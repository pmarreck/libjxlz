const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("jpeg_coefficients_synthetic_fixture.zig");
fn check(allocator: std.mem.Allocator, comptime id: usize) !void {
	const key = std.fmt.comptimePrint("{d}", .{id});
	var parsed = try jxl.codec.container.extractCodestreamAndBoxes(allocator, &@field(fixture, "bytes_" ++ key));
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
	try std.testing.expectEqual(if (id >= 64 and id < 72) jxl.codec.frame_header.ColorTransform.none else jxl.codec.frame_header.ColorTransform.ycbcr, decoder.frame_header.color_transform);
	try std.testing.expectEqual(id & 4 != 0, decoder.frame_header.passes.num_passes > 1);
	const jpeg = output.?;
	const dimensions = @field(fixture, "dimensions_" ++ key);
	try std.testing.expectEqual(dimensions[0], jpeg.width);
	try std.testing.expectEqual(dimensions[1], jpeg.height);
	try std.testing.expect(decoder.rendered_image == null);
	inline for (@field(fixture, "components_" ++ key), 0..) |expected, c| {
		const component = jpeg.components[c];
		try std.testing.expectEqualSlices(u32, &expected, &.{component.id, component.h_sampling, component.v_sampling, @intCast(component.width_blocks), @intCast(component.height_blocks)});
		try std.testing.expectEqualSlices(i16, &@field(fixture, std.fmt.comptimePrint("coeffs_{d}_{d}", .{id,c})), component.coefficients);
	}
	const quant = &@field(fixture, "quant_" ++ key);
	try std.testing.expectEqual(quant.len, jpeg.quant.len);
	for (quant, jpeg.quant) |expected, actual| try std.testing.expectEqualSlices(i32, &expected, &actual.values);
}
test "JPEG synthetic coefficients match original tables and every block" {
	inline for (0..80) |id| {
		errdefer std.debug.print("JPEG synthetic record {d}\n", .{id});
		try check(std.testing.allocator, id);
	}
}
fn allocationCase(allocator: std.mem.Allocator) !void {
	try check(allocator, 5);
	try check(allocator, 63);
	try check(allocator, 67);
	try check(allocator, 79);
}
test "JPEG reconstruction allocations release partial coefficient state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
test "JPEG coefficient decoding fits a one MiB allocation budget for a small image" {
	const buffer = try std.testing.allocator.alloc(u8, 1024 * 1024);
	defer std.testing.allocator.free(buffer);
	var bounded = std.heap.FixedBufferAllocator.init(buffer);
	try check(bounded.allocator(), 0);
}
