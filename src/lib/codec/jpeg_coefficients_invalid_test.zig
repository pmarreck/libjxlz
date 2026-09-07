const std = @import("std");
const jxl = @import("../root.zig");
const reconstruction = @import("jpeg_reconstruction_fixture.zig");
const allocator = std.testing.allocator;
test "JPEG output rejects valid Modular and XYB frames" {
	const cases = [_]struct { bytes: []const u8, encoding: jxl.codec.frame_header.FrameEncoding }{
		.{.bytes = &@import("modular_render_fixture.zig").bytes_0, .encoding = .modular},
		.{.bytes = &@import("vardct_frame_fixture.zig").bytes_0, .encoding = .var_dct},
	};
	for (cases) |item| {
		var jpeg = try jxl.codec.jpeg_reconstruction.parse(allocator, &reconstruction.bytes_0);
		defer jpeg.deinit();
		var br = jxl.base.bit_reader.BitReader.init(item.bytes[2..]);
		var metadata = jxl.codec.image_metadata.CodecMetadata{};
		metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
		metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
		metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
		try br.jumpToByteBoundary();
		const frame = item.bytes[2 + br.totalBitsConsumed() / 8 ..];
		var header_reader = jxl.base.bit_reader.BitReader.init(frame);
		const header = try jxl.codec.frame_header.FrameHeader.readFromBitStream(&header_reader, &metadata, false);
		try std.testing.expectEqual(item.encoding, header.encoding);
		if (item.encoding == .var_dct) try std.testing.expect(metadata.m.xyb_encoded);
		var ordinary = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
		defer ordinary.deinit();
		try ordinary.decodeFrame(frame);
		var decoder = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
		defer decoder.deinit();
		decoder.jpeg_output = &jpeg;
		const expected_error = if (item.encoding == .modular) error.InvalidJpegReconstruction else error.GenericError;
		if (decoder.decodeFrame(frame)) return error.AcceptedNonJpegFrame else |err| try std.testing.expectEqual(expected_error, err);
	}
}
