const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("vardct_extra_fixture.zig");
fn check(allocator: std.mem.Allocator, comptime count: usize) !void {
	inline for (0..count) |id| {
		const input_bytes = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const data = if (id == 4) try jxl.codec.container.extractCodestream(allocator, &input_bytes) else &input_bytes;
		defer if (id == 4) allocator.free(data);
		const expected = @field(fixture, "rgb_" ++ std.fmt.comptimePrint("{d}", .{id}));
		var br = jxl.base.bit_reader.BitReader.init(data[2..]);
		var metadata = jxl.codec.image_metadata.CodecMetadata{};
		metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
		metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
		metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
		try br.jumpToByteBoundary();
		const framedata = data[2 + br.totalBitsConsumed() / 8 ..];
		var dec = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
		defer dec.deinit();
		try dec.decodeFrame(framedata);
		const image = dec.rendered_image.?;
		const alpha = &dec.getDecodedImage().channels.items[if (id == 3) 1 else 0];
		const params = try jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
		try std.testing.expectEqual(@as(u32, if (id == 3) 2 else 1), metadata.m.num_extra_channels);
		try std.testing.expectEqual(@as(usize, if (id == 3) 2 else 1), dec.getDecodedImage().channels.items.len);
		if (id == 5) try std.testing.expect(dec.frame_header.passes.num_passes > 1);
		for (0..image.ysize) |y| for (0..image.xsize) |x| {
			if (id == 3) try std.testing.expectEqual(@as(i32, @intCast((x * 17 + y * 5) % 256)), dec.getDecodedImage().channels.items[0].rowConst(y)[x]);
			try std.testing.expectEqual(@as(i32, expected[(y * image.xsize + x) * 4 + 3]) * @as(i32, if (id == 4) 257 else 1), alpha.rowConst(y)[x]);
			const linear = jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params);
			for (linear, 0..) |value, c| {
				const encoded = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, @max(value, 0), 1.0 / 2.4) - 0.055;
				const pixel: i32 = @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
				try std.testing.expect(@abs(pixel - @as(i32, expected[(y * image.xsize + x) * 4 + c])) <= 1);
			}
		};
	}
}
test "VarDCT alpha frames match upstream RGBA including filtered multigroup images" {
	try check(std.testing.allocator, 6);
}
fn checkOne(allocator: std.mem.Allocator) !void {
	try check(allocator, 1);
}
test "VarDCT alpha frame allocation failures release partial state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOne, .{});
}
