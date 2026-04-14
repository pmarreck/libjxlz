// Color encoding metadata for color space conversions.
// Transliterated from lib/jxl/color_encoding_internal.h/.cc
// and lib/jxl/cms/color_encoding_cms.h

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");
const pack_signed = @import("../base/pack_signed.zig");

// ── Enums ──

pub const ColorSpace = enum(u32) {
    rgb = 0,
    gray = 1,
    xyb = 2,
    unknown = 3,
};

pub const WhitePoint = enum(u32) {
    d65 = 1,
    custom = 2,
    e = 10,
    dci = 11,
};

pub const Primaries = enum(u32) {
    srgb = 1,
    custom = 2,
    bt2100 = 9,
    p3 = 11,
};

pub const TransferFunction = enum(u32) {
    bt709 = 1,
    unknown = 2,
    linear = 8,
    srgb = 13,
    pq = 16,
    dci = 17,
    hlg = 18,
};

pub const RenderingIntent = enum(u32) {
    perceptual = 0,
    relative = 1,
    saturation = 2,
    absolute = 3,
};

// ── CIExy coordinate ──

pub const Customxy = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub fn readFromBitStream(br: *BitReader) Customxy {
        const xy_enc = fc.U32Enc.init(
            fc.bits(19),
            fc.bitsOffset(19, 524288),
            fc.bitsOffset(20, 1048576),
            fc.bitsOffset(21, 2097152),
        );
        const ux = fc.U32Coder.read(xy_enc, br);
        const uy = fc.U32Coder.read(xy_enc, br);
        return .{
            .x = pack_signed.unpackSigned(ux),
            .y = pack_signed.unpackSigned(uy),
        };
    }
};

/// Emits one custom CIExy pair using the same packed-signed U32 coding the
/// decoder consumes for custom white points and primaries.
pub fn writeCustomxy(xy: *const Customxy, writer: anytype) !void {
    const xy_enc = fc.U32Enc.init(
        fc.bits(19),
        fc.bitsOffset(19, 524288),
        fc.bitsOffset(20, 1048576),
        fc.bitsOffset(21, 2097152),
    );
    try fc.U32Coder.write(xy_enc, pack_signed.packSigned(xy.x), writer);
    try fc.U32Coder.write(xy_enc, pack_signed.packSigned(xy.y), writer);
}

// ── CustomTransferFunction ──

pub const CustomTransferFunction = struct {
    have_gamma: bool = false,
    gamma: u32 = kGammaMul, // gamma * 1e7
    transfer_function: TransferFunction = .srgb,

    const kGammaMul: u32 = 10000000;
    const kMaxGamma: u32 = 8192;

    pub fn readFromBitStream(br: *BitReader, color_space: ColorSpace) JxlError!CustomTransferFunction {
        // XYB implies gamma = 1/3, not serialized
        if (color_space == .xyb) {
            return .{
                .have_gamma = true,
                .gamma = @intFromFloat(@round(1.0 / 3.0 * @as(f64, kGammaMul))),
                .transfer_function = .unknown,
            };
        }

        var ctf = CustomTransferFunction{};
        ctf.have_gamma = br.readBits(1) != 0;

        if (ctf.have_gamma) {
            ctf.gamma = @intCast(br.readBits(24));
            if (ctf.gamma > kGammaMul or
                @as(u64, ctf.gamma) * kMaxGamma < kGammaMul)
            {
                return error.GenericError;
            }
        } else {
            const tf_val = fc.readEnum(br);
            ctf.transfer_function = enumFromU32(TransferFunction, tf_val) orelse
                return error.GenericError;
            if (ctf.transfer_function == .unknown) {
                return error.GenericError;
            }
        }

        return ctf;
    }
};

// ── ColorEncoding ──

