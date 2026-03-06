// Codestream headers: SizeHeader, PreviewHeader, AnimationHeader.
// Transliterated from lib/jxl/headers.h and lib/jxl/headers.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");

pub const codestream_marker: u8 = 0x0A;

// ── Aspect ratio helpers ──

const Rational = struct {
    num: u32,
    den: u32,

    fn mulTruncate(self: Rational, multiplicand: u32) u32 {
        return @intCast(@as(u64, multiplicand) * self.num / self.den);
    }
};

const fixed_aspect_ratios = [7]Rational{
    .{ .num = 1, .den = 1 },   // square
    .{ .num = 12, .den = 10 }, //
    .{ .num = 4, .den = 3 },   // camera
    .{ .num = 3, .den = 2 },   // mobile camera
    .{ .num = 16, .den = 9 },  // camera/display
    .{ .num = 5, .den = 4 },   //
    .{ .num = 2, .den = 1 },   //
};

fn getAspectRatio(ratio: u32) Rational {
    std.debug.assert(ratio >= 1 and ratio <= 7);
    return fixed_aspect_ratios[ratio - 1];
}

// ── SizeHeader ──

/// Compact representation of image dimensions.
pub const SizeHeader = struct {
    small: bool = false,
    ysize_div8_minus_1: u32 = 0,
    ysize_raw: u32 = 0,
    ratio: u32 = 0,
    xsize_div8_minus_1: u32 = 0,
    xsize_raw: u32 = 0,

    pub fn ysize(self: SizeHeader) usize {
        if (self.small) return @as(usize, self.ysize_div8_minus_1 + 1) * 8;
        return self.ysize_raw;
    }

    pub fn xsize(self: SizeHeader) usize {
        if (self.ratio != 0) {
            return getAspectRatio(self.ratio).mulTruncate(@intCast(self.ysize()));
        }
        if (self.small) return @as(usize, self.xsize_div8_minus_1 + 1) * 8;
        return self.xsize_raw;
    }

    pub fn readFromBitStream(br: *BitReader) SizeHeader {
        var h = SizeHeader{};

        // small flag
        h.small = br.readBits(1) != 0;

        if (h.small) {
            h.ysize_div8_minus_1 = @intCast(br.readBits(5));
        } else {
            // U32(BitsOffset(9,1), BitsOffset(13,1), BitsOffset(18,1), BitsOffset(30,1))
            const enc = fc.U32Enc.init(
                fc.bitsOffset(9, 1),
                fc.bitsOffset(13, 1),
                fc.bitsOffset(18, 1),
                fc.bitsOffset(30, 1),
            );
            h.ysize_raw = fc.U32Coder.read(enc, br);
        }

        h.ratio = @intCast(br.readBits(3));

        if (h.ratio == 0 and h.small) {
            h.xsize_div8_minus_1 = @intCast(br.readBits(5));
        } else if (h.ratio == 0 and !h.small) {
            const enc = fc.U32Enc.init(
                fc.bitsOffset(9, 1),
                fc.bitsOffset(13, 1),
                fc.bitsOffset(18, 1),
                fc.bitsOffset(30, 1),
            );
            h.xsize_raw = fc.U32Coder.read(enc, br);
        }
        // If ratio != 0, xsize is computed from ysize via aspect ratio.

        return h;
    }
};

// ── PreviewHeader ──

pub const PreviewHeader = struct {
    div8: bool = false,
    ysize_div8: u32 = 0,
    ysize_raw: u32 = 0,
    ratio: u32 = 0,
    xsize_div8: u32 = 0,
    xsize_raw: u32 = 0,

    pub fn ysize(self: PreviewHeader) usize {
        if (self.div8) return @as(usize, self.ysize_div8) * 8;
        return self.ysize_raw;
    }

    pub fn xsize(self: PreviewHeader) usize {
        if (self.ratio != 0) {
            return getAspectRatio(self.ratio).mulTruncate(@intCast(self.ysize()));
        }
        if (self.div8) return @as(usize, self.xsize_div8) * 8;
        return self.xsize_raw;
    }

    pub fn readFromBitStream(br: *BitReader) PreviewHeader {
        var h = PreviewHeader{};

        h.div8 = br.readBits(1) != 0;

        if (h.div8) {
            const enc = fc.U32Enc.init(fc.val(16), fc.val(32), fc.bitsOffset(5, 1), fc.bitsOffset(9, 33));
            h.ysize_div8 = fc.U32Coder.read(enc, br);
        } else {
            const enc = fc.U32Enc.init(fc.bitsOffset(6, 1), fc.bitsOffset(8, 65), fc.bitsOffset(10, 321), fc.bitsOffset(12, 1345));
            h.ysize_raw = fc.U32Coder.read(enc, br);
        }

        h.ratio = @intCast(br.readBits(3));

        if (h.ratio == 0 and h.div8) {
            const enc = fc.U32Enc.init(fc.val(16), fc.val(32), fc.bitsOffset(5, 1), fc.bitsOffset(9, 33));
            h.xsize_div8 = fc.U32Coder.read(enc, br);
        } else if (h.ratio == 0 and !h.div8) {
            const enc = fc.U32Enc.init(fc.bitsOffset(6, 1), fc.bitsOffset(8, 65), fc.bitsOffset(10, 321), fc.bitsOffset(12, 1345));
            h.xsize_raw = fc.U32Coder.read(enc, br);
        }

        return h;
    }
};

