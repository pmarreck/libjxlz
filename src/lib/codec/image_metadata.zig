// Image metadata: BitDepth, ExtraChannelInfo, ImageMetadata, CodecMetadata.
// Transliterated from lib/jxl/image_metadata.h and lib/jxl/image_metadata.cc
//
// Note: ColorEncoding reading is deferred — it requires its own complex module.
// For now, we stub it and skip those bits when encountered during full
// ImageMetadata parsing. The basic structural types (BitDepth, ExtraChannelInfo,
// CodecMetadata) are fully implemented for use by FrameHeader.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");
const headers = @import("headers.zig");
const color_encoding_mod = @import("color_encoding.zig");

// ── Orientation ──

pub const Orientation = enum(u32) {
    identity = 1,
    flip_horizontal = 2,
    rotate_180 = 3,
    flip_vertical = 4,
    transpose = 5,
    rotate_90 = 6,
    anti_transpose = 7,
    rotate_270 = 8,
};

// ── ExtraChannel type ──

pub const ExtraChannel = enum(u32) {
    alpha = 0,
    depth = 1,
    spot_color = 2,
    selection_mask = 3,
    black = 4, // CMYK
    cfa = 5,
    thermal = 6,
    reserved0 = 7,
    reserved1 = 8,
    reserved2 = 9,
    reserved3 = 10,
    reserved4 = 11,
    reserved5 = 12,
    reserved6 = 13,
    reserved7 = 14,
    unknown = 15,
    optional = 16,
};

// ── BitDepth ──

pub const BitDepth = struct {
    floating_point_sample: bool = false,
    bits_per_sample: u32 = 8,
    exponent_bits_per_sample: u32 = 0,

    pub fn readFromBitStream(br: *BitReader) JxlError!BitDepth {
        var bd = BitDepth{};

        bd.floating_point_sample = br.readBits(1) != 0;

        if (!bd.floating_point_sample) {
            // U32(Val(8), Val(10), Val(12), BitsOffset(6, 1))
            const enc = fc.U32Enc.init(fc.val(8), fc.val(10), fc.val(12), fc.bitsOffset(6, 1));
            bd.bits_per_sample = fc.U32Coder.read(enc, br);
            bd.exponent_bits_per_sample = 0;
        } else {
            // U32(Val(32), Val(16), Val(24), BitsOffset(6, 1))
            const enc = fc.U32Enc.init(fc.val(32), fc.val(16), fc.val(24), fc.bitsOffset(6, 1));
            bd.bits_per_sample = fc.U32Coder.read(enc, br);
            // Exponent bits: stored as (value - 1), in 4 bits, default 8-1=7
            const raw: u32 = @intCast(br.readBits(4));
            bd.exponent_bits_per_sample = raw + 1;
        }

        // Validation
        if (bd.floating_point_sample) {
            if (bd.exponent_bits_per_sample < 2 or bd.exponent_bits_per_sample > 8) {
                return error.GenericError;
            }
            const mantissa_bits: i32 = @as(i32, @intCast(bd.bits_per_sample)) -
                @as(i32, @intCast(bd.exponent_bits_per_sample)) - 1;
            if (mantissa_bits < 2 or mantissa_bits > 23) {
                return error.GenericError;
            }
        } else {
            if (bd.bits_per_sample > 31) {
                return error.GenericError;
            }
        }

        return bd;
    }
};

pub fn writeBitDepth(bit_depth: *const BitDepth, writer: anytype) !void {
    try writer.write(1, @intFromBool(bit_depth.floating_point_sample));

    if (!bit_depth.floating_point_sample) {
        const enc = fc.U32Enc.init(fc.val(8), fc.val(10), fc.val(12), fc.bitsOffset(6, 1));
        try fc.U32Coder.write(enc, bit_depth.bits_per_sample, writer);
        return;
    }

    const enc = fc.U32Enc.init(fc.val(32), fc.val(16), fc.val(24), fc.bitsOffset(6, 1));
    try fc.U32Coder.write(enc, bit_depth.bits_per_sample, writer);
    try writer.write(4, bit_depth.exponent_bits_per_sample - 1);
}

