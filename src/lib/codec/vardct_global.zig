//! VarDCT block entropy contexts and global chroma-from-luma parameters.
//! Wire layout follows lib/jxl/entropy_coder.cc and chroma_from_luma.cc.
const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const unpackSigned = @import("../base/pack_signed.zig").unpackSigned;
const loadFloat16Fixed = @import("../base/float.zig").loadFloat16Fixed;
const sf = @import("../base/soft_float.zig");
const fc = @import("field_coders.zig");
const decodeContextMapAlloc = @import("../entropy/dec_context_map.zig").decodeContextMapAlloc;

pub const kDCThresholdDist = fc.U32Enc.init(fc.bits(4), fc.bitsOffset(8, 16), fc.bitsOffset(16, 272), fc.bitsOffset(32, 65808));
pub const kQFThresholdDist = fc.U32Enc.init(fc.bits(2), fc.bitsOffset(3, 4), fc.bitsOffset(5, 12), fc.bitsOffset(8, 44));
pub const kColorFactorDist = fc.U32Enc.init(fc.val(84), fc.val(256), fc.bitsOffset(8, 2), fc.bitsOffset(16, 258));
const kDefaultCtxMap = [_]u8{
	0, 1, 2, 2, 3, 3, 4, 5, 6, 6, 6, 6, 6,
	7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
	7, 8, 9, 9, 10, 11, 12, 13, 14, 14, 14, 14, 14,
};

pub const BlockContextMap = struct {
	allocator: std.mem.Allocator,
	dc_thresholds: [3][15]i32 = @splat(@splat(0)),
	dc_lengths: [3]u4 = @splat(0),
	qf_thresholds: [15]u32 = @splat(0),
	qf_length: u4 = 0,
	ctx_map: []const u8 = &kDefaultCtxMap,
	owned_map: ?[]u8 = null,
	num_ctxs: usize = 15,
	num_dc_ctxs: usize = 1,

	pub fn deinit(self: *BlockContextMap) void {
		if (self.owned_map) |map| self.allocator.free(map);
		self.* = .{ .allocator = self.allocator };
	}

	pub fn decode(allocator: std.mem.Allocator, br: *BitReader) JxlError!BlockContextMap {
		return decodeInner(allocator, br) catch |err| {
			return if (!br.allReadsWithinBounds()) error.NotEnoughBytes else err;
		};
	}

	fn decodeInner(allocator: std.mem.Allocator, br: *BitReader) JxlError!BlockContextMap {
		var result = BlockContextMap{ .allocator = allocator };
		errdefer result.deinit();
		const is_default = br.readBits(1) != 0;
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (is_default) return result;
		for (0..3) |c| {
			result.dc_lengths[c] = @intCast(br.readBits(4));
			result.num_dc_ctxs *= @as(usize, result.dc_lengths[c]) + 1;
			for (result.dc_thresholds[c][0..result.dc_lengths[c]]) |*threshold| {
				threshold.* = unpackSigned(fc.U32Coder.read(kDCThresholdDist, br));
			}
		}
		result.qf_length = @intCast(br.readBits(4));
		for (result.qf_thresholds[0..result.qf_length]) |*threshold| {
			threshold.* = fc.U32Coder.read(kQFThresholdDist, br) + 1;
		}
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		const combinations = result.num_dc_ctxs * (@as(usize, result.qf_length) + 1);
		if (combinations > 64) return error.GenericError;
		const map = try allocator.alloc(u8, 3 * 13 * combinations);
		result.owned_map = map;
		result.ctx_map = map;
		try decodeContextMapAlloc(map, &result.num_ctxs, br, allocator);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (result.num_ctxs > 16) return error.GenericError;
		return result;
	}

	pub fn dcThresholds(self: *const BlockContextMap, c: usize) []const i32 {
		return self.dc_thresholds[c][0..self.dc_lengths[c]];
	}

	pub fn qfThresholds(self: *const BlockContextMap) []const u32 {
		return self.qf_thresholds[0..self.qf_length];
	}

	pub fn dcBucket(self: *const BlockContextMap, dc: [3]i32) usize {
		var bucket: [3]usize = @splat(0);
		for (dc, 0..) |value, c| for (self.dcThresholds(c)) |threshold| {
			bucket[c] += @intFromBool(value > threshold);
		};
		return (bucket[0] * (@as(usize, self.dc_lengths[2]) + 1) + bucket[2]) *
			(@as(usize, self.dc_lengths[1]) + 1) + bucket[1];
	}

	pub fn context(self: *const BlockContextMap, dc: usize, qf: u32, order: usize, c: usize) JxlError!u8 {
		if (dc >= self.num_dc_ctxs or order >= 13 or c >= 3) return error.GenericError;
		var qf_index: usize = 0;
		for (self.qfThresholds()) |threshold| qf_index += @intFromBool(qf > threshold);
		const channel = if (c < 2) c ^ 1 else 2;
		const index = ((channel * 13 + order) * (@as(usize, self.qf_length) + 1) + qf_index) * self.num_dc_ctxs + dc;
		return self.ctx_map[index];
	}

	pub fn numACContexts(self: *const BlockContextMap) usize {
		return self.num_ctxs * (37 + 458);
	}
};

pub const ColorCorrelation = struct {
	color_factor: u32 = 84,
	base: [2]sf.Fixed = .{ sf.Fixed.zero, sf.fromInt(1) },
	dc: [2]i8 = @splat(0),

	pub fn decode(br: *BitReader, xyb: bool) JxlError!ColorCorrelation {
		var result = ColorCorrelation{};
		result.base[1] = sf.fromInt(@intFromBool(xyb));
		const is_default = br.readBits(1) != 0;
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (is_default) return result;
		result.color_factor = fc.U32Coder.read(kColorFactorDist, br);
		for (&result.base) |*base| {
			const bits: u16 = @intCast(br.readBits(16));
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
			base.* = try loadFloat16Fixed(bits);
			if (sf.cmp(base.*, sf.fromInt(-4)) < 0 or sf.cmp(base.*, sf.fromInt(4)) > 0)
				return error.GenericError;
		}
		for (&result.dc) |*dc| dc.* = @intCast(@as(i16, @intCast(br.readBits(8))) - 128);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		return result;
	}

	pub fn ratios(self: ColorCorrelation, factors: [2]i8) [2]sf.Fixed {
		var result: [2]sf.Fixed = undefined;
		for (&result, self.base, factors) |*value, base, factor| {
			value.* = sf.add(base, sf.div(sf.fromInt(factor), sf.fromInt(self.color_factor)));
		}
		return result;
	}

	pub fn dcRatios(self: ColorCorrelation) [2]sf.Fixed {
		return self.ratios(self.dc);
	}
};
