const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("float_noise_fixture.zig");
fn replay(allocator: std.mem.Allocator) !void {
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
	const start = 2 + br.totalBitsConsumed() / 8;
	var state = jxl.codec.decode_session.Session.init(allocator);
	defer state.deinit();
	{
		var offset = start;
		var frames: usize = 0;
		while (offset < data.len) {
			const size = try jxl.codec.dec_frame.frameByteCount(allocator, metadata, data[offset..]);
			var dec = try state.decode(metadata, data[offset..][0..size]);
			defer dec.deinit();
			offset += size;
			frames += 1;
			if (dec.frame_header.is_last) {
				const image = dec.rendered_image orelse return error.TestUnexpectedResult;
				try std.testing.expectEqual(@as(usize, 13), image.xsize);
				try std.testing.expectEqual(@as(usize, 9), image.ysize);
				for (0..image.ysize) |y| for (0..image.xsize) |x| for (0..3) |c| {
					const expected = fixture.float_1_0[(y * image.xsize + x) * 3 + c];
					const actual: u32 = @bitCast(image.rowConst(y, c)[x]);
					if (expected & 0x7fffffff > 0x7f800000) try std.testing.expect(actual & 0x7fffffff > 0x7f800000) else if (expected & 0x7fffffff == 0 or expected & 0x7fffffff == 0x7f800000) try std.testing.expectEqual(expected, actual) else try std.testing.expectApproxEqAbs(@as(f32, @bitCast(expected)), @as(f32, @bitCast(actual)), 0.000001);
				};
			}
		}
		try std.testing.expectEqual(@as(usize, 2), frames);
		try std.testing.expect(state.refs[1].float_image != null);
	}
}
test "float noise frames preserve reference storage" {
	try replay(std.testing.allocator);
}
test "float noise reference allocation failures release partial state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, replay, .{});
}