// ── ExtraChannelInfo ──

pub const ExtraChannelInfo = struct {
    type: ExtraChannel = .alpha,
    bit_depth: BitDepth = .{},
    dim_shift: u32 = 0,
    name: []const u8 = &.{},

    // Conditional fields
    alpha_associated: bool = false,
    spot_color: [4]f32 = .{ 0, 0, 0, 0 },
    cfa_channel: u32 = 0,

    // For reading, we store name bytes inline (up to 1071 bytes per spec)
    name_buf: [1071]u8 = undefined,
    name_len: u32 = 0,

    pub fn readFromBitStream(br: *BitReader) JxlError!ExtraChannelInfo {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return ExtraChannelInfo{};
        }

        var eci = ExtraChannelInfo{};

        // Type (enum encoding)
        const type_val = fc.readEnum(br);
        if (type_val > @intFromEnum(ExtraChannel.optional)) {
            return error.GenericError;
        }
        eci.type = @enumFromInt(type_val);

        // BitDepth (nested)
        eci.bit_depth = try BitDepth.readFromBitStream(br);

        // dim_shift: U32(Val(0), Val(3), Val(4), BitsOffset(3, 1))
        const ds_enc = fc.U32Enc.init(fc.val(0), fc.val(3), fc.val(4), fc.bitsOffset(3, 1));
        eci.dim_shift = fc.U32Coder.read(ds_enc, br);
        if ((@as(u32, 1) << @intCast(eci.dim_shift)) > 8) {
            return error.GenericError;
        }

        // Name string: U32(Val(0), Bits(4), BitsOffset(5,16), BitsOffset(10,48))
        const name_len_enc = fc.U32Enc.init(fc.val(0), fc.bits(4), fc.bitsOffset(5, 16), fc.bitsOffset(10, 48));
        eci.name_len = fc.U32Coder.read(name_len_enc, br);
        if (eci.name_len > 1071) return error.GenericError;
        for (0..eci.name_len) |i| {
            eci.name_buf[i] = @intCast(br.readBits(8));
        }
        eci.name = eci.name_buf[0..eci.name_len];

        // Conditional: alpha_associated
        if (eci.type == .alpha) {
            eci.alpha_associated = br.readBits(1) != 0;
        }

        // Conditional: spot_color
        if (eci.type == .spot_color) {
            for (0..4) |i| {
                eci.spot_color[i] = try fc.F16Coder.read(br);
            }
        }

        // Conditional: cfa_channel
        if (eci.type == .cfa) {
            const cfa_enc = fc.U32Enc.init(fc.val(1), fc.bits(2), fc.bitsOffset(4, 3), fc.bitsOffset(8, 19));
            eci.cfa_channel = fc.U32Coder.read(cfa_enc, br);
        }

        // Reject unknown/reserved types
        if (eci.type == .unknown or
            (@intFromEnum(eci.type) >= @intFromEnum(ExtraChannel.reserved0) and
            @intFromEnum(eci.type) <= @intFromEnum(ExtraChannel.reserved7)))
        {
            return error.GenericError;
        }

        return eci;
    }
};

fn isDefaultExtraChannelInfo(extra: *const ExtraChannelInfo) bool {
    return extra.type == .alpha and
        !extra.bit_depth.floating_point_sample and
        extra.bit_depth.bits_per_sample == 8 and
        extra.bit_depth.exponent_bits_per_sample == 0 and
        extra.dim_shift == 0 and
        extra.name.len == 0 and
        extra.name_len == 0 and
        !extra.alpha_associated and
        std.mem.eql(f32, &extra.spot_color, &[_]f32{ 0, 0, 0, 0 }) and
        extra.cfa_channel == 0;
}

