// Encoder-side frame-shell helpers.
// Starts with a borrowed frame-header prefix so frame-level roundtrips can
// advance before full header serialization exists.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const fc = @import("field_coders.zig");
const frame_header_mod = @import("frame_header.zig");
const enc_toc = @import("enc_toc.zig");
const dec_frame = @import("dec_frame.zig");
const modular_image = @import("../modular/modular_image.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");
const pack_signed = @import("../base/pack_signed.zig");

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

fn expectBitsEqual(expected_source: []const u8, expected_bits: usize, actual_source: []const u8) !void {
    var expected = BitReader.init(expected_source);
    var actual = BitReader.init(actual_source);
    var remaining = expected_bits;
    while (remaining > 0) {
        const chunk = @min(remaining, BitWriter.kMaxBitsPerCall);
        try testing.expectEqual(expected.readBits(chunk), actual.readBits(chunk));
        remaining -= chunk;
    }
}

fn writeBlendingInfo(
    info: *const frame_header_mod.BlendingInfo,
    num_extra_channels: usize,
    is_partial_frame: bool,
    writer: *BitWriter,
) !void {
    const mode_enc = fc.U32Enc.init(
        fc.val(@intFromEnum(frame_header_mod.BlendMode.replace)),
        fc.val(@intFromEnum(frame_header_mod.BlendMode.add)),
        fc.val(@intFromEnum(frame_header_mod.BlendMode.blend)),
        fc.bitsOffset(2, 3),
    );
    try fc.U32Coder.write(mode_enc, @intFromEnum(info.mode), writer);

    if (num_extra_channels > 0 and
        (info.mode == .blend or info.mode == .alpha_weighted_add))
    {
        const alpha_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bitsOffset(3, 3));
        try fc.U32Coder.write(alpha_enc, info.alpha_channel, writer);
    }

    if ((num_extra_channels > 0 and
        (info.mode == .blend or info.mode == .alpha_weighted_add)) or
        info.mode == .mul)
    {
        try writer.write(1, @intFromBool(info.clamp));
    }

    if (info.mode != .replace or is_partial_frame) {
        const source_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
        try fc.U32Coder.write(source_enc, info.source, writer);
    }
}

fn writePasses(passes: *const frame_header_mod.Passes, writer: *BitWriter) !void {
    const num_passes_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.bitsOffset(3, 4));
    try fc.U32Coder.write(num_passes_enc, passes.num_passes, writer);

    if (passes.num_passes == 1) return;

    const num_downsample_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bitsOffset(1, 3));
    try fc.U32Coder.write(num_downsample_enc, passes.num_downsample, writer);

    for (0..passes.num_passes - 1) |i| {
        try writer.write(2, passes.shift[i]);
    }

    const downsample_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(4), fc.val(8));
    for (0..passes.num_downsample) |i| {
        try fc.U32Coder.write(downsample_enc, passes.downsample[i], writer);
    }

    const last_pass_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bits(3));
    for (0..passes.num_downsample) |i| {
        try fc.U32Coder.write(last_pass_enc, passes.last_pass[i], writer);
    }
}

fn computeIsPartialFrame(
    frame_header: *const frame_header_mod.FrameHeader,
    metadata: *const image_metadata.CodecMetadata,
) bool {
    if (!frame_header.custom_size_or_origin) return false;
    if (frame_header.frame_type != .regular_frame and frame_header.frame_type != .skip_progressive) return false;

    const image_xsize: i32 = @intCast(metadata.xsize());
    const image_ysize: i32 = @intCast(metadata.ysize());
    if (frame_header.frame_origin.x0 > 0) return true;
    if (frame_header.frame_origin.y0 > 0) return true;
    if (@as(i32, @intCast(frame_header.frame_size.xsize)) + frame_header.frame_origin.x0 < image_xsize) return true;
    if (@as(i32, @intCast(frame_header.frame_size.ysize)) + frame_header.frame_origin.y0 < image_ysize) return true;
    return false;
}

fn isDefaultLoopFilter(loop_filter: *const @import("loop_filter.zig").LoopFilter) bool {
    return loop_filter.gab and
        !loop_filter.gab_custom and
        loop_filter.gab_x_weight1 == 0 and
        loop_filter.gab_x_weight2 == 0 and
        loop_filter.gab_y_weight1 == 0 and
        loop_filter.gab_y_weight2 == 0 and
        loop_filter.gab_b_weight1 == 0 and
        loop_filter.gab_b_weight2 == 0 and
        loop_filter.epf_iters == 2 and
        !loop_filter.epf_sharp_custom and
        std.mem.eql(f32, &loop_filter.epf_sharp_lut, &[_]f32{0} ** @import("loop_filter.zig").kEpfSharpEntries) and
        !loop_filter.epf_weight_custom and
        std.mem.eql(f32, &loop_filter.epf_channel_scale, &[_]f32{ 0, 0, 0 }) and
        loop_filter.epf_pass1_zeroflush == 0 and
        loop_filter.epf_pass2_zeroflush == 0 and
        !loop_filter.epf_sigma_custom and
        loop_filter.epf_quant_mul == 0 and
        loop_filter.epf_pass0_sigma_scale == 0 and
        loop_filter.epf_pass2_sigma_scale == 0 and
        loop_filter.epf_border_sad_mul == 0 and
        loop_filter.epf_sigma_for_modular == 0 and
        loop_filter.extensions == 0;
}

