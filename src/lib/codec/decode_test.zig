// End-to-end decode integration test: decode a real lossless JXL to pixels.
// Tests the full pipeline: SizeHeader → ImageMetadata → FrameHeader → TOC → Modular decode → Inverse transforms.

const std = @import("std");
const testing = std.testing;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const dec_frame = @import("dec_frame.zig");
const toc = @import("toc.zig");

test "parse lossless 4x4 codestream headers" {
    const data = @embedFile("../testdata/lossless_4x4.jxl");

    // Verify codestream signature
    try testing.expectEqual(@as(u8, 0xFF), data[0]);
    try testing.expectEqual(@as(u8, 0x0A), data[1]);

    var br = BitReader.init(data[2..]);

    // Parse SizeHeader
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 4), size.xsize());
    try testing.expectEqual(@as(usize, 4), size.ysize());

    // Parse ImageMetadata
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    try testing.expectEqual(@as(u32, 8), metadata.bit_depth.bits_per_sample);
    try testing.expect(!metadata.bit_depth.floating_point_sample);
    try testing.expect(!metadata.have_preview);
    try testing.expect(!metadata.have_animation);

    // Parse CustomTransformData
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);

    // Build CodecMetadata
    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    // Parse FrameHeader
    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    try testing.expectEqual(frame_header_mod.FrameEncoding.modular, fh.encoding);
    try testing.expect(fh.is_last);

    // Compute frame dimensions
    const frame_dim = fh.toFrameDimensions(&codec_meta, false);
    try testing.expectEqual(@as(usize, 4), frame_dim.xsize);
    try testing.expectEqual(@as(usize, 4), frame_dim.ysize);
    // Small image: single group
    try testing.expectEqual(@as(usize, 1), frame_dim.num_groups);

    // Read TOC
    const num_toc = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, fh.passes.num_passes);
    try testing.expectEqual(@as(usize, 1), num_toc);
}

test "decode lossless 4x4 modular global info" {
    const data = @embedFile("../testdata/lossless_4x4.jxl");
    const allocator = testing.allocator;

    var br = BitReader.init(data[2..]);

    // Parse headers
    const size = headers.SizeHeader.readFromBitStream(&br);
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    const frame_dim = fh.toFrameDimensions(&codec_meta, false);

    // Single-section frame: skip TOC (1 entry = 1 section)
    const num_toc = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, fh.passes.num_passes);
    _ = num_toc;
    // For single-section frame, there is no TOC — all data is in one section

    // Decode global modular info
    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    // After global decode, full_image should have channels
    try testing.expect(mod_dec.full_image.channels.items.len >= 3);
    try testing.expectEqual(@as(usize, 4), mod_dec.full_image.w);
    try testing.expectEqual(@as(usize, 4), mod_dec.full_image.h);

    // Undo transforms to get final pixel data
    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // For a 4x4 lossless modular image, after undo transforms we should have
    // RGB channels with the original pixel values.
    // Expected pixel (0,0): R=0, G=0, B=128
    if (mod_dec.full_image.channels.items.len >= 3) {
        const ch_r = &mod_dec.full_image.channels.items[0];
        const ch_g = &mod_dec.full_image.channels.items[1];
        const ch_b = &mod_dec.full_image.channels.items[2];

        if (ch_r.w == 4 and ch_r.h == 4) {
            const r00 = ch_r.rowConst(0)[0];
            const g00 = ch_g.rowConst(0)[0];
            const b00 = ch_b.rowConst(0)[0];

            // Pixel (0,0) should be (0, 0, 128) from our test image
            try testing.expectEqual(@as(i32, 0), r00);
            try testing.expectEqual(@as(i32, 0), g00);
            try testing.expectEqual(@as(i32, 128), b00);

            // Pixel (3,3) should be (255, 255, 128)
            const r33 = ch_r.rowConst(3)[3];
            const g33 = ch_g.rowConst(3)[3];
            const b33 = ch_b.rowConst(3)[3];
            try testing.expectEqual(@as(i32, 255), r33);
            try testing.expectEqual(@as(i32, 255), g33);
            try testing.expectEqual(@as(i32, 128), b33);
        }
    }
}
