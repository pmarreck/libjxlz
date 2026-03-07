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
const encoding = @import("../modular/encoding.zig");
const modular_image = @import("../modular/modular_image.zig");

const Image = modular_image.Image;

const PreparedFrame = struct {
    codec_meta: image_metadata.CodecMetadata,
    frame_data: []const u8,
};

fn prepareFrame(data: []const u8) !PreparedFrame {
    var br = BitReader.init(data[2..]);

    const size = headers.SizeHeader.readFromBitStream(&br);
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    try br.jumpToByteBoundary();

    var codec_meta = image_metadata.CodecMetadata{};
    codec_meta.m = metadata;
    codec_meta.size = size;
    codec_meta.transform_data = transform_data;

    const frame_header_byte_offset = br.totalBitsConsumed() / 8;
    return .{
        .codec_meta = codec_meta,
        .frame_data = data[2 + frame_header_byte_offset ..],
    };
}

fn expectImagesEqual(expected: *const Image, actual: *const Image) !void {
    try testing.expectEqual(expected.w, actual.w);
    try testing.expectEqual(expected.h, actual.h);
    try testing.expectEqual(expected.bitdepth, actual.bitdepth);
    try testing.expectEqual(expected.nb_meta_channels, actual.nb_meta_channels);
    try testing.expectEqual(expected.channels.items.len, actual.channels.items.len);

    for (expected.channels.items, actual.channels.items) |*expected_ch, *actual_ch| {
        try testing.expectEqual(expected_ch.w, actual_ch.w);
        try testing.expectEqual(expected_ch.h, actual_ch.h);
        try testing.expectEqual(expected_ch.hshift, actual_ch.hshift);
        try testing.expectEqual(expected_ch.vshift, actual_ch.vshift);
        for (0..expected_ch.h) |y| {
            try testing.expectEqualSlices(i32, expected_ch.rowConst(y), actual_ch.rowConst(y));
        }
    }
}

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

    // DequantMatrices::DecodeDC — must be called before decodeGlobalInfo
    // (matches C++ ProcessDCGlobal flow in dec_frame.cc)
    var matrices = dec_frame.DequantMatrices{};
    try matrices.decodeDC(&br);

    // Decode global modular info
    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    // After global decode, full_image should have channels
    // Before undo transforms, channel count may differ (palette reduces 3 to 2)
    try testing.expectEqual(@as(usize, 2), mod_dec.full_image.channels.items.len);
    try testing.expectEqual(@as(usize, 4), mod_dec.full_image.w);
    try testing.expectEqual(@as(usize, 4), mod_dec.full_image.h);

    // Undo transforms to get final pixel data
    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // After undo transforms (palette inverse), should have 3 RGB channels
    try testing.expectEqual(@as(usize, 3), mod_dec.full_image.channels.items.len);
    const ch_r = &mod_dec.full_image.channels.items[0];
    const ch_g = &mod_dec.full_image.channels.items[1];
    const ch_b = &mod_dec.full_image.channels.items[2];
    try testing.expectEqual(@as(usize, 4), ch_r.w);
    try testing.expectEqual(@as(usize, 4), ch_r.h);
    try testing.expectEqual(@as(usize, 4), ch_g.w);
    try testing.expectEqual(@as(usize, 4), ch_g.h);
    try testing.expectEqual(@as(usize, 4), ch_b.w);
    try testing.expectEqual(@as(usize, 4), ch_b.h);

    // Verify pixel (0,0) = (0, 0, 128)
    try testing.expectEqual(@as(i32, 0), ch_r.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), ch_g.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 128), ch_b.rowConst(0)[0]);

    // Verify pixel (3,3) = (255, 255, 128)
    try testing.expectEqual(@as(i32, 255), ch_r.rowConst(3)[3]);
    try testing.expectEqual(@as(i32, 255), ch_g.rowConst(3)[3]);
    try testing.expectEqual(@as(i32, 128), ch_b.rowConst(3)[3]);
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

    // DequantMatrices::DecodeDC — must be called before decodeGlobalInfo
    var matrices16 = dec_frame.DequantMatrices{};
    try matrices16.decodeDC(&br);

    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // Verify dimensions
    try testing.expectEqual(@as(usize, 3), mod_dec.full_image.channels.items.len);
    const ch_r = &mod_dec.full_image.channels.items[0];
    try testing.expectEqual(@as(usize, 16), ch_r.w);
    try testing.expectEqual(@as(usize, 16), ch_r.h);

    // Verify pixel (0,0) = (0, 0, 0)
    try testing.expectEqual(@as(i32, 0), ch_r.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), mod_dec.full_image.channels.items[1].rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), mod_dec.full_image.channels.items[2].rowConst(0)[0]);

    // Verify pixel (15,15) = (255, 255, 240)
    try testing.expectEqual(@as(i32, 255), ch_r.rowConst(15)[15]);
    try testing.expectEqual(@as(i32, 255), mod_dec.full_image.channels.items[1].rowConst(15)[15]);
    try testing.expectEqual(@as(i32, 240), mod_dec.full_image.channels.items[2].rowConst(15)[15]);
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

    // DequantMatrices::DecodeDC — must be called before decodeGlobalInfo
    var matrices64 = dec_frame.DequantMatrices{};
    try matrices64.decodeDC(&br);

    var mod_dec = dec_frame.ModularFrameDecoder.init(allocator);
    defer mod_dec.deinit();
    mod_dec.initFrame(frame_dim);

    try mod_dec.decodeGlobalInfo(&br, &fh, &codec_meta);

    const weighted = @import("../modular/weighted.zig");
    const wp_hdr = weighted.Header{};
    const transform_zig = @import("../modular/transform.zig");
    try transform_zig.undoTransforms(&mod_dec.full_image, &wp_hdr);

    // Verify dimensions
    try testing.expectEqual(@as(usize, 3), mod_dec.full_image.channels.items.len);
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
    try testing.expectEqual(@as(i32, 252), ch_r.rowConst(63)[63]);
    try testing.expectEqual(@as(i32, 252), ch_g.rowConst(63)[63]);
    try testing.expectEqual(@as(i32, 252), ch_b.rowConst(63)[63]);
}

