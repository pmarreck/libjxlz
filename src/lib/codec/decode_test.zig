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

    // Codestream headers are zero-padded to byte boundary before frame data
    try br.jumpToByteBoundary();

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

    // Codestream headers are zero-padded to byte boundary before frame data
    try br.jumpToByteBoundary();

    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    const frame_dim = fh.toFrameDimensions(&codec_meta, false);

    // Read TOC (always present, even for single-section frames)
    const num_toc = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, fh.passes.num_passes);
    const toc_entries = try toc.readToc(allocator, num_toc, &br);
    defer allocator.free(toc_entries);

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

test "decode lossless 16x16 modular" {
    const data = @embedFile("../testdata/lossless_16x16.jxl");
    const allocator = testing.allocator;

    try testing.expectEqual(@as(u8, 0xFF), data[0]);
    try testing.expectEqual(@as(u8, 0x0A), data[1]);

    var br = BitReader.init(data[2..]);

    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 16), size.xsize());
    try testing.expectEqual(@as(usize, 16), size.ysize());

    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);

    // Codestream headers are zero-padded to byte boundary before frame data
    try br.jumpToByteBoundary();

    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    try testing.expectEqual(frame_header_mod.FrameEncoding.modular, fh.encoding);

    const frame_dim = fh.toFrameDimensions(&codec_meta, false);

    // Read TOC
    const num_toc = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, fh.passes.num_passes);
    const toc_entries = try toc.readToc(allocator, num_toc, &br);
    defer allocator.free(toc_entries);

    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // Verify dimensions
    try testing.expect(mod_dec.full_image.channels.items.len >= 3);
    const ch_r = &mod_dec.full_image.channels.items[0];
    try testing.expectEqual(@as(usize, 16), ch_r.w);
    try testing.expectEqual(@as(usize, 16), ch_r.h);

    // Verify pixel (0,0) = (0, 0, 0)
    try testing.expectEqual(@as(i32, 0), ch_r.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), mod_dec.full_image.channels.items[1].rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), mod_dec.full_image.channels.items[2].rowConst(0)[0]);

    // Verify pixel (15,15) = (255, 255, 240)
    const ch_g = &mod_dec.full_image.channels.items[1];
    const ch_b = &mod_dec.full_image.channels.items[2];
    try testing.expectEqual(@as(i32, 255), ch_r.rowConst(15)[15]);
    try testing.expectEqual(@as(i32, 255), ch_g.rowConst(15)[15]);
    try testing.expectEqual(@as(i32, 240), ch_b.rowConst(15)[15]); // (15+15)*8 % 256 = 240

    // Verify pixel (8,4) = (136, 68, 96)
    try testing.expectEqual(@as(i32, 136), ch_r.rowConst(4)[8]); // 8*17 = 136
    try testing.expectEqual(@as(i32, 68), ch_g.rowConst(4)[8]);  // 4*17 = 68
    try testing.expectEqual(@as(i32, 96), ch_b.rowConst(4)[8]);  // (8+4)*8 % 256 = 96
}

