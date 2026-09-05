//! VarDCT coefficient-order classes, sharing the TOC permutation decoder.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const ans = @import("../entropy/dec_ans.zig");
const strategy = @import("ac_strategy.zig");
const toc = @import("toc.zig");

pub const kNumOrders = 13;
pub const kStrategyOrder = [strategy.kNumValidStrategies]u8{
	0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1,
	1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12,
};

pub const Orders = struct {
	allocator: std.mem.Allocator,
	// Only used classes own storage. Three channel orders are contiguous.
	classes: [kNumOrders][]u32 = @splat(&.{}),

	pub fn deinit(self: *Orders) void {
		for (&self.classes) |*order| {
			self.allocator.free(order.*);
			order.* = &.{};
		}
	}

	pub fn get(self: *const Orders, raw: u8, channel: usize) JxlError![]const u32 {
		if (raw >= kStrategyOrder.len or channel >= 3) return error.GenericError;
		const data = self.classes[kStrategyOrder[raw]];
		if (data.len == 0) return error.GenericError;
		const size = data.len / 3;
		return data[channel * size .. (channel + 1) * size];
	}

	pub fn decode(allocator: std.mem.Allocator, used_orders: u16, used_acs: u32,
		br: *BitReader) JxlError!Orders
	{
		return decodeInner(allocator, used_orders, used_acs, br) catch |err| {
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
			return err;
		};
	}

	fn decodeInner(allocator: std.mem.Allocator, used_orders: u16, used_acs: u32,
		br: *BitReader) JxlError!Orders
	{
		if (used_orders >> kNumOrders != 0 or used_acs >> strategy.kNumValidStrategies != 0)
			return error.GenericError;
		var result = Orders{ .allocator = allocator };
		errdefer result.deinit();
		var code = ans.ANSCode.init(allocator);
		defer code.deinit();
		const contexts: []u8 = if (used_orders != 0)
			try ans.decodeHistograms(allocator, br, toc.kPermutationContexts, &code) else &.{};
		defer allocator.free(contexts);
		var reader: ?ans.ANSSymbolReader = null;
		defer if (reader) |*r| r.deinit();
		if (used_orders != 0) reader = try ans.ANSSymbolReader.create(&code, br, 0, allocator);
		var used_classes: u16 = 0;
		for (kStrategyOrder, 0..) |bucket, raw| {
			if (used_acs & (@as(u32, 1) << @intCast(raw)) != 0)
				used_classes |= @as(u16, 1) << @intCast(bucket);
		}
		var computed: u16 = 0;
		for (kStrategyOrder, 0..) |bucket, raw| {
			const mask = @as(u16, 1) << @intCast(bucket);
			if (computed & mask != 0) continue;
			computed |= mask;
			const used = used_classes & mask != 0;
			const custom = used_orders & mask != 0;
			if (!used and !custom) continue;
			const extent = try strategy.strategyExtent(@intCast(raw));
			const llf = extent.x * extent.y;
			const size = 64 * llf;
			const natural: []u32 = if (used) try allocator.alloc(u32, size) else &.{};
			defer allocator.free(natural);
			if (used) {
				try strategy.naturalOrder(@intCast(raw), natural);
				result.classes[bucket] = try allocator.alloc(u32, 3 * size);
			}
			for (0..3) |c| {
				const dest: ?[]u32 = if (used) result.classes[bucket][c * size .. (c + 1) * size] else null;
				if (custom) {
					try toc.readPermutation(allocator, llf, size, dest, br, &reader.?, contexts);
					if (dest) |order| for (order) |*index| { index.* = natural[index.*]; };
				} else if (dest) |order| @memcpy(order, natural);
			}
		}
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (reader) |*r| if (!r.checkANSFinalState()) return error.GenericError;
		return result;
	}
};
