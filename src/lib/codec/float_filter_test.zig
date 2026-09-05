const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("float_filter_fixture.zig");
test "wide floating Modular frame renders exact upstream samples" {
	const allocator = std.testing.allocator;
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(fixture.bytes_0[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	try br.close();
	var session = jxl.codec.decode_session.Session.init(allocator);
	defer session.deinit();
	var dec = try session.decode(metadata, fixture.bytes_0[2 + br.totalBitsConsumed() / 8 ..]);
	defer dec.deinit();
	const image = dec.rendered_image orelse return error.TestUnexpectedResult;
	for (0..image.ysize) |y| for (0..image.xsize) |x| for (0..3) |c| {
		try std.testing.expectEqual(fixture.float_0[(y * image.xsize + x) * 3 + c], @as(u32, @bitCast(image.rowConst(y, c)[x])));
	};
}