fn isPlainExtraChannelType(extra_type: ExtraChannel) bool {
	return switch (extra_type) {
		.depth,
		.selection_mask,
		.black,
		.thermal,
		.optional,
		=> true,
		else => false,
	};
}

/// Starts the write-side extra-channel surface with the decoder's all-default
/// alpha channel, then grows into the explicit alpha-field form so codestream
/// writers can cover alpha plus the plain shared-field extra-channel family
/// before broader spot/CFA support exists.
pub fn writeExtraChannelInfo(extra: *const ExtraChannelInfo, writer: anytype) !void {
    if (isDefaultExtraChannelInfo(extra)) {
        try fc.writeAllDefault(true, writer);
        return;
    }

    if (extra.name_len != 0 and extra.name_len != extra.name.len) return error.Unsupported;
    if ((extra.type == .alpha and !std.mem.eql(f32, &extra.spot_color, &[_]f32{ 0, 0, 0, 0 })) or
        (extra.type == .alpha and extra.cfa_channel != 0))
    {
        return error.Unsupported;
    }
    if (isPlainExtraChannelType(extra.type)) {
        if (extra.alpha_associated) return error.Unsupported;
        if (!std.mem.eql(f32, &extra.spot_color, &[_]f32{ 0, 0, 0, 0 })) return error.Unsupported;
        if (extra.cfa_channel != 0) return error.Unsupported;
    } else if (extra.type != .alpha) {
        return error.Unsupported;
    }

    try fc.writeAllDefault(false, writer);
    try fc.writeEnum(@intFromEnum(extra.type), writer);
    try writeBitDepth(&extra.bit_depth, writer);

    const dim_shift_enc = fc.U32Enc.init(fc.val(0), fc.val(3), fc.val(4), fc.bitsOffset(3, 1));
    try fc.U32Coder.write(dim_shift_enc, extra.dim_shift, writer);

    const name_len: u32 = @intCast(extra.name.len);
    const name_len_enc = fc.U32Enc.init(fc.val(0), fc.bits(4), fc.bitsOffset(5, 16), fc.bitsOffset(10, 48));
    try fc.U32Coder.write(name_len_enc, name_len, writer);
    for (extra.name) |byte| {
        try writer.write(8, byte);
    }

    if (extra.type == .alpha) {
        try writer.write(1, @intFromBool(extra.alpha_associated));
    }
}

// ── ToneMapping ──

pub const ToneMapping = struct {
    intensity_target: f32 = 255.0, // kDefaultIntensityTarget
    min_nits: f32 = 0.0,
    relative_to_max_display: bool = false,
    linear_below: f32 = 0.0,

    pub fn readFromBitStream(br: *BitReader) JxlError!ToneMapping {
        if (fc.readAllDefault(br)) {
            return ToneMapping{};
        }

        var tm = ToneMapping{};
        tm.intensity_target = try fc.F16Coder.read(br);
        if (tm.intensity_target <= 0.0) return error.GenericError;

        tm.min_nits = try fc.F16Coder.read(br);
        if (tm.min_nits < 0.0 or tm.min_nits > tm.intensity_target) return error.GenericError;

        tm.relative_to_max_display = br.readBits(1) != 0;

        tm.linear_below = try fc.F16Coder.read(br);
        if (tm.linear_below < 0 or (tm.relative_to_max_display and tm.linear_below > 1.0)) {
            return error.GenericError;
        }

        return tm;
    }
};

fn isDefaultToneMapping(tone_mapping: *const ToneMapping) bool {
    return tone_mapping.intensity_target == 255.0 and
        tone_mapping.min_nits == 0.0 and
        !tone_mapping.relative_to_max_display and
        tone_mapping.linear_below == 0.0;
}

// ── ImageMetadata ──