// ── AnimationHeader ──

pub const AnimationHeader = struct {
    tps_numerator: u32 = 1,
    tps_denominator: u32 = 1,
    num_loops: u32 = 0,
    have_timecodes: bool = false,

    pub fn readFromBitStream(br: *BitReader) AnimationHeader {
        var h = AnimationHeader{};

        const tps_num_enc = fc.U32Enc.init(fc.val(100), fc.val(1000), fc.bitsOffset(10, 1), fc.bitsOffset(30, 1));
        h.tps_numerator = fc.U32Coder.read(tps_num_enc, br);

        const tps_den_enc = fc.U32Enc.init(fc.val(1), fc.val(1001), fc.bitsOffset(8, 1), fc.bitsOffset(10, 1));
        h.tps_denominator = fc.U32Coder.read(tps_den_enc, br);

        const loops_enc = fc.U32Enc.init(fc.val(0), fc.bits(3), fc.bits(16), fc.bits(32));
        h.num_loops = fc.U32Coder.read(loops_enc, br);

        h.have_timecodes = br.readBits(1) != 0;

        return h;
    }
};

// ── Tests ──

const testing = std.testing;

test "SizeHeader small 64x64" {
    // small=1, ysize_div8_minus_1=7 (64/8-1), ratio=0 (3 bits), xsize_div8_minus_1=7
    // Bits: 1, 00111, 000, 00111
    // = 1 00111 000 00111 xx
    // Byte 0 (bits 0-7): 1_00111_00 = 0b00_00111_1 reversed... let me think about bit order.
    // BitReader reads LSB first from bytes.
    // bit0 = small = 1
    // bits1-5 = ysize_div8_minus_1 = 7 = 0b00111
    // bits6-8 = ratio = 0 = 0b000
    // bits9-13 = xsize_div8_minus_1 = 7 = 0b00111
    // byte0 = bits[0:7] = 1_00111_00 reading right-to-left for LSB = 0b00_11100_1 = 0xE1...
    // Actually: bit0=1 is LSB. byte0 bits: b0=1, b1=1, b2=1, b3=1, b4=0, b5=0, b6=0, b7=0
    // ysize_div8_minus_1: readBits(5) reads bits1-5 = 11100 = 0x1C... that's 28 not 7.
    // Let me reconsider. readBits reads from the buffer which loads LE.
    // The buffer is loaded as a u64 LE from the byte array.
    // readBits(1) returns bit0 of buffer. readBits(5) returns bits1-5 of buffer.
    // For byte array [b0, b1, ...], the u64 LE value is b0 + b1*256 + ...
    // bit0 of the u64 = bit0 of b0
    // bits1-5 of the u64 = bits1-5 of b0 + possibly bit0 of b1
    //
    // I want: small=1 (bit0=1), ysize_div8_minus_1=7 (bits1-5=00111), ratio=0 (bits6-8=000),
    //         xsize_div8_minus_1=7 (bits9-13=00111)
    // byte0 = bit0..7: 1, then 7=0b00111 in bits1-5, then 0 in bits6-7
    // byte0: b0=1, b1=1, b2=1, b3=1, b4=0, b5=0, b6=0, b7=0 = 0x0F
    // byte1 = bit8..15: b8=0 (ratio bit2), then xsize_div8_minus_1=7=0b00111 in bits9-13, 0s
    // byte1: b0=0 (bit8=ratio[2]), b1=1, b2=1, b3=1, b4=0, b5=0, b6=0, b7=0 = 0x0E
    var data = [_]u8{ 0x0F, 0x0E, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const h = SizeHeader.readFromBitStream(&br);
    try testing.expect(h.small);
    try testing.expectEqual(@as(usize, 64), h.xsize());
    try testing.expectEqual(@as(usize, 64), h.ysize());
}

test "SizeHeader non-small" {
    // small=0, then U32 for ysize (selector + bits), then ratio, then U32 for xsize
    // U32Enc(BitsOffset(9,1), BitsOffset(13,1), BitsOffset(18,1), BitsOffset(30,1))
    // For ysize=100: selector=0 (bits00), then 9 bits = 100-1=99 = 0b001100011
    // For ratio=0: 3 bits = 000
    // For xsize=200: selector=0, then 9 bits = 200-1=199 = 0b011000111
    //
    // bit0 = small = 0
    // bits1-2 = ysize selector = 00
    // bits3-11 = ysize value = 99 = 0b001100011
    // bits12-14 = ratio = 000
    // bits15-16 = xsize selector = 00
    // bits17-25 = xsize value = 199 = 0b011000111
    //
    // byte0 (bits0-7): 0, 00, 00011 = b0=0, b1=0, b2=0, b3=1, b4=1, b5=0, b6=0, b7=0 = 0b00011000 reversed? No.
    // bit0=0 (small), bit1=0 (sel[0]), bit2=0 (sel[1]), bit3..11 = 99
    // 99 in 9 bits = 0b001100011
    // bit3=1, bit4=1, bit5=0, bit6=0, bit7=0
    // byte0 = 0b00011000 = 0x18... hmm
    // Actually: byte0 bits = 0_00_11000 = bits0-7 in order = 0,0,0,1,1,0,0,0 -> byte=0b00011000=0x18? No
    // LSB order: byte0 = bit0 | (bit1<<1) | (bit2<<2) | (bit3<<3) | ...
    // = 0 | 0 | 0 | (1<<3) | (1<<4) | 0 | 0 | 0 = 0x18
    // byte1: bit8=1, bit9=1, bit10=0, bit11=0, bit12=0, bit13=0, bit14=0, bit15=0 = 0b00000011 = 0x03
    // Wait, 99 = bits3-11. bit3=LSB of 99=1, bit4=1, bit5=0, bit6=0, bit7=1, bit8=1, bit9=0, bit10=0, bit11=0
    // 99 = 0b001100011. Bit3=1 (bit0 of 99), bit4=1, bit5=0, bit6=0, bit7=0, bit8=1, bit9=1, bit10=0, bit11=0
    // byte0 = 0 | 0 | 0 | (1<<3) | (1<<4) | 0 | 0 | 0 = 0x18
    // byte1: bit8=1 | (bit9=1)<<1 | (bit10=0)<<2 | (bit11=0)<<3 | (bit12=0)<<4 | (bit13=0)<<5 | (bit14=0)<<6 | (bit15=0)<<7 = 0x03
    // ratio (bits12-14) = 000, xsize sel (bits15-16) = 00
    // byte2: bit16=0, then xsize value 199=0b011000111
    // bit17=1, bit18=1, bit19=1, bit20=0, bit21=0, bit22=0, bit23=1
    // byte2 = 0 | (1<<1) | (1<<2) | (1<<3) | 0 | 0 | 0 | (1<<7) = 0b10001110 = 0x8E
    // byte3: bit24=1, bit25=0, ...
    // byte3 = 1 | 0 | ... = 0x01
    var data = [_]u8{ 0x18, 0x03, 0x8E, 0x01, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const h = SizeHeader.readFromBitStream(&br);
    try testing.expect(!h.small);
    try testing.expectEqual(@as(usize, 100), h.ysize());
    try testing.expectEqual(@as(usize, 200), h.xsize());
}

test "SizeHeader with aspect ratio" {
    // small=1, ysize_div8_minus_1=15 (128/8-1=15), ratio=1 (1:1), no xsize needed
    // bit0=1, bits1-5=15=0b01111, bits6-8=001
    // byte0: 1 | (1<<1) | (1<<2) | (1<<3) | (1<<4) | 0 | (1<<6) | 0 = 0b01011111 = 0x5F
    // Wait: bits1-5=15=0b01111. bit1=1,bit2=1,bit3=1,bit4=1,bit5=0.
    // bits6-8=1=0b001. bit6=1,bit7=0,bit8=0.
    // byte0 = 1|(1<<1)|(1<<2)|(1<<3)|(1<<4)|0|(1<<6)|0 = 0b01011111 = 0x5F
    var data = [_]u8{ 0x5F, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const h = SizeHeader.readFromBitStream(&br);
    try testing.expect(h.small);
    try testing.expectEqual(@as(usize, 128), h.ysize());
    try testing.expectEqual(@as(u32, 1), h.ratio);
    // ratio 1 = 1:1, so xsize = ysize = 128
    try testing.expectEqual(@as(usize, 128), h.xsize());
}

test "AnimationHeader defaults" {
    // tps_numerator: selector=0 -> Val(100), tps_denominator: selector=0 -> Val(1),
    // num_loops: selector=0 -> Val(0), have_timecodes=0
    // All selectors = 00, so bits: 00 00 00 0
    var data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const h = AnimationHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(u32, 100), h.tps_numerator);
    try testing.expectEqual(@as(u32, 1), h.tps_denominator);
    try testing.expectEqual(@as(u32, 0), h.num_loops);
    try testing.expect(!h.have_timecodes);
}