test "decode lossless 64x64 modular (may use squeeze)" {
    const data = @embedFile("../testdata/lossless_64x64.jxl");
    const allocator = testing.allocator;

    var br = BitReader.init(data[2..]);

    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 64), size.xsize());
    try testing.expectEqual(@as(usize, 64), size.ysize());

    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);

    // Codestream headers are zero-padded to byte boundary before frame data
    try br.jumpToByteBoundary();

    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    try testing.expectEqual(frame_header_mod.FrameEncoding.modular, fh.encoding);

    const frame_dim = fh.toFrameDimensions(&codec_meta, false);

    // Read TOC
    const num_toc_entries = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, fh.passes.num_passes);
    const toc_entries = try toc.readToc(allocator, num_toc_entries, &br);
    defer allocator.free(toc_entries);

    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // Verify dimensions
    try testing.expect(mod_dec.full_image.channels.items.len >= 3);
    const ch_r = &mod_dec.full_image.channels.items[0];
    const ch_g = &mod_dec.full_image.channels.items[1];
    const ch_b = &mod_dec.full_image.channels.items[2];
    try testing.expectEqual(@as(usize, 64), ch_r.w);
    try testing.expectEqual(@as(usize, 64), ch_r.h);

    // Verify pixel (0,0) = (0, 0, 0)
    try testing.expectEqual(@as(i32, 0), ch_r.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), ch_g.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), ch_b.rowConst(0)[0]);

    // Verify pixel (63,63) = (252, 252, 252)
    try testing.expectEqual(@as(i32, 252), ch_r.rowConst(63)[63]); // 63*4 % 256 = 252
    try testing.expectEqual(@as(i32, 252), ch_g.rowConst(63)[63]);
    try testing.expectEqual(@as(i32, 252), ch_b.rowConst(63)[63]); // (63+63)*2 % 256 = 252

    // Verify pixel (32,16) = (128, 64, 96)
    try testing.expectEqual(@as(i32, 128), ch_r.rowConst(16)[32]); // 32*4 = 128
    try testing.expectEqual(@as(i32, 64), ch_g.rowConst(16)[32]);  // 16*4 = 64
    try testing.expectEqual(@as(i32, 96), ch_b.rowConst(16)[32]);  // (32+16)*2 = 96
}

test "decode lossless 300x200 multi-group" {
    const data = @embedFile("../testdata/lossless_300x200.jxl");
    const allocator = testing.allocator;

    // Parse codestream headers to get CodecMetadata and frame header byte offset
    var br = BitReader.init(data[2..]);

    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 300), size.xsize());
    try testing.expectEqual(@as(usize, 200), size.ysize());

    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);

    // Codestream headers are zero-padded to byte boundary before frame data
    try br.jumpToByteBoundary();

    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    // Capture byte offset where frame header starts (before reading it)
    const frame_header_byte_offset = br.totalBitsConsumed() / 8;

    // Quick validation: parse frame header to check encoding
    const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    try testing.expectEqual(frame_header_mod.FrameEncoding.modular, fh.encoding);
    const frame_dim = fh.toFrameDimensions(&codec_meta, false);
    try testing.expect(frame_dim.num_groups >= 2);

    // Full frame decode using FrameDecoder — pass data starting at frame header
    const frame_data = data[2 + frame_header_byte_offset ..];
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &codec_meta);
    defer frame_dec.deinit();

    try frame_dec.decodeFrame(frame_data);

    const img = frame_dec.getDecodedImage();
    try testing.expect(img.channels.items.len >= 3);
    try testing.expectEqual(@as(usize, 300), img.w);
    try testing.expectEqual(@as(usize, 200), img.h);

    // Verify pixel (0,0) = (0, 0, 0)
    const ch_r = &img.channels.items[0];
    const ch_g = &img.channels.items[1];
    const ch_b = &img.channels.items[2];
    try testing.expectEqual(@as(i32, 0), ch_r.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), ch_g.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), ch_b.rowConst(0)[0]);

    // Verify pixel (150, 100) = (150, 100, (150*100)%256 = 216)
    try testing.expectEqual(@as(i32, 150), ch_r.rowConst(100)[150]);
    try testing.expectEqual(@as(i32, 100), ch_g.rowConst(100)[150]);
    try testing.expectEqual(@as(i32, 216), ch_b.rowConst(100)[150]);

    // Verify pixel (299, 199) = (43, 199, (299*199)%256 = 245)
    try testing.expectEqual(@as(i32, 43), ch_r.rowConst(199)[299]);   // 299 % 256 = 43
    try testing.expectEqual(@as(i32, 199), ch_g.rowConst(199)[299]);
    try testing.expectEqual(@as(i32, 245), ch_b.rowConst(199)[299]);  // (299*199) % 256
}
