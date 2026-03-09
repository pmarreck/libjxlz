// Encoder-side frame-shell helpers.
// Starts with a borrowed frame-header prefix so frame-level roundtrips can
// advance before full header serialization exists.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const enc_toc = @import("enc_toc.zig");
const dec_frame = @import("dec_frame.zig");
const modular_image = @import("../modular/modular_image.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");

const Channel = modular_image.Channel;
const Predictor = @import("../modular/options.zig").Predictor;

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

fn extractFrameHeaderBits(frame_data: []const u8, codec_meta: *const image_metadata.CodecMetadata) !usize {
    var br = BitReader.init(frame_data);
    _ = try frame_header_mod.FrameHeader.readFromBitStream(&br, codec_meta, false);
    return br.totalBitsConsumed();
}

fn appendRawBits(writer: *BitWriter, source: []const u8, bit_count: usize) !void {
    var br = BitReader.init(source);
    var remaining = bit_count;
    while (remaining > 0) {
        const chunk = @min(remaining, BitWriter.kMaxBitsPerCall);
        try writer.write(chunk, br.readBits(chunk));
        remaining -= chunk;
    }
}

/// Reuses a proven frame-header bit prefix, then appends a fresh TOC and raw
/// section bytes so frame-level tests can exercise new payload writers before
/// full frame-header serialization exists.
pub fn writeBorrowedHeaderFrame(
    frame_header_source: []const u8,
    frame_header_bits: usize,
    section_payloads: []const []const u8,
    writer: *BitWriter,
) !void {
    try appendRawBits(writer, frame_header_source, frame_header_bits);

    const section_sizes = try writer.allocator.alloc(u32, section_payloads.len);
    defer writer.allocator.free(section_sizes);
    for (section_payloads, 0..) |payload, i| {
        if (payload.len > std.math.maxInt(u32)) return error.GenericError;
        section_sizes[i] = @intCast(payload.len);
    }

    try enc_toc.writeSimpleToc(section_sizes, writer);
    try writer.zeroPadToByte();

    for (section_payloads) |payload| {
        for (payload) |byte| {
            try writer.write(8, byte);
        }
    }
}

const testing = std.testing;

test "writeBorrowedHeaderFrame round-trips a grayscale image through FrameDecoder" {
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

    const frame_header_bits = try extractFrameHeaderBits(prepared.frame_data, &codec_meta);

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
    try writeBorrowedHeaderFrame(prepared.frame_data, frame_header_bits, &sections, &frame_writer);
    try frame_writer.zeroPadToByte();

    var frame_dec = dec_frame.FrameDecoder.init(allocator, &codec_meta);
    defer frame_dec.deinit();
    try frame_dec.decodeFrame(frame_writer.bytes());

    const image = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 1), image.channels.items.len);
    try testing.expectEqual(@as(usize, 3), image.w);
    try testing.expectEqual(@as(usize, 3), image.h);
    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}
