// Hybrid unsigned integer encoding/decoding.
// Transliterated from lib/jxl/dec_ans.h (HybridUintConfig)

const std = @import("std");
const bits_mod = @import("../base/bits.zig");

/// Split-exponent scheme for variable-length integers.
/// Dedicated tokens for the smallest (1 << split_exponent) numbers,
/// and for larger numbers encodes (number of bits) + (msb_in_token sub-leading
/// binary digits) + (lsb_in_token lowest binary digits) in the token,
/// with the remaining bits encoded as extra data.
pub const HybridUintConfig = struct {
    split_exponent: u32,
    split_token: u32,
    msb_in_token: u32,
    lsb_in_token: u32,

    pub fn init(split_exponent: u32, msb_in_token: u32, lsb_in_token: u32) HybridUintConfig {
        std.debug.assert(split_exponent >= msb_in_token + lsb_in_token);
        return .{
            .split_exponent = split_exponent,
            .split_token = @as(u32, 1) << @intCast(split_exponent),
            .msb_in_token = msb_in_token,
            .lsb_in_token = lsb_in_token,
        };
    }

    pub fn initDefault() HybridUintConfig {
        return init(4, 2, 0);
    }

    pub fn initZero() HybridUintConfig {
        return init(0, 0, 0);
    }

    pub const EncodeResult = struct {
        token: u32,
        nbits: u32,
        bits: u32,
    };

    pub fn encode(self: HybridUintConfig, value: u32) EncodeResult {
        if (value < self.split_token) {
            return .{ .token = value, .nbits = 0, .bits = 0 };
        }
        const n = bits_mod.floorLog2Nonzero(value);
        const m = value - (@as(u32, 1) << @intCast(n));
        const token = self.split_token +
            ((n - self.split_exponent) << @intCast(self.msb_in_token + self.lsb_in_token)) +
            ((m >> @intCast(n - self.msb_in_token)) << @intCast(self.lsb_in_token)) +
            (m & ((@as(u32, 1) << @intCast(self.lsb_in_token)) - 1));
        const nbits = n - self.msb_in_token - self.lsb_in_token;
        const extra_bits = (value >> @intCast(self.lsb_in_token)) & ((@as(u32, 1) << @intCast(nbits)) - 1);
        return .{ .token = token, .nbits = nbits, .bits = extra_bits };
    }

    /// Decodes a hybrid uint from a token and extra bits (from bitstream peek).
    /// This is the fast-track decode path matching C++ ReadHybridUintConfig.
    pub fn decode(self: HybridUintConfig, token: usize, peek_bits: usize, consume: *usize) u32 {
        if (token < self.split_token) {
            consume.* = 0;
            return @intCast(token);
        }
        var nbits: u32 = self.split_exponent - (self.msb_in_token + self.lsb_in_token) +
            @as(u32, @intCast((token - self.split_token) >> @intCast(self.msb_in_token + self.lsb_in_token)));
        nbits &= 31;
        const low: u32 = @intCast(token & ((@as(usize, 1) << @intCast(self.lsb_in_token)) - 1));
        const shifted_token = token >> @intCast(self.lsb_in_token);
        const bits_val: u32 = @intCast(peek_bits & ((@as(usize, 1) << @intCast(nbits)) - 1));
        consume.* = nbits;
        const msb_mask = (@as(u32, 1) << @intCast(self.msb_in_token)) - 1;
        const ret = ((((@as(u32, 1) << @intCast(self.msb_in_token)) |
            @as(u32, @intCast(shifted_token & msb_mask))) << @intCast(nbits)) | bits_val) << @intCast(self.lsb_in_token) | low;
        return ret;
    }

    pub fn lsbMask(self: HybridUintConfig) u32 {
        return (@as(u32, 1) << @intCast(self.lsb_in_token)) - 1;
    }
};

// ── Tests ──

const testing = std.testing;

test "HybridUintConfig default" {
    const cfg = HybridUintConfig.initDefault();
    try testing.expectEqual(@as(u32, 4), cfg.split_exponent);
    try testing.expectEqual(@as(u32, 16), cfg.split_token);
    try testing.expectEqual(@as(u32, 2), cfg.msb_in_token);
    try testing.expectEqual(@as(u32, 0), cfg.lsb_in_token);
}

test "HybridUintConfig encode small values" {
    const cfg = HybridUintConfig.initDefault();
    // Values below split_token are direct
    for (0..16) |v| {
        const result = cfg.encode(@intCast(v));
        try testing.expectEqual(@as(u32, @intCast(v)), result.token);
        try testing.expectEqual(@as(u32, 0), result.nbits);
    }
}

test "HybridUintConfig encode larger values" {
    const cfg = HybridUintConfig.init(4, 2, 0);
    // N = 16 (10000): token=16, nbits=2, bits=00
    const r16 = cfg.encode(16);
    try testing.expectEqual(@as(u32, 16), r16.token);
    try testing.expectEqual(@as(u32, 2), r16.nbits);
    try testing.expectEqual(@as(u32, 0), r16.bits);

    // N = 17 (10001): token=16, nbits=2, bits=01
    const r17 = cfg.encode(17);
    try testing.expectEqual(@as(u32, 16), r17.token);
    try testing.expectEqual(@as(u32, 2), r17.nbits);
    try testing.expectEqual(@as(u32, 1), r17.bits);

    // N = 20 (10100): token=17, nbits=2, bits=00
    const r20 = cfg.encode(20);
    try testing.expectEqual(@as(u32, 17), r20.token);
    try testing.expectEqual(@as(u32, 2), r20.nbits);
    try testing.expectEqual(@as(u32, 0), r20.bits);
}

test "HybridUintConfig encode-decode roundtrip" {
    const cfg = HybridUintConfig.initDefault();
    // Test roundtrip for values 0..100
    for (0..100) |v| {
        const enc = cfg.encode(@intCast(v));
        var consumed: usize = 0;
        const dec = cfg.decode(enc.token, enc.bits, &consumed);
        try testing.expectEqual(@as(u32, @intCast(v)), dec);
        try testing.expectEqual(@as(usize, enc.nbits), consumed);
    }
}

test "HybridUintConfig zero config" {
    const cfg = HybridUintConfig.initZero();
    try testing.expectEqual(@as(u32, 0), cfg.split_exponent);
    try testing.expectEqual(@as(u32, 1), cfg.split_token);
    // Value 0 is direct
    const r0 = cfg.encode(0);
    try testing.expectEqual(@as(u32, 0), r0.token);
    try testing.expectEqual(@as(u32, 0), r0.nbits);
}
