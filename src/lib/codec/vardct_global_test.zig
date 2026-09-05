const std = @import("std");
const testing = std.testing;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const global = @import("vardct_global.zig");
const fixture = @import("vardct_global_fixture.zig");
const sf = @import("../base/soft_float.zig");

test "VarDCT global default block contexts preserve channel ordering" {
	var br = BitReader.init(&.{1});
	var model = try global.BlockContextMap.decode(testing.allocator, &br);
	defer model.deinit();
	try testing.expectEqual(@as(usize, 1), br.totalBitsConsumed());
	try testing.expectEqual(@as(usize, 15), model.num_ctxs);
	try testing.expectEqual(@as(usize, 1), model.num_dc_ctxs);
	try testing.expectEqual(@as(usize, 7425), model.numACContexts());
	try testing.expectEqual(@as(u8, 7), try model.context(0, 256, 0, 0));
	try testing.expectEqual(@as(u8, 0), try model.context(0, 256, 0, 1));
	try testing.expectEqual(@as(u8, 14), try model.context(0, 256, 12, 2));
	try testing.expectError(error.GenericError, model.context(1, 0, 0, 0));
	try testing.expectError(error.GenericError, model.context(0, 0, 13, 0));
	try testing.expectError(error.GenericError, model.context(0, 0, 0, 3));
	try br.close();
}

fn checkCustomContext(allocator: std.mem.Allocator) !void {
	var br = BitReader.init(&fixture.block_context);
	var model = try global.BlockContextMap.decode(allocator, &br);
	defer model.deinit();
	try testing.expectEqual(fixture.block_context_bits, br.totalBitsConsumed());
	try testing.expectEqual(@as(usize, 4), model.num_ctxs);
	try testing.expectEqual(@as(usize, 12), model.num_dc_ctxs);
	try testing.expectEqualSlices(i32, &.{-10}, model.dcThresholds(0));
	try testing.expectEqualSlices(i32, &.{ -5, 6 }, model.dcThresholds(1));
	try testing.expectEqualSlices(i32, &.{0}, model.dcThresholds(2));
	try testing.expectEqualSlices(u32, &.{7}, model.qfThresholds());
	var hash: u64 = 14695981039346656037;
	for (0..12) |dc| for ([_]u32{ 0, 7, 8, 255 }) |qf| {
		for (0..13) |order| for (0..3) |c| {
			hash = (hash ^ try model.context(dc, qf, order, c)) *% 1099511628211;
		};
	};
	try testing.expectEqual(fixture.block_context_lookup_hash, hash);
	try testing.expectEqual(@as(usize, 0), model.dcBucket(.{ -10, -5, 0 }));
	try testing.expectEqual(@as(usize, 11), model.dcBucket(.{ -9, 7, 1 }));
	try testing.expectEqual(@as(usize, 6), model.dcBucket(.{ -9, -5, 0 }));
	try testing.expectEqual(@as(usize, 3), model.dcBucket(.{ -10, -5, 1 }));
	try testing.expectEqual(@as(usize, 1), model.dcBucket(.{ -10, 6, 0 }));
	try testing.expectEqual(@as(usize, 2), model.dcBucket(.{ -10, 7, 0 }));
	try br.close();
}

test "VarDCT global custom block contexts match upstream encoder and decoder" {
	try checkCustomContext(testing.allocator);
}

test "VarDCT global context allocations release on failure" {
	try testing.checkAllAllocationFailures(testing.allocator, checkCustomContext, .{});
}

test "VarDCT global rejects every truncated context fixture byte prefix" {
	for (0..fixture.block_context.len) |len| {
		var br = BitReader.init(fixture.block_context[0..len]);
		try testing.expectError(error.NotEnoughBytes, global.BlockContextMap.decode(testing.allocator, &br));
	}
}

test "VarDCT global CfL matches upstream half float and signed endpoint fixture" {
	var br = BitReader.init(&fixture.cfl);
	const cfl = try global.ColorCorrelation.decode(&br, true);
	try testing.expectEqual(fixture.cfl_bits, br.totalBitsConsumed());
	try testing.expectEqual(@as(u32, 256), cfl.color_factor);
	try testing.expectEqual(sf.fromInt(-2), cfl.dcRatios()[0]);
	try testing.expectEqual(sf.div(sf.fromInt(319), sf.fromInt(256)), cfl.dcRatios()[1]);
	try br.close();
}