pub const ImageMetadata = struct {
    bit_depth: BitDepth = .{},
    modular_16_bit_buffer_sufficient: bool = true,
    xyb_encoded: bool = true,
    orientation: u32 = 1,
    have_preview: bool = false,
    have_animation: bool = false,
    have_intrinsic_size: bool = false,

    intrinsic_size: headers.SizeHeader = .{},
    preview_size: headers.PreviewHeader = .{},
    animation: headers.AnimationHeader = .{},
    tone_mapping: ToneMapping = .{},
    color_encoding: color_encoding_mod.ColorEncoding = .{},

    num_extra_channels: u32 = 0,
    extra_channel_info: [256]ExtraChannelInfo = undefined,
    extra_channel_count: u32 = 0, // actual count of populated entries

    extensions: u64 = 0,

    pub fn readFromBitStream(br: *BitReader) JxlError!ImageMetadata {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return ImageMetadata{};
        }

        var m = ImageMetadata{};

        // Extra fields flag
        const extra_fields = br.readBits(1) != 0;
        if (extra_fields) {
            // Orientation: 3 bits, stored as (value - 1)
            m.orientation = @as(u32, @intCast(br.readBits(3))) + 1;

            // Intrinsic size
            m.have_intrinsic_size = br.readBits(1) != 0;
            if (m.have_intrinsic_size) {
                m.intrinsic_size = headers.SizeHeader.readFromBitStream(br);
            }

            // Preview
            m.have_preview = br.readBits(1) != 0;
            if (m.have_preview) {
                m.preview_size = headers.PreviewHeader.readFromBitStream(br);
            }

            // Animation
            m.have_animation = br.readBits(1) != 0;
            if (m.have_animation) {
                m.animation = headers.AnimationHeader.readFromBitStream(br);
            }
        } else {
            m.orientation = 1;
            m.have_intrinsic_size = false;
            m.have_preview = false;
            m.have_animation = false;
        }

        // BitDepth (nested, no AllDefault)
        m.bit_depth = try BitDepth.readFromBitStream(br);

        // modular_16_bit_buffer_sufficient
        m.modular_16_bit_buffer_sufficient = br.readBits(1) != 0;

        // num_extra_channels: U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(12,1))
        const ec_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.bitsOffset(4, 2), fc.bitsOffset(12, 1));
        m.num_extra_channels = fc.U32Coder.read(ec_enc, br);

        if (m.num_extra_channels != 0) {
            if (m.num_extra_channels > 256) return error.GenericError;
            m.extra_channel_count = m.num_extra_channels;
            for (0..m.num_extra_channels) |i| {
                m.extra_channel_info[i] = try ExtraChannelInfo.readFromBitStream(br);
            }
        }

        // xyb_encoded
        m.xyb_encoded = br.readBits(1) != 0;

        // ColorEncoding (nested with AllDefault)
        m.color_encoding = try color_encoding_mod.ColorEncoding.readFromBitStream(br);

        // ToneMapping (only if extra_fields)
        if (extra_fields) {
            m.tone_mapping = try ToneMapping.readFromBitStream(br);
        }

        // Extensions
        m.extensions = fc.readExtensions(br);

        return m;
    }

    pub fn getOrientation(self: ImageMetadata) Orientation {
        return @enumFromInt(self.orientation);
    }
};

/// Emits the currently-supported codestream metadata surface: no extra fields,
/// alpha extra channels, non-XYB grayscale/RGB color encodings, and no extensions.
pub fn writeImageMetadata(metadata: *const ImageMetadata, writer: anytype) !void {
    if (metadata.extensions != 0) return error.Unsupported;

    const tone_mapping_default = isDefaultToneMapping(&metadata.tone_mapping);
    const extra_fields = metadata.orientation != 1 or
        metadata.have_preview or
        metadata.have_animation or
        metadata.have_intrinsic_size or
        !tone_mapping_default;
    if (extra_fields) return error.Unsupported;

    try fc.writeAllDefault(false, writer);
    try writer.write(1, 0); // extra_fields = false
    try writeBitDepth(&metadata.bit_depth, writer);
    try writer.write(1, @intFromBool(metadata.modular_16_bit_buffer_sufficient));

    const extra_channels_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.bitsOffset(4, 2), fc.bitsOffset(12, 1));
    try fc.U32Coder.write(extra_channels_enc, metadata.num_extra_channels, writer);
    if (metadata.extra_channel_count != metadata.num_extra_channels) return error.Unsupported;
    for (0..metadata.extra_channel_count) |i| {
        try writeExtraChannelInfo(&metadata.extra_channel_info[i], writer);
    }

    try writer.write(1, @intFromBool(metadata.xyb_encoded));
    try color_encoding_mod.writeColorEncoding(&metadata.color_encoding, writer);
    try fc.writeExtensions(0, writer);
}

