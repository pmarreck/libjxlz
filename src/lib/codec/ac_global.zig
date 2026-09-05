//! VarDCT AC-global coefficient orders and entropy tables.
const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const ans = @import("../entropy/dec_ans.zig");
const Orders = @import("coeff_order.zig").Orders;
const Matrices = @import("dec_frame.zig").DequantMatrices;
const Model = @import("vardct_global.zig").BlockContextMap;
const fc = @import("field_coders.zig");
const order_encoding = fc.U32Enc.init(fc.val(0x5f), fc.val(0x13), fc.val(0), fc.bits(13));

pub const Pass = struct {
	orders: Orders,
	code: ans.ANSCode,
	contexts: []u8 = &.{},
};
pub const Global = struct {
	allocator: std.mem.Allocator,
	num_histograms: usize,
	passes: []Pass,
	pub fn deinit(self: *Global) void {
		for (self.passes) |*pass| {
			pass.orders.deinit();
			pass.code.deinit();
			self.allocator.free(pass.contexts);
		}
		self.allocator.free(self.passes);
		self.passes = &.{};
	}
	pub fn decode(allocator: std.mem.Allocator, br: *BitReader, matrices: *Matrices, used_acs: u32, num_groups: usize, num_passes: usize, model: *const Model) JxlError!Global {
		return decodeInner(allocator, br, matrices, used_acs, num_groups, num_passes, model) catch |err| {
			return if (!br.allReadsWithinBounds()) error.NotEnoughBytes else err;
		};
	}
	fn decodeInner(allocator: std.mem.Allocator, br: *BitReader, matrices: *Matrices, used_acs: u32, num_groups: usize, num_passes: usize, model: *const Model) JxlError!Global {
		if (num_groups == 0 or num_passes == 0 or num_passes > 11) return error.GenericError;
		try matrices.decode(br);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		try matrices.ensureComputed(allocator, used_acs);
		const num_histograms = 1 + br.readBits(@import("../base/bits.zig").ceilLog2Nonzero(num_groups));
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		const num_contexts = std.math.mul(usize, num_histograms, model.numACContexts()) catch return error.GenericError;
		const passes = try allocator.alloc(Pass, num_passes);
		for (passes) |*pass| pass.* = .{ .orders = .{ .allocator = allocator }, .code = ans.ANSCode.init(allocator) };
		var result = Global{ .allocator = allocator, .num_histograms = num_histograms, .passes = passes };
		errdefer result.deinit();
		for (passes) |*pass| {
			const used_orders = fc.U32Coder.read(order_encoding, br);
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
			pass.orders = try Orders.decode(allocator, @intCast(used_orders), used_acs, br);
			pass.contexts = try ans.decodeHistograms(allocator, br, num_contexts, &pass.code);
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		}
		return result;
	}
};
