const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("float_modular_chroma_fixture.zig");
fn decode(allocator: std.mem.Allocator) !void {
	const data = &fixture.bytes_1;
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	try br.close();
	var session = jxl.codec.decode_session.Session.init(allocator);
	defer session.deinit();
	var dec = try session.decode(metadata, data[2 + br.totalBitsConsumed() / 8 ..]);
	defer dec.deinit();
	const image = dec.rendered_image orelse return error.TestUnexpectedResult;
	try std.testing.expectEqual(@as(usize, 13), image.xsize);
	try std.testing.expectEqual(@as(usize, 9), image.ysize);
	for (0..image.ysize) |y| for (0..image.xsize) |x| for (0..3) |c| {
		const expected = fixture.pixels_1[(y * image.xsize + x) * 3 + c];
		const actual: u32 = @bitCast(image.rowConst(y, c)[x]);
		if (expected & 0x7fffffff > 0x7f800000) try std.testing.expect(actual & 0x7fffffff > 0x7f800000) else if (expected & 0x7fffffff == 0 or expected & 0x7fffffff == 0x7f800000) try std.testing.expectEqual(expected, actual) else {
			const wanted: f32 = @bitCast(expected);
			const value: f32 = @bitCast(actual);
			try std.testing.expect(std.math.isFinite(value));
			try std.testing.expectApproxEqAbs(wanted, value, 0.0001 + 0.00001 * @abs(wanted));
		}
	};
}
test "nonfinite chroma allocation failures release partial rendered images" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, decode, .{});
}
