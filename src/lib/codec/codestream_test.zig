// Integration test: parse real JXL codestream headers.
// Tests SizeHeader, ImageMetadata, and FrameHeader against a known file.

const std = @import("std");
const testing = std.testing;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const color_encoding = @import("color_encoding.zig");
const frame_header_mod = @import("frame_header.zig");

test "parse real JXL codestream headers" {
    // Load the bare codestream extracted from mahavatar babaji.jxl
    const data = @embedFile("../testdata/small_test_codestream.jxl");

    // Skip the 2-byte codestream marker (0xFF 0x0A)
    try testing.expectEqual(@as(u8, 0xFF), data[0]);
    try testing.expectEqual(@as(u8, 0x0A), data[1]);

    var br = BitReader.init(data[2..]);

    // Parse SizeHeader
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 201), size.xsize());
    try testing.expectEqual(@as(usize, 251), size.ysize());

    // Parse ImageMetadata
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    try testing.expect(!metadata.have_preview);
    try testing.expect(!metadata.have_animation);
    try testing.expectEqual(@as(u32, 8), metadata.bit_depth.bits_per_sample);
    try testing.expect(!metadata.bit_depth.floating_point_sample);
    try testing.expect(metadata.xyb_encoded);
    try testing.expectEqual(@as(u32, 1), metadata.orientation);
    try testing.expectEqual(@as(u32, 0), metadata.num_extra_channels);

    // ColorEncoding should be sRGB defaults
    try testing.expect(!metadata.color_encoding.want_icc);
    try testing.expectEqual(color_encoding.ColorSpace.rgb, metadata.color_encoding.color_space);

    // Build CodecMetadata for FrameHeader parsing
    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;

    // Parse FrameHeader
    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    try testing.expectEqual(frame_header_mod.FrameType.regular_frame, fh.frame_type);
    try testing.expect(fh.is_last); // single-frame image
}
