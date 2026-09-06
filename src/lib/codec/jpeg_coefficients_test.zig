const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("jpeg_coefficients_fixture.zig");
const allocator = std.testing.allocator;
test "JPEG coefficients and quantization tables match the original JPEG" {
	var parsed = try jxl.codec.container.extractCodestreamAndBoxes(allocator, &fixture.bytes_0);
	defer parsed.deinit(allocator);
	var output: ?*jxl.codec.jpeg_reconstruction.Data = null;
	for (parsed.boxes) |*box| if (box.reconstruction) |*data| { output = data; };
	try std.testing.expect(output != null);
	var br = jxl.base.bit_reader.BitReader.init(parsed.codestream[2..]);
	var metadata = jxl.codec.image_metadata.CodecMetadata{};
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	var decoder = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
	defer decoder.deinit();
	decoder.jpeg_output = output;
	try decoder.decodeFrame(parsed.codestream[2 + br.totalBitsConsumed() / 8 ..]);
	const jpeg = output.?;
	try std.testing.expectEqual(fixture.dimensions_0[0], jpeg.width);
	try std.testing.expectEqual(fixture.dimensions_0[1], jpeg.height);
	try std.testing.expect(decoder.rendered_image == null);
	inline for (fixture.components_0, 0..) |expected, c| {
		const component = jpeg.components[c];
		try std.testing.expectEqualSlices(u32, &expected, &.{component.id, component.h_sampling, component.v_sampling, @intCast(component.width_blocks), @intCast(component.height_blocks)});
		try std.testing.expectEqualSlices(i16, &@field(fixture, std.fmt.comptimePrint("coeffs_0_{d}", .{c})), component.coefficients);
	}
	try std.testing.expectEqual(fixture.quant_0.len, jpeg.quant.len);
	for (fixture.quant_0, jpeg.quant) |expected, actual| try std.testing.expectEqualSlices(i32, &expected, &actual.values);
}