// ── CodecMetadata ──

pub const CodecMetadata = struct {
    m: ImageMetadata = .{},
    size: headers.SizeHeader = .{},
    transform_data: CustomTransformData = .{},

    pub fn xsize(self: CodecMetadata) usize {
        return self.size.xsize();
    }

    pub fn ysize(self: CodecMetadata) usize {
        return self.size.ysize();
    }
};

// ── OpsinInverseMatrix ──

pub const OpsinInverseMatrix = struct {
    inverse_matrix: [3][3]f32 = .{
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    },
    opsin_biases: [3]f32 = .{ 0, 0, 0 },
    quant_biases: [4]f32 = .{ 0, 0, 0, 0 },

    pub fn readFromBitStream(br: *BitReader) JxlError!OpsinInverseMatrix {
        if (fc.readAllDefault(br)) {
            return OpsinInverseMatrix{};
        }

        var m = OpsinInverseMatrix{};
        for (0..3) |j| {
            for (0..3) |i| {
                m.inverse_matrix[j][i] = try fc.F16Coder.read(br);
            }
        }
        for (0..3) |i| {
            m.opsin_biases[i] = try fc.F16Coder.read(br);
        }
        for (0..4) |i| {
            m.quant_biases[i] = try fc.F16Coder.read(br);
        }
        return m;
    }
};

// ── CustomTransformData ──

pub const CustomTransformData = struct {
    opsin_inverse_matrix: OpsinInverseMatrix = .{},
    custom_weights_mask: u32 = 0,
    upsampling2_weights: [15]f32 = [_]f32{0} ** 15,
    upsampling4_weights: [55]f32 = [_]f32{0} ** 55,
    upsampling8_weights: [210]f32 = [_]f32{0} ** 210,

    pub fn readFromBitStream(br: *BitReader, xyb_encoded: bool) JxlError!CustomTransformData {
        if (fc.readAllDefault(br)) {
            return CustomTransformData{};
        }

        var ctd = CustomTransformData{};

        // OpsinInverseMatrix (only if xyb_encoded)
        if (xyb_encoded) {
            ctd.opsin_inverse_matrix = try OpsinInverseMatrix.readFromBitStream(br);
        }

        // Custom weights mask (3 bits)
        ctd.custom_weights_mask = @intCast(br.readBits(3));

        // Upsampling 2x weights (15 values)
        if ((ctd.custom_weights_mask & 0x1) != 0) {
            for (0..15) |i| {
                ctd.upsampling2_weights[i] = try fc.F16Coder.read(br);
            }
        }

        // Upsampling 4x weights (55 values)
        if ((ctd.custom_weights_mask & 0x2) != 0) {
            for (0..55) |i| {
                ctd.upsampling4_weights[i] = try fc.F16Coder.read(br);
            }
        }

        // Upsampling 8x weights (210 values)
        if ((ctd.custom_weights_mask & 0x4) != 0) {
            for (0..210) |i| {
                ctd.upsampling8_weights[i] = try fc.F16Coder.read(br);
            }
        }

        return ctd;
    }
};

pub fn writeCustomTransformData(transform_data: *const CustomTransformData, xyb_encoded: bool, writer: anytype) !void {
    if (xyb_encoded) return error.Unsupported;
    if (transform_data.custom_weights_mask != 0) return error.Unsupported;
    try fc.writeAllDefault(true, writer);
}

