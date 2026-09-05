const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("transfer_frame_fixture.zig");
fn check(data: []const u8, linear_bits: []const u32, encoded_bits: []const u32, id: usize) !void {
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
	const params = jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
	const channels: usize = if (id >= 14) 1 else 3;
	for (0..image.ysize) |y| for (0..image.xsize) |x| {
		const rgb = jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params);
		var expected_rgb: [3]f32 = undefined;
		for (0..3) |c| expected_rgb[c] = @bitCast(linear_bits[(y * image.xsize + x) * channels + @min(c, channels - 1)]);
		const transferred = try @import("output_transfer.zig").fromLinear(expected_rgb, metadata.m.color_encoding.tf, metadata.m.tone_mapping.intensity_target, .{ 0.2126, 0.7152, 0.0722 });
		for (0..channels) |c| {
			const wanted: f32 = @bitCast(encoded_bits[(y * image.xsize + x) * channels + c]);
			if (!std.math.isFinite(rgb[c]) or @abs(rgb[c] - expected_rgb[c]) > 0.0001 + 0.00001 * @abs(expected_rgb[c])) {
				std.debug.print("linear id={d} x={d} y={d} c={d} actual={d} expected={d}\n", .{ id, x, y, c, rgb[c], expected_rgb[c] });
				return error.TestUnexpectedResult;
			}
			if (!std.math.isFinite(transferred[c]) or @abs(transferred[c] - wanted) > 0.0002) {
				std.debug.print("from oracle linear id={d} x={d} y={d} c={d} input={d} actual={d} expected={d}\n", .{ id, x, y, c, expected_rgb[c], transferred[c], wanted });
				return error.TestUnexpectedResult;
			}
		}
	};
}
test "transfer frame linear reconstruction and independent transfer inputs" {
	@setEvalBranchQuota(20000);
	inline for (0..28) |id| try @call(.never_inline, check, .{ &@field(fixture, std.fmt.comptimePrint("bytes_{d}", .{id})), &@field(fixture, std.fmt.comptimePrint("linear_bits_{d}", .{id})), &@field(fixture, std.fmt.comptimePrint((if ((id % 14) / 2 == 3) "pq_scalar_{d}" else "float_bits_{d}"), .{id})), id });
}