test "decode lossless 300x200 single-section" {
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
    // group_size_shift=2 means grp_dim=512, so 300x200 fits in one group/section.
    try testing.expectEqual(@as(usize, 1), frame_dim.num_groups);

    // Full frame decode using FrameDecoder — pass data starting at frame header
    const frame_data = data[2 + frame_header_byte_offset ..];
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &codec_meta);
    defer frame_dec.deinit();

    try frame_dec.decodeFrame(frame_data);

    const img = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 3), img.channels.items.len);
    try testing.expectEqual(@as(usize, 300), img.w);
    try testing.expectEqual(@as(usize, 200), img.h);
    try testing.expectEqual(@as(i32, 0), img.channels.items[0].rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[1].rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[2].rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 43), img.channels.items[0].rowConst(0)[299]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[1].rowConst(0)[299]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[2].rowConst(0)[299]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[0].rowConst(199)[0]);
    try testing.expectEqual(@as(i32, 199), img.channels.items[1].rowConst(199)[0]);
    try testing.expectEqual(@as(i32, 0), img.channels.items[2].rowConst(199)[0]);
    try testing.expectEqual(@as(i32, 43), img.channels.items[0].rowConst(199)[299]);
    try testing.expectEqual(@as(i32, 199), img.channels.items[1].rowConst(199)[299]);
    try testing.expectEqual(@as(i32, 109), img.channels.items[2].rowConst(199)[299]);
    try testing.expectEqual(@as(i32, 150), img.channels.items[0].rowConst(100)[150]);
    try testing.expectEqual(@as(i32, 100), img.channels.items[1].rowConst(100)[150]);
    try testing.expectEqual(@as(i32, 152), img.channels.items[2].rowConst(100)[150]);
}

test "decode lossless 600x10 multi-section grayscale" {
    const data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const allocator = testing.allocator;
    const prepared = try prepareFrame(data);

    var frame_dec = dec_frame.FrameDecoder.init(allocator, &prepared.codec_meta);
    defer frame_dec.deinit();

    try frame_dec.decodeFrame(prepared.frame_data);

    const img = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 1), img.channels.items.len);
    try testing.expectEqual(@as(usize, 600), img.w);
    try testing.expectEqual(@as(usize, 10), img.h);

    const ch = &img.channels.items[0];
    try testing.expectEqual(@as(usize, 600), ch.w);
    try testing.expectEqual(@as(usize, 10), ch.h);
    try testing.expectEqual(@as(i32, 255), ch.rowConst(0)[0]);
    try testing.expectEqual(@as(i32, 255), ch.rowConst(0)[599]);
    try testing.expectEqual(@as(i32, 227), ch.rowConst(1)[0]);
    try testing.expectEqual(@as(i32, 113), ch.rowConst(5)[123]);
    try testing.expectEqual(@as(i32, 0), ch.rowConst(9)[0]);
    try testing.expectEqual(@as(i32, 0), ch.rowConst(9)[599]);
}

test "decode truncated 600x10 multi-section frame errors" {
    const data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const allocator = testing.allocator;
    const prepared = try prepareFrame(data);

    var frame_dec = dec_frame.FrameDecoder.init(allocator, &prepared.codec_meta);
    defer frame_dec.deinit();

    try testing.expectError(error.GenericError, frame_dec.decodeFrame(prepared.frame_data[0 .. prepared.frame_data.len - 1]));
}

test "reference and specialized reader strategies decode identical lossless corpus" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        name: []const u8,
        data: []const u8,
    }{
        .{ .name = "lossless_4x4", .data = @embedFile("../testdata/lossless_4x4.jxl") },
        .{ .name = "lossless_16x16", .data = @embedFile("../testdata/lossless_16x16.jxl") },
        .{ .name = "lossless_64x64", .data = @embedFile("../testdata/lossless_64x64.jxl") },
        .{ .name = "lossless_300x200", .data = @embedFile("../testdata/lossless_300x200.jxl") },
        .{ .name = "lossless_600x10_multisection", .data = @embedFile("../testdata/lossless_600x10_multisection.jxl") },
    };

    for (cases) |tc| {
        const prepared = try prepareFrame(tc.data);

        var ref_dec = dec_frame.FrameDecoder.init(allocator, &prepared.codec_meta);
        defer ref_dec.deinit();
        try ref_dec.decodeFrameWithReaderStrategy(encoding.ReaderStrategy.reference, prepared.frame_data);

        var specialized_dec = dec_frame.FrameDecoder.init(allocator, &prepared.codec_meta);
        defer specialized_dec.deinit();
        try specialized_dec.decodeFrameWithReaderStrategy(encoding.ReaderStrategy.specialized, prepared.frame_data);

        try expectImagesEqual(ref_dec.getDecodedImage(), specialized_dec.getDecodedImage());
    }
}
