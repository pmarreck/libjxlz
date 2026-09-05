const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("modular_render_fixture.zig");
fn check(allocator: std.mem.Allocator, comptime count: usize) !void {
	@setEvalBranchQuota(10000);
	inline for (0..count) |id| {
		const data = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const expected = @field(fixture, "rgb_" ++ std.fmt.comptimePrint("{d}", .{id}));
		var br = jxl.base.bit_reader.BitReader.init(data[2..]);
		var metadata = jxl.codec.image_metadata.CodecMetadata{};
		metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
		metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
		metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
		try br.jumpToByteBoundary();
		var dec = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
		defer dec.deinit();
		try dec.decodeFrame(data[2 + br.totalBitsConsumed() / 8 ..]);
		const colors = [_]u32{ 1, 2, 4, 8, 1, 2, 4, 8, 1, 2, 4, 8 };
		const extras = [_]u32{ 2, 2, 4, 8, 2, 2, 4, 8, 1, 2, 4, 8 };
		try std.testing.expectEqual(colors[id], dec.frame_header.upsampling);
		try std.testing.expectEqual(extras[id], dec.frame_header.extra_channel_upsampling[0]);
		try std.testing.expectEqual(jxl.codec.frame_header.FrameEncoding.modular, dec.frame_header.encoding);
		try std.testing.expectEqual(id < 4, metadata.m.xyb_encoded);
		try std.testing.expect(dec.rendered_image != null);
		const image = dec.rendered_image.?;
		try std.testing.expectEqual(19, image.xsize);
		try std.testing.expectEqual(13, image.ysize);
		try std.testing.expectEqual(4, image.channels);
		const params = jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
		for (0..image.ysize) |y| for (0..image.xsize) |x| {
			const linear = jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params);
			var rgba: [4]f32 = undefined;
			for (linear, 0..) |value, c| rgba[c] = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, @max(value, 0), 1.0 / 2.4) - 0.055;
			if (id >= 4) for (0..3) |c| {
				rgba[c] = image.rowConst(y, c)[x];
			};
			rgba[3] = image.rowConst(y, 3)[x];
			for (rgba, 0..) |value, c| {
				const pixel: i32 = @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
				if (@abs(pixel - @as(i32, expected[(y * image.xsize + x) * 4 + c])) > 1) {
					std.debug.print("id={d} xy={d},{d} channel={d} actual={d} expected={d}\n", .{ id, x, y, c, pixel, expected[(y * image.xsize + x) * 4 + c] });
					return error.TestUnexpectedResult;
				}
			}
		};
	}
}
test "modular rendered frames match upstream RGBA" {
	try check(std.testing.allocator, 12);
}
fn one(allocator: std.mem.Allocator) !void {
	try check(allocator, 1);
}
test "modular rendered allocation failures release state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, one, .{});
}
