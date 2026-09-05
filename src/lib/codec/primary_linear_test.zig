const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("primary_frame_fixture.zig");
fn check(data: []const u8, linear_bits: []const u32, id: usize) !void {
	const allocator = std.testing.allocator;
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
	try std.testing.expect(!dec.rendered_in_output_space);
	const params = try jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
	const channels: usize = if (id >= 32 and id < 40) 1 else 3;
	for (0..image.ysize) |y| for (0..image.xsize) |x| {
		const rgb = jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params);
		for (0..channels) |c| {
			const expected: f32 = @bitCast(linear_bits[(y * image.xsize + x) * channels + c]);
			if (!std.math.isFinite(rgb[c]) or @abs(rgb[c] - expected) > 0.0001 + 0.00001 * @abs(expected)) {
				std.debug.print("primary linear id={d} x={d} y={d} c={d} actual={d} expected={d}\n", .{ id, x, y, c, rgb[c], expected });
				return error.TestUnexpectedResult;
			}
		}
	};
}
test "primary frames match independently requested upstream linear output" {
	@setEvalBranchQuota(20000);
	inline for (0..50) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, check, .{ &@field(fixture, "bytes_" ++ key), &@field(fixture, "linear_bits_" ++ key), id });
	}
}