fn isSimpleDisabledLoopFilter(loop_filter: *const @import("loop_filter.zig").LoopFilter) bool {
    return !loop_filter.gab and
        !loop_filter.gab_custom and
        loop_filter.gab_x_weight1 == 0 and
        loop_filter.gab_x_weight2 == 0 and
        loop_filter.gab_y_weight1 == 0 and
        loop_filter.gab_y_weight2 == 0 and
        loop_filter.gab_b_weight1 == 0 and
        loop_filter.gab_b_weight2 == 0 and
        loop_filter.epf_iters == 0 and
        !loop_filter.epf_sharp_custom and
        !loop_filter.epf_weight_custom and
        !loop_filter.epf_sigma_custom and
        loop_filter.epf_sigma_for_modular == 0 and
        loop_filter.extensions == 0;
}

fn writeLoopFilter(
    loop_filter: *const @import("loop_filter.zig").LoopFilter,
    writer: *BitWriter,
) !void {
    if (isDefaultLoopFilter(loop_filter)) {
        try fc.writeAllDefault(true, writer);
        return;
    }

    if (!isSimpleDisabledLoopFilter(loop_filter)) return error.Unsupported;

    try fc.writeAllDefault(false, writer);
    try writer.write(1, 0); // gab = false
    try writer.write(2, 0); // epf_iters = 0
    try fc.writeExtensions(0, writer);
}

/// Emits the currently-supported frame-header surface in native Zig instead of
/// borrowing fixture bits. This intentionally starts with the simple modular
/// path our encoder tests already exercise and rejects unsupported features.
pub fn writeFrameHeader(
    frame_header: *const frame_header_mod.FrameHeader,
    metadata: *const image_metadata.CodecMetadata,
    writer: *BitWriter,
) !void {
    if (frame_header.extensions != 0) return error.Unsupported;

    const num_extra_channels: usize = metadata.m.extra_channel_count;
    const is_partial_frame = computeIsPartialFrame(frame_header, metadata);

    try fc.writeAllDefault(false, writer);

    const frame_type_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
    try fc.U32Coder.write(frame_type_enc, @intFromEnum(frame_header.frame_type), writer);
    try writer.write(1, @intFromBool(frame_header.encoding == .modular));
    try fc.U64Coder.write(frame_header.flags, writer);

    if (metadata.m.xyb_encoded) {
        if (frame_header.color_transform != .xyb) return error.Unsupported;
    } else {
        const alternate: u1 = switch (frame_header.color_transform) {
            .none => 0,
            .ycbcr => 1,
            else => return error.Unsupported,
        };
        try writer.write(1, alternate);
    }

    if (frame_header.color_transform == .ycbcr and (frame_header.flags & frame_header_mod.FrameFlags.use_dc_frame) == 0) {
        for (frame_header.chroma_subsampling.channel_mode) |channel_mode| {
            try writer.write(2, channel_mode);
        }
    }

    if ((frame_header.flags & frame_header_mod.FrameFlags.use_dc_frame) == 0) {
        const upsampling_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(4), fc.val(8));
        try fc.U32Coder.write(upsampling_enc, frame_header.upsampling, writer);

        for (0..num_extra_channels) |i| {
            const dim_shift = metadata.m.extra_channel_info[i].dim_shift;
            const ec_upsampling = frame_header.extra_channel_upsampling[i] >> @intCast(dim_shift);
            try fc.U32Coder.write(upsampling_enc, ec_upsampling, writer);
        }
    }

    if (frame_header.encoding == .modular) {
        try writer.write(2, frame_header.group_size_shift);
    } else if (frame_header.color_transform == .xyb) {
        try writer.write(3, frame_header.x_qm_scale);
        try writer.write(3, frame_header.b_qm_scale);
    }

    if (frame_header.frame_type != .reference_only) {
        try writePasses(&frame_header.passes, writer);
    }

    if (frame_header.frame_type == .dc_frame) {
        const dc_level_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.val(4));
        try fc.U32Coder.write(dc_level_enc, frame_header.dc_level, writer);
    }

    if (frame_header.frame_type != .dc_frame) {
        try writer.write(1, @intFromBool(frame_header.custom_size_or_origin));
        if (frame_header.custom_size_or_origin) {
            const size_enc = fc.U32Enc.init(
                fc.bits(8),
                fc.bitsOffset(11, 256),
                fc.bitsOffset(14, 2304),
                fc.bitsOffset(30, 18688),
            );

            if (frame_header.frame_type == .regular_frame or frame_header.frame_type == .skip_progressive) {
                try fc.U32Coder.write(size_enc, pack_signed.packSigned(frame_header.frame_origin.x0), writer);
                try fc.U32Coder.write(size_enc, pack_signed.packSigned(frame_header.frame_origin.y0), writer);
            }
            try fc.U32Coder.write(size_enc, frame_header.frame_size.xsize, writer);
            try fc.U32Coder.write(size_enc, frame_header.frame_size.ysize, writer);
        }
    }

    if (frame_header.frame_type == .regular_frame or frame_header.frame_type == .skip_progressive) {
        try writeBlendingInfo(&frame_header.blending_info, num_extra_channels, is_partial_frame, writer);
        for (0..num_extra_channels) |i| {
            try writeBlendingInfo(&frame_header.extra_channel_blending_info[i], num_extra_channels, is_partial_frame, writer);
        }

        if (metadata.m.have_animation) {
            const duration_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.bits(8), fc.bits(32));
            try fc.U32Coder.write(duration_enc, frame_header.animation_frame.duration, writer);
            if (metadata.m.animation.have_timecodes) {
                try writer.write(32, frame_header.animation_frame.timecode);
            }
        }

        try writer.write(1, @intFromBool(frame_header.is_last));
    }

    if (frame_header.frame_type != .dc_frame and !frame_header.is_last) {
        const save_ref_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
        try fc.U32Coder.write(save_ref_enc, frame_header.save_as_reference, writer);
    }

    if (frame_header.frame_type != .dc_frame) {
        const should_write_save_before =
            ((frame_header.canBeReferenced() and
                frame_header.blending_info.mode == .replace and
                !is_partial_frame and
                (frame_header.frame_type == .regular_frame or frame_header.frame_type == .skip_progressive)) or
                frame_header.frame_type == .reference_only);
        if (should_write_save_before) {
            try writer.write(1, @intFromBool(frame_header.save_before_color_transform));
        }
    }

    const name_len_enc = fc.U32Enc.init(fc.val(0), fc.bits(4), fc.bitsOffset(5, 16), fc.bitsOffset(10, 48));
    try fc.U32Coder.write(name_len_enc, frame_header.name_len, writer);
    for (0..frame_header.name_len) |i| {
        try writer.write(8, frame_header.name_buf[i]);
    }

    try writeLoopFilter(&frame_header.loop_filter, writer);
    try fc.writeExtensions(0, writer);
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

