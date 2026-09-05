//! Quantized VarDCT AC passes, with a borrowed entropy reader and block metadata.
const std = @import("std");
const JxlError = @import("../base/status.zig").JxlError;
const meta = @import("ac_metadata.zig");
const order = @import("coeff_order.zig");
const Model = @import("vardct_global.zig").BlockContextMap;
const Chroma = @import("frame_header.zig").YCbCrChromaSubsampling;
const unpackSigned = @import("../base/pack_signed.zig").unpackSigned;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const ans = @import("../entropy/dec_ans.zig");
const bits = @import("../base/bits.zig");

const EntropyReader = struct {
	br: *BitReader,
	symbols: *ans.ANSSymbolReader,
	contexts: []const u8,
	pub fn read(self: *EntropyReader, context: usize) JxlError!u32 {
		if (context >= self.contexts.len) return error.GenericError;
		const value = self.symbols.readHybridUint(context, self.br, self.contexts);
		if (!self.br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (value > std.math.maxInt(u32)) return error.GenericError;
		return @intCast(value);
	}
};

pub const Pass = struct {
	map: *const meta.BlockMap,
	dc: []const u8,
	orders: *const order.Orders,
	context: *const Model,
	x: usize = 0,
	y: usize = 0,
	context_offset: usize = 0,
	shift: u5 = 0,
};

pub const Group = struct {
	allocator: std.mem.Allocator,
	width: usize,
	height: usize,
	chroma: Chroma,
	planes: [3][]i32 = @splat(&.{}),

	pub fn create(allocator: std.mem.Allocator, width: usize, height: usize, chroma: Chroma) JxlError!Group {
		if (width == 0 or height == 0 or width > 32 or height > 32) return error.GenericError;
		var result = Group{ .allocator = allocator, .width = width, .height = height, .chroma = chroma };
		errdefer result.deinit();
		for (0..3) |c| {
			result.planes[c] = try allocator.alloc(i32, 64 * result.channelWidth(c) * result.channelHeight(c));
			@memset(result.planes[c], 0);
		}
		return result;
	}

	pub fn deinit(self: *Group) void {
		for (&self.planes) |*plane| {
			self.allocator.free(plane.*);
			plane.* = &.{};
		}
	}

	fn channelWidth(self: *const Group, c: usize) usize {
		const shift: u6 = @intCast(self.chroma.hShift(c));
		return (self.width + (@as(usize, 1) << shift) - 1) >> shift;
	}
	fn channelHeight(self: *const Group, c: usize) usize {
		const shift: u6 = @intCast(self.chroma.vShift(c));
		return (self.height + (@as(usize, 1) << shift) - 1) >> shift;
	}

	/// Consume the group's histogram selector and one complete entropy stream.
	pub fn decodeEntropyPass(self: *Group, allocator: std.mem.Allocator, p: Pass,
		br: *BitReader, code: *const ans.ANSCode, contexts: []const u8, num_histograms: usize) JxlError!void
	{
		if (num_histograms == 0 or num_histograms > 65536 or
			contexts.len != num_histograms * p.context.numACContexts() + @intFromBool(code.lz77.enabled)) return error.GenericError;
		const histogram = br.readBits(bits.ceilLog2Nonzero(num_histograms));
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (histogram >= num_histograms) return error.GenericError;
		var symbols = try ans.ANSSymbolReader.create(code, br, 0, allocator);
		defer symbols.deinit();
		var reader = EntropyReader{ .br = br, .symbols = &symbols, .contexts = contexts };
		var selected = p;
		selected.context_offset = histogram * p.context.numACContexts();
		try self.decodePass(allocator, selected, &reader);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (!symbols.checkANSFinalState()) return error.GenericError;
	}

	/// Reader.read(context) returns a hybrid unsigned symbol. Separate passes
	/// add shifted residuals to the same planes; each pass resets its predictors.
	pub fn decodePass(self: *Group, allocator: std.mem.Allocator, p: Pass, reader: anytype) !void {
		if (p.map.width > 256 or p.map.height > 256 or p.x > p.map.width or p.y > p.map.height or
			self.width > p.map.width - p.x or self.height > p.map.height - p.y or
			p.map.blocks.len != p.map.width * p.map.height or p.dc.len != p.map.blocks.len or
			p.context_offset > std.math.maxInt(usize) - p.context.numACContexts()) return error.GenericError;
		const nonzeros = try allocator.alloc(u32, 3 * self.width * self.height);
		defer allocator.free(nonzeros);
		@memset(nonzeros, 0);
		var offsets: [3]usize = @splat(0);
		for (0..self.height) |y| for (0..self.width) |x| {
			const index = (p.y + y) * p.map.width + p.x + x;
			const block = p.map.blocks[index];
			if (!block.is_first) continue;
			const extent = try meta.strategyExtent(block.strategy);
			if (extent.x > self.width - x or extent.y > self.height - y or
				(!self.chroma.is444() and (extent.x > 1 or extent.y > 1))) return error.GenericError;
			const covered = extent.x * extent.y;
			const size = 64 * covered;
			for ([_]usize{ 1, 0, 2 }) |c| {
				const hs: u6 = @intCast(self.chroma.hShift(c));
				const vs: u6 = @intCast(self.chroma.vShift(c));
				const bx = x >> hs;
				const by = y >> vs;
				if (bx << hs != x or by << vs != y) continue;
				const stride = self.channelWidth(c);
				const nz = nonzeros[c * self.width * self.height ..][0 .. stride * self.channelHeight(c)];
				const pos = by * stride + bx;
				const predicted = if (bx == 0) (if (by == 0) 32 else nz[pos - stride]) else
					if (by == 0) nz[pos - 1] else (nz[pos - stride] + nz[pos - 1] + 1) / 2;
				const block_ctx = try p.context.context(p.dc[index],
					p.map.blocks[(p.y + y) * p.map.width + p.x + bx].quant, order.kStrategyOrder[block.strategy], c);
				const predicted_clamped = @min(predicted, 64);
				const bucket = if (predicted_clamped < 8) predicted_clamped else 4 + predicted_clamped / 2;
				var remaining = try reader.read(p.context_offset + bucket * p.context.num_ctxs + block_ctx);
				if (remaining > size - covered) return error.GenericError;
				for (0..extent.y) |dy| for (0..extent.x) |dx| {
					nz[pos + dy * stride + dx] = @intCast((remaining + covered - 1) / covered);
				};
				if (offsets[c] > self.planes[c].len or size > self.planes[c].len - offsets[c]) return error.GenericError;
				const coefficients = self.planes[c][offsets[c]..][0..size];
				offsets[c] += size;
				const scan = try p.orders.get(block.strategy, c);
				if (scan.len != size) return error.GenericError;
				var previous: usize = @intFromBool(remaining <= size / 16);
				var k = covered;
				while (k < size and remaining != 0) : (k += 1) {
					if (remaining > size - k) return error.GenericError;
					const density = (nonzero_context[(remaining + covered - 1) / covered] + frequency_context[k / covered]) * 2 + previous;
					const ctx = p.context_offset + p.context.num_ctxs * 37 + 458 * @as(usize, block_ctx) + density;
					const symbol = try reader.read(ctx);
					if (scan[k] >= size) return error.GenericError;
					const shifted: i32 = @bitCast(@as(u32, @bitCast(unpackSigned(symbol))) << p.shift);
					coefficients[scan[k]] +%= shifted;
					previous = @intFromBool(symbol != 0);
					remaining -= @intCast(previous);
				}
				if (remaining != 0) return error.GenericError;
			}
		};
		for (offsets, self.planes) |used, plane| if (used != plane.len) return error.GenericError;
	}
};

// ISO zero-density buckets, as tabulated in lib/jxl/ac_context.h.
const frequency_context = [64]usize{
	0xBAD,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,
	15,15,16,16,17,17,18,18,19,19,20,20,21,21,22,22,
	23,23,23,23,24,24,24,24,25,25,25,25,26,26,26,26,
	27,27,27,27,28,28,28,28,29,29,29,29,30,30,30,30,
};
const nonzero_context = [64]usize{
	0xBAD,0,31,62,62,93,93,93,93,123,123,123,123,
	152,152,152,152,152,152,152,152,180,180,180,180,180,
	180,180,180,180,180,180,180,206,206,206,206,206,206,
	206,206,206,206,206,206,206,206,206,206,206,206,206,
	206,206,206,206,206,206,206,206,206,206,206,206,
};