pub const ColorEncoding = struct {
    want_icc: bool = false,
    color_space: ColorSpace = .rgb,
    white_point: WhitePoint = .d65,
    white: Customxy = .{},
    primaries: Primaries = .srgb,
    red: Customxy = .{},
    green: Customxy = .{},
    blue: Customxy = .{},
    tf: CustomTransferFunction = .{},
    rendering_intent: RenderingIntent = .relative,

    pub fn readFromBitStream(br: *BitReader) JxlError!ColorEncoding {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return ColorEncoding{};
        }

        var ce = ColorEncoding{};

        // want_icc
        ce.want_icc = br.readBits(1) != 0;

        // Color space (always sent, even if want_icc)
        const cs_val = fc.readEnum(br);
        ce.color_space = enumFromU32(ColorSpace, cs_val) orelse
            return error.GenericError;

        if (!ce.want_icc) {
            // White point (unless implicit for XYB)
            const implicit_wp = (ce.color_space == .xyb);
            if (implicit_wp) {
                ce.white_point = .d65;
            } else {
                const wp_val = fc.readEnum(br);
                ce.white_point = enumFromU32(WhitePoint, wp_val) orelse
                    return error.GenericError;
                if (ce.white_point == .custom) {
                    ce.white = Customxy.readFromBitStream(br);
                }
            }

            // Primaries (only if has primaries: RGB or unknown)
            const has_primaries = (ce.color_space != .gray and ce.color_space != .xyb);
            if (has_primaries) {
                const pr_val = fc.readEnum(br);
                ce.primaries = enumFromU32(Primaries, pr_val) orelse
                    return error.GenericError;
                if (ce.primaries == .custom) {
                    ce.red = Customxy.readFromBitStream(br);
                    ce.green = Customxy.readFromBitStream(br);
                    ce.blue = Customxy.readFromBitStream(br);
                }
            }

            // Transfer function
            ce.tf = try CustomTransferFunction.readFromBitStream(br, ce.color_space);

            // Rendering intent
            const ri_val = fc.readEnum(br);
            ce.rendering_intent = enumFromU32(RenderingIntent, ri_val) orelse
                return error.GenericError;

            // Validation: if no ICC, color space and tf must not be unknown
            if (ce.color_space == .unknown or
                (!ce.tf.have_gamma and ce.tf.transfer_function == .unknown))
            {
                return error.GenericError;
            }
        }

        return ce;
    }

    pub fn isGray(self: ColorEncoding) bool {
        return self.color_space == .gray;
    }

    pub fn channels(self: ColorEncoding) usize {
        return if (self.color_space == .gray) 1 else 3;
    }

    pub fn hasPrimaries(self: ColorEncoding) bool {
        return self.color_space != .gray and self.color_space != .xyb;
    }
};

fn isDefaultColorEncoding(ce: *const ColorEncoding) bool {
    return !ce.want_icc and
        ce.color_space == .rgb and
        ce.white_point == .d65 and
        ce.primaries == .srgb and
        !ce.tf.have_gamma and
        ce.tf.transfer_function == .srgb and
        ce.rendering_intent == .relative;
}

/// Emits the current non-ICC transfer-function surface, covering the standard
/// enum-coded transfer functions and the optional explicit gamma form.
pub fn writeCustomTransferFunction(tf: *const CustomTransferFunction, color_space: ColorSpace, writer: anytype) !void {
    if (color_space == .xyb) return;

    try writer.write(1, @intFromBool(tf.have_gamma));
    if (tf.have_gamma) {
        try writer.write(24, tf.gamma);
        return;
    }

    if (tf.transfer_function == .unknown) return error.Unsupported;
    try fc.writeEnum(@intFromEnum(tf.transfer_function), writer);
}

/// Emits the narrow color-encoding surface used by the current grayscale/RGB
/// modular fixtures: non-ICC, implicit/default chromaticities, and standard
/// transfer-function enums.
pub fn writeColorEncoding(ce: *const ColorEncoding, writer: anytype) !void {
    if (isDefaultColorEncoding(ce)) {
        try fc.writeAllDefault(true, writer);
        return;
    }

    try fc.writeAllDefault(false, writer);
    try writer.write(1, @intFromBool(ce.want_icc));
    try fc.writeEnum(@intFromEnum(ce.color_space), writer);

    if (ce.want_icc) return;

    if (ce.color_space != .xyb) {
        try fc.writeEnum(@intFromEnum(ce.white_point), writer);
        if (ce.white_point == .custom) {
            try writeCustomxy(&ce.white, writer);
        }
    }

    if (ce.hasPrimaries()) {
        try fc.writeEnum(@intFromEnum(ce.primaries), writer);
        if (ce.primaries == .custom) {
            try writeCustomxy(&ce.red, writer);
            try writeCustomxy(&ce.green, writer);
            try writeCustomxy(&ce.blue, writer);
        }
    }

    try writeCustomTransferFunction(&ce.tf, ce.color_space, writer);
    try fc.writeEnum(@intFromEnum(ce.rendering_intent), writer);
}