/// Writes a frame using the native Zig frame-header serializer, then appends a
/// fresh TOC and raw section bytes for the caller-provided payload sections.
pub fn writeFrame(
    frame_header: *const frame_header_mod.FrameHeader,
    codec_meta: *const image_metadata.CodecMetadata,
    section_payloads: []const []const u8,
    writer: *BitWriter,
) !void {
    try writeFrameHeader(frame_header, codec_meta, writer);

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

test "writeFrameHeader matches simple RGB fixture bits" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_4x4.jxl");
    const prepared = try prepareFrame(source_data);
    const frame_header_bits = try extractFrameHeaderBits(prepared.frame_data, &prepared.codec_meta);

    var header_br = BitReader.init(prepared.frame_data);
    const frame_header = try frame_header_mod.FrameHeader.readFromBitStream(&header_br, &prepared.codec_meta, false);

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try writeFrameHeader(&frame_header, &prepared.codec_meta, &writer);
    try writer.zeroPadToByte();

    try testing.expectEqual(frame_header_bits, writer.bitsWritten() - ((8 - (frame_header_bits % 8)) % 8));
    try expectBitsEqual(prepared.frame_data, frame_header_bits, writer.bytes());
}

test "writeFrameHeader matches simple grayscale fixture bits" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const prepared = try prepareFrame(source_data);
    const frame_header_bits = try extractFrameHeaderBits(prepared.frame_data, &prepared.codec_meta);

    var header_br = BitReader.init(prepared.frame_data);
    const frame_header = try frame_header_mod.FrameHeader.readFromBitStream(&header_br, &prepared.codec_meta, false);

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try writeFrameHeader(&frame_header, &prepared.codec_meta, &writer);
    try writer.zeroPadToByte();

    try testing.expectEqual(frame_header_bits, writer.bitsWritten() - ((8 - (frame_header_bits % 8)) % 8));
    try expectBitsEqual(prepared.frame_data, frame_header_bits, writer.bytes());
}

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

test "writeFrame round-trips a grayscale image through FrameDecoder" {
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

    var header_br = BitReader.init(prepared.frame_data);
    const frame_header = try frame_header_mod.FrameHeader.readFromBitStream(&header_br, &codec_meta, false);

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
    try writeFrame(&frame_header, &codec_meta, &sections, &frame_writer);
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