test "VarDCT global CfL defaults respect XYB and reject truncation" {
	for ([_]bool{ false, true }) |xyb| {
		var br = BitReader.init(&.{1});
		const cfl = try global.ColorCorrelation.decode(&br, xyb);
		try testing.expectEqual(sf.Fixed.zero, cfl.dcRatios()[0]);
		try testing.expectEqual(sf.fromInt(@intFromBool(xyb)), cfl.dcRatios()[1]);
		try testing.expectEqual(@as(usize, 1), br.totalBitsConsumed());
		try br.close();
	}
	for (0..fixture.cfl.len) |len| {
		var br = BitReader.init(fixture.cfl[0..len]);
		try testing.expectError(error.NotEnoughBytes, global.ColorCorrelation.decode(&br, true));
	}
}

test "VarDCT global CfL rejects nonfinite and excessive bases" {
	for ([_]u16{ 0x7c00, 0xfc00, 0x7c01, 0x4401, 0xc401 }) |bits| {
		var writer = BitWriter.init(testing.allocator);
		defer writer.deinit();
		try writer.write(3, 0); // Explicit fields, default factor selector.
		try writer.write(16, bits);
		try writer.write(16, 0);
		try writer.write(16, 0x8080);
		try writer.zeroPadToByte();
		var br = BitReader.init(writer.bytes());
		try testing.expectError(error.GenericError, global.ColorCorrelation.decode(&br, true));
		try br.close();
	}
}

test "VarDCT global block context product accepts 64 and rejects 128" {
	for ([_]u4{ 0, 1 }) |qf_count| {
		var writer = BitWriter.init(testing.allocator);
		defer writer.deinit();
		try writer.write(1, 0);
		for (0..3) |_| {
			try writer.write(4, 3);
			for (0..3) |_| try writer.write(6, 0); // Three zero DC thresholds.
		}
		try writer.write(4, qf_count);
		if (qf_count != 0) try writer.write(4, 0); // QF threshold 1.
		try writer.write(3, 1); // Simple all-zero context map.
		try writer.zeroPadToByte();
		var br = BitReader.init(writer.bytes());
		if (qf_count == 0) {
			var model = try global.BlockContextMap.decode(testing.allocator, &br);
			defer model.deinit();
			try testing.expectEqual(@as(usize, 2496), model.ctx_map.len);
			try testing.expectEqual(@as(usize, 64), model.num_dc_ctxs);
			try testing.expectEqual(@as(usize, 63), model.dcBucket(.{ 1, 1, 1 }));
			try testing.expectEqual(@as(u8, 0), try model.context(63, 255, 12, 2));
		} else {
			try testing.expectError(error.GenericError, global.BlockContextMap.decode(testing.allocator, &br));
		}
		try br.close();
	}
}

test "VarDCT global CfL accepts every selector endpoint and exact base bounds" {
	for (0..4) |selector| {
		const distr = global.kColorFactorDist.getDistr(@intCast(selector));
		const payloads = if (distr.isDirect()) [_]u32{ 0, 0 } else
			[_]u32{ 0, (@as(u32, 1) << @intCast(distr.extraBits())) - 1 };
		for (payloads) |payload| {
			var writer = BitWriter.init(testing.allocator);
			defer writer.deinit();
			try writer.write(1, 0);
			try writer.write(2, selector);
			if (!distr.isDirect()) try writer.write(distr.extraBits(), payload);
			try writer.write(16, 0xc400); // -4.
			try writer.write(16, 0x4400); // +4.
			try writer.write(16, 0x8080); // Zero signed DC factors.
			try writer.zeroPadToByte();
			var br = BitReader.init(writer.bytes());
			const cfl = try global.ColorCorrelation.decode(&br, true);
			try testing.expectEqual(if (distr.isDirect()) distr.direct() else distr.offset() + payload, cfl.color_factor);
			try testing.expectEqual(sf.fromInt(-4), cfl.dcRatios()[0]);
			try testing.expectEqual(sf.fromInt(4), cfl.dcRatios()[1]);
			try br.close();
		}
	}
}
