const std = @import("std");
const sf = @import("../base/soft_float.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const fixture = @import("dc_group_fixture.zig");
const global = @import("vardct_global.zig");
const Chroma = @import("frame_header.zig").YCbCrChromaSubsampling;
const dc_group = @import("dc_group.zig");

fn checkGroups(allocator: std.mem.Allocator) !void {
	@setEvalBranchQuota(20000);
	var context = global.BlockContextMap{ .allocator = allocator };
	context.dc_lengths = .{ 1, 2, 1 };
	context.dc_thresholds[0][0] = -10;
	context.dc_thresholds[1][0..2].* = .{ -5, 6 };
	context.dc_thresholds[2][0] = 0;
	context.num_dc_ctxs = 12;
	inline for (0..8) |case| {
		const wire = [_]u8{if (case >= 4) 4 else 0}; // 4:2:0 raw modes 0,1,0.
		var chroma_br = BitReader.init(&wire);
		const chroma = Chroma.readFromBitStream(&chroma_br);
		try chroma_br.close();
		var br = BitReader.init(&@field(fixture, "stream_" ++ std.fmt.comptimePrint("{d}", .{case})));
		var group = try dc_group.DcGroup.decode(allocator, &br, .{
			.width = 4, .height = 4, .chroma = chroma, .stream_id = 23,
			.dc_steps = .{ sf.div(sf.fromInt(1), sf.fromInt(4)), sf.div(sf.fromInt(1), sf.fromInt(2)), sf.fromInt(1) },
			.cfl = .{ sf.div(sf.fromInt(-1), sf.fromInt(2)), sf.div(sf.fromInt(5), sf.fromInt(4)) },
			.block_context = &context,
		});
		defer group.deinit();
		try std.testing.expectEqual(@field(fixture, "bits_" ++ std.fmt.comptimePrint("{d}", .{case})), br.totalBitsConsumed());
		const expected = @field(fixture, "samples_" ++ std.fmt.comptimePrint("{d}", .{case}));
		var i: usize = 0;
		for (group.planes, 0..) |plane, c| {
			try std.testing.expectEqual(@as(usize, if (case >= 4 and c != 1) 2 else 4), plane.width);
			try std.testing.expectEqual(plane.width, plane.height);
			for (plane.samples) |value| {
				try std.testing.expectEqual(sf.div(sf.fromInt(expected[i]), sf.fromInt(64)), value);
				i += 1;
			}
		}
		try std.testing.expectEqual(expected.len, i);
		try std.testing.expectEqualSlices(u8, &@field(fixture, "buckets_" ++ std.fmt.comptimePrint("{d}", .{case})), group.buckets);
		try br.close();
	}
}

test "VarDCT DC groups match upstream modular streams dequantization and contexts" {
	try checkGroups(std.testing.allocator);
}

test "VarDCT DC groups release every failed allocation" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkGroups, .{});
}

test "VarDCT DC groups reject every truncated byte prefix" {
	const context = global.BlockContextMap{ .allocator = std.testing.allocator };
	inline for (.{ .{ &fixture.stream_0, @as(u8, 0) }, .{ &fixture.stream_4, @as(u8, 4) } }) |case| {
		const wire = [_]u8{case[1]};
		var chroma_br = BitReader.init(&wire);
		const chroma = Chroma.readFromBitStream(&chroma_br);
		try chroma_br.close();
		for (0..case[0].len) |len| {
			var br = BitReader.init(case[0][0..len]);
			try std.testing.expectError(error.NotEnoughBytes, dc_group.DcGroup.decode(std.testing.allocator, &br, .{
				.width = 4, .height = 4, .chroma = chroma, .stream_id = 23,
				.dc_steps = @splat(sf.fromInt(1)), .cfl = @splat(sf.Fixed.zero), .block_context = &context,
			}));
		}
	}
}

