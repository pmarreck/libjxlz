const std = @import("std");
const jxl = @import("../root.zig");
const session = @import("decode_session.zig");
const fixture = @import("spline_frame_fixture.zig");
fn checkFixture(allocator: std.mem.Allocator, data: []const u8, expected: []const u8, id: usize) !void {
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	var state = session.Session.init(allocator);
	defer state.deinit();
	var offset = 2 + br.totalBitsConsumed() / 8;
	var frames: usize = 0;
	while (offset < data.len) {
		const size = try jxl.codec.dec_frame.frameByteCount(allocator, metadata, data[offset..]);
		var dec = try state.decode(metadata, data[offset..][0..size]);
		defer dec.deinit();
		offset += size;
		frames += 1;
		if (dec.frame_header.is_last) {
			try std.testing.expectEqual(id % 5, @intFromEnum(dec.frame_header.blending_info.mode));
			try std.testing.expectEqual(@as(i32, if (id % 2 != 0) -2 else 3), dec.frame_header.frame_origin.x0);
			try std.testing.expectEqual(@as(i32, if (id % 2 != 0) -1 else 2), dec.frame_header.frame_origin.y0);
			try std.testing.expect(dec.frame_header.custom_size_or_origin);
			const image = dec.rendered_image orelse return error.TestUnexpectedResult;
			try std.testing.expectEqual(metadata.xsize(), image.xsize);
			try std.testing.expectEqual(metadata.ysize(), image.ysize);
			try std.testing.expectEqual(3 + (id % 10) / 5, image.channels);
			try std.testing.expect(dec.rendered_in_output_space);
			for (0..image.ysize) |y| for (0..image.xsize) |x| for (0..image.channels) |c| {
				const pixel: i32 = @intFromFloat(@round(std.math.clamp(image.rowConst(y, c)[x], 0, 1) * 255));
				const wanted = expected[(y * image.xsize + x) * image.channels + c];
				if (@abs(pixel - @as(i32, wanted)) > 1) {
					std.debug.print("spline id={d} x={d} y={d} c={d} actual={d} expected={d}\n", .{ id, x, y, c, pixel, wanted });
					return error.TestUnexpectedResult;
				}
			};
		}
	}
	try std.testing.expectEqual(2, frames);
}
fn check(allocator: std.mem.Allocator, comptime count: usize) !void {
	@setEvalBranchQuota(20000);
	inline for (0..count) |id| {
		const data = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const expected = @field(fixture, "pixels_" ++ std.fmt.comptimePrint("{d}", .{id}));
		try @call(.never_inline, checkFixture, .{ allocator, &data, &expected, id });
	}
}
test "spline frame session matches upstream cropped blend pixels" {
	try check(std.testing.allocator, 28);
}
fn one(allocator: std.mem.Allocator) !void {
	try checkFixture(allocator, &fixture.bytes_1, &fixture.pixels_1, 1);
}
test "spline frame session allocation failures release state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, one, .{});
}
