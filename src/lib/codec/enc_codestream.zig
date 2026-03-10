// Encoder-side codestream-shell helpers.
// Starts with native SizeHeader/ImageMetadata/CustomTransformData writers.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const dec_frame = @import("dec_frame.zig");
const enc_frame = @import("enc_frame.zig");
const enc_toc = @import("enc_toc.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");
const modular_image = @import("../modular/modular_image.zig");

const Channel = modular_image.Channel;

fn prepareFrame(data: []const u8) !struct {
    codec_meta: image_metadata.CodecMetadata,
    frame_data: []const u8,
} {
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

fn writeSizeRawValue(value: u32, writer: *BitWriter) !void {
    if (value < (1 << 9) + 1) {
        try writer.write(2, 0);
        try writer.write(9, value - 1);
        return;
    }
    if (value < (1 << 13) + 1) {
        try writer.write(2, 1);
        try writer.write(13, value - 1);
        return;
    }
    if (value < (1 << 18) + 1) {
        try writer.write(2, 2);
        try writer.write(18, value - 1);
        return;
    }
    try writer.write(2, 3);
    try writer.write(30, value - 1);
}

/// Emits the non-small ratio-0 SizeHeader form for arbitrary dimensions.
pub fn writeRawSizeHeader(xsize: u32, ysize: u32, writer: *BitWriter) !void {
    std.debug.assert(xsize > 0 and ysize > 0);
    try writer.write(1, 0); // non-small
    try writeSizeRawValue(ysize, writer);
    try writer.write(3, 0); // ratio = 0, xsize written explicitly
    try writeSizeRawValue(xsize, writer);
}

/// Writes a complete codestream using native Zig serializers for SizeHeader,
/// ImageMetadata, CustomTransformData, and the already-assembled frame payload.
pub fn writeCodestream(
    codec_meta: *const image_metadata.CodecMetadata,
    frame_data: []const u8,
    writer: *BitWriter,
) !void {
    try writer.write(8, 0xFF);
    try writer.write(8, headers.codestream_marker);
    try writeRawSizeHeader(@intCast(codec_meta.xsize()), @intCast(codec_meta.ysize()), writer);
    try image_metadata.writeImageMetadata(&codec_meta.m, writer);
    try image_metadata.writeCustomTransformData(&codec_meta.transform_data, codec_meta.m.xyb_encoded, writer);
    try writer.zeroPadToByte();
    for (frame_data) |byte| {
        try writer.write(8, byte);
    }
}

const testing = std.testing;

test "writeCodestream round-trips a grayscale codestream through header parse and FrameDecoder" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const prepared = try prepareFrame(source_data);

    var codec_meta = prepared.codec_meta;
    codec_meta.size = .{
        .small = false,
        .ysize_raw = 3,
        .ratio = 0,
        .xsize_raw = 3,
    };

    const frame_header = blk: {
        var br = BitReader.init(prepared.frame_data);
        break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    };

    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    var dc_global = BitWriter.init(allocator);
    defer dc_global.deinit();
    try dc_global.write(1, 1); // DequantMatrices all_default
    try dc_global.write(1, 0); // no global tree
    try testing.expectEqual(@as(usize, 0), try enc_encoding.writeSingleNodeLocalTreeGroup(
        allocator,
        &channel,
        .gradient,
        &dc_global,
    ));
    try dc_global.zeroPadToByte();

    const sections = [_][]const u8{dc_global.bytes()};
    var frame_writer = BitWriter.init(allocator);
    defer frame_writer.deinit();
    try enc_frame.writeFrame(&frame_header, &codec_meta, &sections, &frame_writer);
    try frame_writer.zeroPadToByte();

    var codestream = BitWriter.init(allocator);
    defer codestream.deinit();
    try writeCodestream(&codec_meta, frame_writer.bytes(), &codestream);
    try codestream.zeroPadToByte();

    const bytes = codestream.bytes();
    try testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try testing.expectEqual(@as(u8, 0x0A), bytes[1]);

    var br = BitReader.init(bytes[2..]);
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 3), size.xsize());
    try testing.expectEqual(@as(usize, 3), size.ysize());
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    try br.jumpToByteBoundary();

    var parsed_meta = image_metadata.CodecMetadata{};
    parsed_meta.m = metadata;
    parsed_meta.size = size;
    parsed_meta.transform_data = transform_data;

    const frame_offset = br.totalBitsConsumed() / 8;
    try testing.expectEqualSlices(u8, frame_writer.bytes(), bytes[2 + frame_offset ..]);
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
    defer frame_dec.deinit();
    try frame_dec.decodeFrame(bytes[2 + frame_offset ..]);

    const image = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 1), image.channels.items.len);
    try testing.expectEqual(@as(usize, 3), image.w);
    try testing.expectEqual(@as(usize, 3), image.h);
    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeCodestream round-trips an RGB codestream through header parse and FrameDecoder" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_4x4.jxl");
    const prepared = try prepareFrame(source_data);

    var codec_meta = prepared.codec_meta;
    codec_meta.size = .{
        .small = false,
        .ysize_raw = 2,
        .ratio = 0,
        .xsize_raw = 3,
    };

    const frame_header = blk: {
        var br = BitReader.init(prepared.frame_data);
        break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    };

    var source = try modular_image.Image.create(allocator, 3, 2, 8, 3);
    defer source.deinit();

    source.channels.items[0].row(0)[0] = 10;
    source.channels.items[0].row(0)[1] = 12;
    source.channels.items[0].row(0)[2] = 14;
    source.channels.items[0].row(1)[0] = 13;
    source.channels.items[0].row(1)[1] = 15;
    source.channels.items[0].row(1)[2] = 17;

    source.channels.items[1].row(0)[0] = 20;
    source.channels.items[1].row(0)[1] = 19;
    source.channels.items[1].row(0)[2] = 18;
    source.channels.items[1].row(1)[0] = 17;
    source.channels.items[1].row(1)[1] = 16;
    source.channels.items[1].row(1)[2] = 15;

    source.channels.items[2].row(0)[0] = 7;
    source.channels.items[2].row(0)[1] = 8;
    source.channels.items[2].row(0)[2] = 9;
    source.channels.items[2].row(1)[0] = 11;
    source.channels.items[2].row(1)[1] = 12;
    source.channels.items[2].row(1)[2] = 13;

    var dc_global = BitWriter.init(allocator);
    defer dc_global.deinit();
    try dc_global.write(1, 1); // DequantMatrices all_default
    try dc_global.write(1, 0); // no global tree
    try testing.expectEqual(@as(usize, 0), try enc_encoding.writeSingleNodeLocalTreeGroupImage(
        allocator,
        &source,
        .gradient,
        &dc_global,
    ));
    try dc_global.zeroPadToByte();

    const sections = [_][]const u8{dc_global.bytes()};
    var frame_writer = BitWriter.init(allocator);
    defer frame_writer.deinit();
    try enc_frame.writeFrame(&frame_header, &codec_meta, &sections, &frame_writer);
    try frame_writer.zeroPadToByte();

    var codestream = BitWriter.init(allocator);
    defer codestream.deinit();
    try writeCodestream(&codec_meta, frame_writer.bytes(), &codestream);
    try codestream.zeroPadToByte();

    const bytes = codestream.bytes();
    try testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try testing.expectEqual(@as(u8, 0x0A), bytes[1]);

    var br = BitReader.init(bytes[2..]);
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 3), size.xsize());
    try testing.expectEqual(@as(usize, 2), size.ysize());
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    try br.jumpToByteBoundary();

    var parsed_meta = image_metadata.CodecMetadata{};
    parsed_meta.m = metadata;
    parsed_meta.size = size;
    parsed_meta.transform_data = transform_data;

    const frame_offset = br.totalBitsConsumed() / 8;
    try testing.expectEqualSlices(u8, frame_writer.bytes(), bytes[2 + frame_offset ..]);
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
    defer frame_dec.deinit();
    try frame_dec.decodeFrame(bytes[2 + frame_offset ..]);

    const image = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 3), image.channels.items.len);
    try testing.expectEqual(@as(usize, 3), image.w);
    try testing.expectEqual(@as(usize, 2), image.h);

    for (source.channels.items, image.channels.items) |want, got| {
        try testing.expectEqualSlices(i32, want.data, got.data);
    }
}
