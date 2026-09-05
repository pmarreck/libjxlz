const std = @import("std");
const jxl = @import("../root.zig");
const BitReader = jxl.base.bit_reader.BitReader;
const fixture = @import("upsampling_frame_fixture.zig");
const sf = jxl.base.soft_float;
fn check(allocator: std.mem.Allocator, comptime first: usize, comptime end: usize) !void {
	inline for (first..end) |id| {
		const data = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const rgb = @field(fixture, "rgb_" ++ std.fmt.comptimePrint("{d}", .{id}));
		var br = BitReader.init(data[2..]);
		var metadata = jxl.codec.image_metadata.CodecMetadata{};
		metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
		metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
		metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
		try br.jumpToByteBoundary();
		const framedata = data[2 + br.totalBitsConsumed() / 8 ..];
		var decoder = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
		defer decoder.deinit();
		try decoder.decodeFrame(framedata);
		try std.testing.expectEqual(@as(u32, 1) << @as(u5, @intCast(id % 3 + 1)), decoder.frame_header.upsampling);
		if (id >= 6) {
			try std.testing.expect(decoder.frame_header.loop_filter.gab);
			try std.testing.expectEqual(2, decoder.frame_header.loop_filter.epf_iters);
		}
		const image = &decoder.rendered_image.?;
		try std.testing.expectEqual(rgb.len, image.data.len);
		const params = try jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
		for (0..image.ysize) |y| for (0..image.xsize) |x| {
			const linear = jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params);
			for (linear, 0..) |value, c| {
				const encoded = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, @max(value, 0), 1.0 / 2.4) - 0.055;
				const pixel: i32 = @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
				const expected: i32 = rgb[(y * image.xsize + x) * 3 + c];
				if (@abs(pixel - expected) > 1) {
					std.debug.print("id={d} ({d},{d}) channel={d}: expected={d} actual={d}\n", .{ id, x, y, c, expected, pixel });
					return error.TestUnexpectedResult;
				}
			}
		};
	}
}
test "upsampled frames match upstream RGB output" {
	try check(std.testing.allocator, 0, 9);
}

fn checkOne(allocator: std.mem.Allocator) !void {
	try check(allocator, 0, 1);
}
test "upsampled frame allocation failures release partial state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOne, .{});
}

test "upsampled frame rejects every truncated section prefix" {
	var br = BitReader.init(fixture.bytes_1[2..]);
	var metadata = jxl.codec.image_metadata.CodecMetadata{};
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	const frame = fixture.bytes_1[2 + br.totalBitsConsumed() / 8 ..];
	for (0..frame.len) |len| {
		var decoder = jxl.codec.dec_frame.FrameDecoder.init(std.testing.allocator, &metadata);
		defer decoder.deinit();
		var header_br = BitReader.init(frame[0..len]);
		decoder.initFrame(&header_br) catch continue;
		const offset = decoder.headerBytes(&header_br);
		header_br.close() catch continue;
		if (@import("vardct_frame.zig").decode(&decoder, frame[0..len], offset)) return error.TestUnexpectedResult else |_| {}
	}
}
