const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("chroma_frame_fixture.zig");
fn check(allocator: std.mem.Allocator, data: []const u8, expected: []const u8, id: usize) !void {
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	var state = jxl.codec.decode_session.Session.init(allocator);
	defer state.deinit();
	var dec = try state.decode(metadata, data[2 + br.totalBitsConsumed() / 8 ..]);
	defer dec.deinit();
	try std.testing.expectEqual(jxl.codec.frame_header.ColorTransform.ycbcr, dec.frame_header.color_transform);
	const image = dec.rendered_image orelse return error.TestUnexpectedResult;
	try std.testing.expect(dec.rendered_in_output_space);
	try std.testing.expectEqual(metadata.size.xsize(), image.xsize);
	try std.testing.expectEqual(metadata.size.ysize(), image.ysize);
	for (0..image.ysize) |y| for (0..image.xsize) |x| for (0..3) |c| {
		const actual: i32 = @intFromFloat(@round(std.math.clamp(image.rowConst(y, c)[x], 0, 1) * 255));
		const wanted = expected[(y * image.xsize + x) * 3 + c];
		if (@abs(actual - @as(i32, wanted)) > 1) {
			std.debug.print("chroma id={d} x={d} y={d} c={d} actual={d} expected={d}\n", .{ id, x, y, c, actual, wanted });
			return error.TestUnexpectedResult;
		}
	};
}
test "chroma frames match upstream JPEG transcode pixels" {
	@setEvalBranchQuota(50000);
	inline for (0..12) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, check, .{ std.testing.allocator, &@field(fixture, "bytes_" ++ key), &@field(fixture, "pixels_" ++ key), id });
	}
}
fn allocationCase(allocator: std.mem.Allocator) !void {
	try check(allocator, &fixture.bytes_1, &fixture.pixels_1, 1);
}
test "chroma frame allocation failures release subsampled planes" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
fn malformed(allocator: std.mem.Allocator, data: []const u8) !void {
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	try br.close();
	var state = jxl.codec.decode_session.Session.init(allocator);
	defer state.deinit();
	var dec = try state.decode(metadata, data[2 + br.totalBitsConsumed() / 8 ..]);
	defer dec.deinit();
}
test "chroma frame rejects adaptive DC smoothing as upstream does" {
	try std.testing.expectError(error.GenericError, malformed(std.testing.allocator, &fixture.bad_smoothing));
}