// ── Tests ──

const testing = std.testing;

fn extractMetadataBits(data: []const u8) !struct {
    size: headers.SizeHeader,
    metadata: ImageMetadata,
    transform_data: CustomTransformData,
    offset_bits: usize,
    len_bits: usize,
} {
    var br = BitReader.init(data[2..]);
    const size = headers.SizeHeader.readFromBitStream(&br);
    const offset_bits = br.totalBitsConsumed();
    const metadata = try ImageMetadata.readFromBitStream(&br);
    const transform_data = try CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    const end_bits = br.totalBitsConsumed();
    return .{
        .size = size,
        .metadata = metadata,
        .transform_data = transform_data,
        .offset_bits = offset_bits,
        .len_bits = end_bits - offset_bits,
    };
}

fn expectBitsEqual(expected_source: []const u8, expected_offset_bits: usize, expected_bits: usize, actual_source: []const u8) !void {
    var expected = BitReader.init(expected_source);
    _ = expected.readBits(expected_offset_bits);
    var actual = BitReader.init(actual_source);
    var remaining = expected_bits;
    while (remaining > 0) {
        const chunk = @min(remaining, BitWriter.kMaxBitsPerCall);
        try testing.expectEqual(expected.readBits(chunk), actual.readBits(chunk));
        remaining -= chunk;
    }
}

test "writeImageMetadata plus CustomTransformData matches simple RGB fixture bits" {
    const allocator = testing.allocator;
    const data = @embedFile("../testdata/lossless_4x4.jxl");
    const extracted = try extractMetadataBits(data);

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try writeImageMetadata(&extracted.metadata, &writer);
    try writeCustomTransformData(&extracted.transform_data, extracted.metadata.xyb_encoded, &writer);
    try writer.zeroPadToByte();

    try testing.expectEqual(extracted.len_bits, writer.bitsWritten() - ((8 - (extracted.len_bits % 8)) % 8));
    try expectBitsEqual(data[2..], extracted.offset_bits, extracted.len_bits, writer.bytes());
}

test "writeImageMetadata plus CustomTransformData matches simple grayscale fixture bits" {
    const allocator = testing.allocator;
    const data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const extracted = try extractMetadataBits(data);

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try writeImageMetadata(&extracted.metadata, &writer);
    try writeCustomTransformData(&extracted.transform_data, extracted.metadata.xyb_encoded, &writer);
    try writer.zeroPadToByte();

    try testing.expectEqual(extracted.len_bits, writer.bitsWritten() - ((8 - (extracted.len_bits % 8)) % 8));
    try expectBitsEqual(data[2..], extracted.offset_bits, extracted.len_bits, writer.bytes());
}

test "writeImageMetadata round-trips a default alpha extra channel" {
    const allocator = testing.allocator;
    const data = @embedFile("../testdata/lossless_4x4.jxl");
    const extracted = try extractMetadataBits(data);

    var metadata = extracted.metadata;
    metadata.num_extra_channels = 1;
    metadata.extra_channel_count = 1;
    metadata.extra_channel_info[0] = .{};

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try writeImageMetadata(&metadata, &writer);
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    const roundtrip = try ImageMetadata.readFromBitStream(&br);
    try testing.expectEqual(@as(u32, 1), roundtrip.num_extra_channels);
    try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_count);
    try testing.expectEqual(ExtraChannel.alpha, roundtrip.extra_channel_info[0].type);
    try testing.expectEqual(@as(u32, 8), roundtrip.extra_channel_info[0].bit_depth.bits_per_sample);
    try testing.expect(!roundtrip.extra_channel_info[0].alpha_associated);
}