// ── Enum conversion helper ──

fn enumFromU32(comptime E: type, val: u32) ?E {
    return std.meta.intToEnum(E, val) catch null;
}

// ── Tests ──

const testing = std.testing;

test "ColorEncoding all default (sRGB)" {
    // AllDefault = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const ce = try ColorEncoding.readFromBitStream(&br);
    try testing.expect(!ce.want_icc);
    try testing.expectEqual(ColorSpace.rgb, ce.color_space);
    try testing.expectEqual(WhitePoint.d65, ce.white_point);
    try testing.expectEqual(Primaries.srgb, ce.primaries);
    try testing.expect(!ce.tf.have_gamma);
    try testing.expectEqual(TransferFunction.srgb, ce.tf.transfer_function);
    try testing.expectEqual(RenderingIntent.relative, ce.rendering_intent);
}

test "ColorEncoding want_icc with gray" {
    // AllDefault=0, want_icc=1, color_space enum=1 (gray)
    // readEnum: selector=01 -> Val(1) = gray
    // bits: 0, 1, 01
    // byte0: 0 | (1<<1) | (1<<2) | 0 = 0b00000110 = 0x06
    var data = [_]u8{ 0x06, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const ce = try ColorEncoding.readFromBitStream(&br);
    try testing.expect(ce.want_icc);
    try testing.expectEqual(ColorSpace.gray, ce.color_space);
}

test "ColorEncoding gray no ICC" {
    // AllDefault=0, want_icc=0, color_space=gray(1), no primaries for gray,
    // white_point default=d65(1), tf=srgb(default), rendering_intent=relative(default)
    // Enums use readEnum: Val(0), Val(1), BitsOffset(4,2), BitsOffset(6,18)
    //
    // bit0=0 (AllDefault)
    // bit1=0 (want_icc)
    // bit2-3=01 (enum selector for color_space -> Val(1)=gray)
    // white_point not implicit (gray != xyb):
    //   bit4-5=01 (enum selector for white_point -> Val(1)=d65)
    // no primaries (gray)
    // tf: not XYB, so read:
    //   bit6=0 (have_gamma=false)
    //   bit7-8=01 (enum selector -> Val(1)=bt709... hmm)
    //
    // Wait, tf default is srgb=13, so Val(0)=0, Val(1)=1. For srgb(13) we need
    // BitsOffset(4,2): selector=10, 4 bits = 13-2=11 = 0b1011
    // Or BitsOffset(6,18): not needed.
    // Actually readEnum: Val(0)->0, Val(1)->1, BitsOffset(4,2)->2..17, BitsOffset(6,18)->18..81
    // For srgb=13: selector=10, extra bits = 13-2 = 11 = 0b1011
    //
    // bit6=0 (have_gamma)
    // bit7-8=10 (tf enum selector -> BitsOffset(4,2))
    // bit9-12: extra bits encode 13-2=11=0b1011, LSB first: bit9=1,bit10=1,bit11=0,bit12=1
    // rendering_intent=relative(1):
    // bit13-14=01 (enum selector -> Val(1)=relative)
    //
    // byte0: bit0=0, bit1=0, bit2=1, bit3=0, bit4=1, bit5=0, bit6=0, bit7=0
    // byte0 = 0|(0<<1)|(1<<2)|(0<<3)|(1<<4)|(0<<5)|(0<<6)|(0<<7) = 0x14
    // byte1: bit8=1, bit9=1, bit10=1, bit11=0, bit12=1, bit13=1, bit14=0, bit15=0
    // byte1 = 1|(1<<1)|(1<<2)|(0<<3)|(1<<4)|(1<<5)|(0<<6)|(0<<7) = 0x37
    var data = [_]u8{ 0x14, 0x37, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const ce = try ColorEncoding.readFromBitStream(&br);
    try testing.expect(!ce.want_icc);
    try testing.expectEqual(ColorSpace.gray, ce.color_space);
    try testing.expectEqual(WhitePoint.d65, ce.white_point);
    try testing.expect(!ce.tf.have_gamma);
    try testing.expectEqual(TransferFunction.srgb, ce.tf.transfer_function);
    try testing.expectEqual(RenderingIntent.relative, ce.rendering_intent);
}

test "Customxy readFromBitStream" {
    // Both x and y encoded as packed signed via U32 encoding
    // Selector 0 = bits(19): read 19 bits
    // For x=0: packSigned(0) = 0, so 19 bits of 0, selector 00
    // For y=0: same
    // Total: 2 * (2 + 19) = 42 bits
    var data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const xy = Customxy.readFromBitStream(&br);
    try testing.expectEqual(@as(i32, 0), xy.x);
    try testing.expectEqual(@as(i32, 0), xy.y);
}

test "writeColorEncoding emits all-default for sRGB" {
    var writer = @import("../base/bit_writer.zig").BitWriter.init(testing.allocator);
    defer writer.deinit();

    const ce = ColorEncoding{};
    try writeColorEncoding(&ce, &writer);
    try writer.zeroPadToByte();

    try testing.expectEqual(@as(usize, 8), writer.bitsWritten());
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, writer.bytes());
}

test "writeColorEncoding matches gray no-ICC fixture bits" {
    const data = [_]u8{ 0x14, 0x37, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const ce = try ColorEncoding.readFromBitStream(&br);

    var writer = @import("../base/bit_writer.zig").BitWriter.init(testing.allocator);
    defer writer.deinit();
    try writeColorEncoding(&ce, &writer);
    try writer.zeroPadToByte();

    var want = BitReader.init(&data);
    var got = BitReader.init(writer.bytes());
    var remaining: usize = br.totalBitsConsumed();
    while (remaining > 0) {
        const chunk = @min(remaining, @import("../base/bit_writer.zig").BitWriter.kMaxBitsPerCall);
        try testing.expectEqual(want.readBits(chunk), got.readBits(chunk));
        remaining -= chunk;
    }
}

test "writeColorEncoding round-trips custom white point" {
    const ce = ColorEncoding{
        .white_point = .custom,
        .white = .{ .x = 321000, .y = 345000 },
    };

    var writer = @import("../base/bit_writer.zig").BitWriter.init(testing.allocator);
    defer writer.deinit();
    try writeColorEncoding(&ce, &writer);
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    const roundtrip = try ColorEncoding.readFromBitStream(&br);
    try testing.expectEqual(ColorSpace.rgb, roundtrip.color_space);
    try testing.expectEqual(WhitePoint.custom, roundtrip.white_point);
    try testing.expectEqual(@as(i32, 321000), roundtrip.white.x);
    try testing.expectEqual(@as(i32, 345000), roundtrip.white.y);
    try testing.expectEqual(Primaries.srgb, roundtrip.primaries);
}

test "writeColorEncoding round-trips custom primaries" {
    const ce = ColorEncoding{
        .primaries = .custom,
        .red = .{ .x = 680000, .y = 320000 },
        .green = .{ .x = 265000, .y = 690000 },
        .blue = .{ .x = 150000, .y = 45000 },
    };

    var writer = @import("../base/bit_writer.zig").BitWriter.init(testing.allocator);
    defer writer.deinit();
    try writeColorEncoding(&ce, &writer);
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    const roundtrip = try ColorEncoding.readFromBitStream(&br);
    try testing.expectEqual(Primaries.custom, roundtrip.primaries);
    try testing.expectEqual(@as(i32, 680000), roundtrip.red.x);
    try testing.expectEqual(@as(i32, 320000), roundtrip.red.y);
    try testing.expectEqual(@as(i32, 265000), roundtrip.green.x);
    try testing.expectEqual(@as(i32, 690000), roundtrip.green.y);
    try testing.expectEqual(@as(i32, 150000), roundtrip.blue.x);
    try testing.expectEqual(@as(i32, 45000), roundtrip.blue.y);
}

test "enumFromU32" {
    try testing.expectEqual(ColorSpace.rgb, enumFromU32(ColorSpace, 0).?);
    try testing.expectEqual(ColorSpace.gray, enumFromU32(ColorSpace, 1).?);
    try testing.expect(enumFromU32(ColorSpace, 99) == null);
}