test "VarDCT DC groups reject invalid dimensions before reading" {
	const context = global.BlockContextMap{ .allocator = std.testing.allocator };
	const wire = [_]u8{4};
	var chroma_br = BitReader.init(&wire);
	const chroma = Chroma.readFromBitStream(&chroma_br);
	try chroma_br.close();
	for ([_][2]usize{ .{ 0, 4 }, .{ 4, 0 }, .{ 257, 4 }, .{ 4, 257 }, .{ 3, 4 }, .{ 4, 3 } }) |size| {
		var br = BitReader.init(&fixture.stream_4);
		try std.testing.expectError(error.GenericError, dc_group.DcGroup.decode(std.testing.allocator, &br, .{
			.width = size[0], .height = size[1], .chroma = chroma, .stream_id = 23,
			.dc_steps = @splat(sf.fromInt(1)), .cfl = @splat(sf.Fixed.zero), .block_context = &context,
		}));
		try std.testing.expectEqual(@as(usize, 0), br.totalBitsConsumed());
		try br.close();
	}
}

fn checkBorrowedGlobal(allocator: std.mem.Allocator) !void {
	const encoding = @import("../modular/encoding.zig");
	const ma = @import("../modular/dec_ma.zig");
	const ans = @import("../entropy/dec_ans.zig");
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	var original = BitReader.init(&fixture.stream_0);
	try std.testing.expectEqual(@as(u64, 0), original.readBits(2));
	var header = try encoding.GroupHeader.readFromBitStream(&original, allocator);
	defer header.deinit();
	try std.testing.expect(!header.use_global_tree);
	try std.testing.expectEqual(@as(usize, 0), header.transforms.len);
	var tree: ma.Tree = .empty;
	defer tree.deinit(allocator);
	try ma.decodeTree(allocator, &original, &tree, 1024);
	var code = ans.ANSCode.init(allocator);
	defer code.deinit();
	const contexts = try ans.decodeHistograms(allocator, &original, (tree.items.len + 1) / 2, &code);
	defer allocator.free(contexts);
	// Keep upstream's entropy payload, with its tree and histograms borrowed
	// from global state instead of repeated in the modular group header.
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(2, 0);
	try writer.write(4, 3); // Global tree, default WP, no transforms.
	while (original.totalBitsConsumed() < fixture.bits_0) try writer.write(1, original.readBits(1));
	try original.close();
	const bits = writer.bitsWritten();
	try writer.write(8, 0xa5);
	try writer.zeroPadToByte();
	const context = global.BlockContextMap{ .allocator = allocator };
	var br = BitReader.init(writer.bytes());
	var group = try dc_group.DcGroup.decode(allocator, &br, .{
		.width = 4, .height = 4, .stream_id = 23,
		.global = .{ .tree = tree.items, .code = &code, .context_map = contexts },
		.dc_steps = .{ sf.div(sf.fromInt(1), sf.fromInt(4)), sf.div(sf.fromInt(1), sf.fromInt(2)), sf.fromInt(1) },
		.cfl = .{ sf.div(sf.fromInt(-1), sf.fromInt(2)), sf.div(sf.fromInt(5), sf.fromInt(4)) },
		.block_context = &context,
	});
	defer group.deinit();
	var i: usize = 0;
	for (group.planes) |plane| for (plane.samples) |value| {
		try std.testing.expectEqual(sf.div(sf.fromInt(fixture.samples_0[i]), sf.fromInt(64)), value);
		i += 1;
	};
	try std.testing.expectEqual(@as(usize, 48), i);
	try std.testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0))), group.buckets);
	try std.testing.expectEqual(bits, br.totalBitsConsumed());
	try std.testing.expectEqual(@as(u64, 0xa5), br.readBits(8));
	try br.close();
}

test "VarDCT DC groups borrow global entropy and preserve following bits" {
	try checkBorrowedGlobal(std.testing.allocator);
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBorrowedGlobal, .{});
}