test "writeImageMetadata round-trips an associated alpha extra channel" {
	const allocator = testing.allocator;
	const data = @embedFile("../testdata/lossless_4x4.jxl");
	const extracted = try extractMetadataBits(data);

	var metadata = extracted.metadata;
	metadata.num_extra_channels = 1;
	metadata.extra_channel_count = 1;
	metadata.extra_channel_info[0] = .{ .alpha_associated = true };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeImageMetadata(&metadata, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	const roundtrip = try ImageMetadata.readFromBitStream(&br);
	try testing.expectEqual(@as(u32, 1), roundtrip.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_count);
	try testing.expectEqual(ExtraChannel.alpha, roundtrip.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 8), roundtrip.extra_channel_info[0].bit_depth.bits_per_sample);
	try testing.expect(roundtrip.extra_channel_info[0].alpha_associated);
}

test "writeImageMetadata round-trips a subsampled alpha extra channel" {
	const allocator = testing.allocator;
	const data = @embedFile("../testdata/lossless_4x4.jxl");
	const extracted = try extractMetadataBits(data);

	var metadata = extracted.metadata;
	metadata.num_extra_channels = 1;
	metadata.extra_channel_count = 1;
	metadata.extra_channel_info[0] = .{
		.dim_shift = 1,
		.name = "alpha-quarter",
		.name_len = "alpha-quarter".len,
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeImageMetadata(&metadata, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	const roundtrip = try ImageMetadata.readFromBitStream(&br);
	try testing.expectEqual(@as(u32, 1), roundtrip.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_count);
	try testing.expectEqual(ExtraChannel.alpha, roundtrip.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_info[0].dim_shift);
	try testing.expectEqualStrings("alpha-quarter", roundtrip.extra_channel_info[0].name);
	try testing.expect(!roundtrip.extra_channel_info[0].alpha_associated);
}

test "writeImageMetadata round-trips a selection-mask extra channel" {
	const allocator = testing.allocator;
	const data = @embedFile("../testdata/lossless_4x4.jxl");
	const extracted = try extractMetadataBits(data);

	var metadata = extracted.metadata;
	metadata.num_extra_channels = 1;
	metadata.extra_channel_count = 1;
	metadata.extra_channel_info[0] = .{
		.type = .selection_mask,
		.name = "mask",
		.name_len = "mask".len,
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeImageMetadata(&metadata, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	const roundtrip = try ImageMetadata.readFromBitStream(&br);
	try testing.expectEqual(@as(u32, 1), roundtrip.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_count);
	try testing.expectEqual(ExtraChannel.selection_mask, roundtrip.extra_channel_info[0].type);
	try testing.expectEqualStrings("mask", roundtrip.extra_channel_info[0].name);
}

test "writeImageMetadata round-trips a subsampled depth extra channel" {
	const allocator = testing.allocator;
	const data = @embedFile("../testdata/lossless_4x4.jxl");
	const extracted = try extractMetadataBits(data);

	var metadata = extracted.metadata;
	metadata.num_extra_channels = 1;
	metadata.extra_channel_count = 1;
	metadata.extra_channel_info[0] = .{
		.type = .depth,
		.dim_shift = 1,
		.name = "depth-half",
		.name_len = "depth-half".len,
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeImageMetadata(&metadata, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	const roundtrip = try ImageMetadata.readFromBitStream(&br);
	try testing.expectEqual(@as(u32, 1), roundtrip.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_count);
	try testing.expectEqual(ExtraChannel.depth, roundtrip.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), roundtrip.extra_channel_info[0].dim_shift);
	try testing.expectEqualStrings("depth-half", roundtrip.extra_channel_info[0].name);
}

test "BitDepth default (8-bit uint)" {
    // floating_point=0, selector=00 -> Val(8)
    // bits: 0, 00 = byte 0x00
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const bd = try BitDepth.readFromBitStream(&br);
    try testing.expect(!bd.floating_point_sample);
    try testing.expectEqual(@as(u32, 8), bd.bits_per_sample);
    try testing.expectEqual(@as(u32, 0), bd.exponent_bits_per_sample);
}

test "BitDepth 10-bit uint" {
    // floating_point=0, selector=01 -> Val(10)
    // bits: 0, 01 = 0b010 in bits 0-2
    // byte0: 0b00000010 = 0x02
    var data = [_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const bd = try BitDepth.readFromBitStream(&br);
    try testing.expect(!bd.floating_point_sample);
    try testing.expectEqual(@as(u32, 10), bd.bits_per_sample);
}

test "BitDepth float32" {
    // floating_point=1, selector=00 -> Val(32), then 4 bits for exponent_bits-1
    // default exponent_bits=8, so we encode 8-1=7 in 4 bits
    // But the C++ says: default is (8-offset)=(8-1)=7
    // bits: 1, 00, 0111 (=7 in 4 bits for exponent default)
    // byte0: 1 | (0<<1) | (0<<2) | (1<<3) | (1<<4) | (1<<5) | 0 | 0 = 0b00111001 = 0x39
    var data = [_]u8{ 0x39, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const bd = try BitDepth.readFromBitStream(&br);
    try testing.expect(bd.floating_point_sample);
    try testing.expectEqual(@as(u32, 32), bd.bits_per_sample);
    try testing.expectEqual(@as(u32, 8), bd.exponent_bits_per_sample);
}

test "ExtraChannelInfo all default" {
    // AllDefault bit = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const eci = try ExtraChannelInfo.readFromBitStream(&br);
    try testing.expectEqual(ExtraChannel.alpha, eci.type);
    try testing.expectEqual(@as(u32, 8), eci.bit_depth.bits_per_sample);
    try testing.expectEqual(@as(u32, 0), eci.dim_shift);
}

test "ToneMapping all default" {
    // AllDefault bit = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const tm = try ToneMapping.readFromBitStream(&br);
    try testing.expectEqual(@as(f32, 255.0), tm.intensity_target);
    try testing.expectEqual(@as(f32, 0.0), tm.min_nits);
    try testing.expect(!tm.relative_to_max_display);
}

test "ImageMetadata all default" {
    // AllDefault bit = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const m = try ImageMetadata.readFromBitStream(&br);
    try testing.expect(!m.have_preview);
    try testing.expect(!m.have_animation);
    try testing.expect(m.xyb_encoded);
    try testing.expectEqual(@as(u32, 8), m.bit_depth.bits_per_sample);
    try testing.expectEqual(@as(u32, 1), m.orientation);
    try testing.expectEqual(@as(u32, 0), m.num_extra_channels);
}

test "ImageMetadata non-default 8-bit no extras" {
    // AllDefault=0
    // extra_fields=0
    // BitDepth: float=0, selector=00 -> Val(8)
    // modular_16=1
    // num_extra=00 -> Val(0)
    // xyb_encoded=1
    // ColorEncoding: AllDefault=1
    // extensions: U64 sel=00 -> 0
    //
    // bit0=0 (AllDefault)
    // bit1=0 (extra_fields)
    // bit2=0, bit3-4=00 (BitDepth: float=0, sel=00)
    // bit5=1 (modular_16)
    // bit6-7=00 (num_extra sel -> Val(0))
    // byte0 = 0b00100000 = 0x20
    // bit8=1 (xyb_encoded)
    // bit9=1 (ColorEncoding AllDefault)
    // bit10-11=00 (extensions sel -> 0)
    // byte1 = 0b00000011 = 0x03
    var data = [_]u8{ 0x20, 0x03, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const m = try ImageMetadata.readFromBitStream(&br);
    try testing.expect(m.xyb_encoded);
    try testing.expectEqual(@as(u32, 8), m.bit_depth.bits_per_sample);
    try testing.expect(m.modular_16_bit_buffer_sufficient);
    try testing.expectEqual(@as(u32, 0), m.num_extra_channels);
}

test "CodecMetadata basic" {
    var cm = CodecMetadata{};
    cm.size = .{ .small = true, .ysize_div8_minus_1 = 7, .xsize_div8_minus_1 = 7 };
    try testing.expectEqual(@as(usize, 64), cm.xsize());
    try testing.expectEqual(@as(usize, 64), cm.ysize());
}
