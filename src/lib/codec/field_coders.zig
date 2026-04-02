// Field coders: BitsCoder, U32Coder, U64Coder, F16Coder.
// Transliterated from lib/jxl/fields.h, lib/jxl/fields.cc, lib/jxl/field_encodings.h
//
// In C++, these are used via the Visitor pattern (virtual dispatch).
// In Zig, we provide direct read functions since we only need the decode path
// for now. The Visitor pattern can be replaced by comptime generics if the
// encoder needs shared serialization logic later.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const JxlError = @import("../base/status.zig").JxlError;
const float16_mod = @import("../base/float.zig");

// ── U32Distr ──

/// Distribution of U32 values for one particular selector.
/// Represents either a power-of-two-sized range, or a single value.
pub const U32Distr = struct {
    d: u32,

    const k_direct: u32 = 0x80000000;

    pub fn isDirect(self: U32Distr) bool {
        return (self.d & k_direct) != 0;
    }

    pub fn direct(self: U32Distr) u32 {
        return self.d & (k_direct - 1);
    }

    pub fn extraBits(self: U32Distr) u6 {
        return @intCast((self.d & 0x1F) + 1);
    }

    pub fn offset(self: U32Distr) u32 {
        return (self.d >> 5) & 0x3FFFFFF;
    }
};

/// A direct-coded 31-bit value occupying 2 bits in the bitstream.
pub fn val(value: u32) U32Distr {
    return .{ .d = value | U32Distr.k_direct };
}

/// Value - `offset` will be signaled in `bits` extra bits.
pub fn bitsOffset(nbits: u32, offset_val: u32) U32Distr {
    return .{ .d = ((nbits - 1) & 0x1F) + ((offset_val & 0x3FFFFFF) << 5) };
}

/// Value will be signaled in `nbits` extra bits.
pub fn bits(nbits: u32) U32Distr {
    return bitsOffset(nbits, 0);
}

// ── U32Enc ──

/// See U32Coder documentation. Contains 4 distributions, selected by 2-bit selector.
pub const U32Enc = struct {
    d: [4]U32Distr,

    pub fn init(d0: U32Distr, d1: U32Distr, d2: U32Distr, d3: U32Distr) U32Enc {
        return .{ .d = .{ d0, d1, d2, d3 } };
    }

    pub fn getDistr(self: U32Enc, selector: u2) U32Distr {
        return self.d[selector];
    }
};

// ── BitsCoder ──

pub const BitsCoder = struct {
    pub fn read(nbits: u5, reader: *BitReader) u32 {
        return @intCast(reader.readBits(nbits));
    }

    pub fn write(nbits: u5, value: u32, writer: anytype) !void {
        try writer.write(nbits, value);
    }
};

// ── U32Coder ──

pub const U32Coder = struct {
    pub fn read(enc: U32Enc, reader: *BitReader) u32 {
        const selector: u2 = @intCast(reader.readBits(2));
        const d = enc.getDistr(selector);
        if (d.isDirect()) {
            return d.direct();
        }
        return @as(u32, @intCast(reader.readBits(d.extraBits()))) + d.offset();
    }

    /// Chooses the shortest valid selector form for a field-coded integer and
    /// emits the selector plus payload bits in the same canonical layout the
    /// decoder expects.
    pub fn write(enc: U32Enc, value: u32, writer: anytype) !void {
        var found = false;
        var best_selector: u2 = 0;
        var best_extra_bits: u6 = 0;
        var best_extra_value: u32 = 0;
        var best_total_bits: usize = std.math.maxInt(usize);

        var selector_index: u8 = 0;
        while (selector_index < 4) : (selector_index += 1) {
            const selector: u2 = @intCast(selector_index);
            const d = enc.getDistr(selector);

            var extra_bits: u6 = 0;
            var extra_value: u32 = 0;
            if (d.isDirect()) {
                if (value != d.direct()) continue;
            } else {
                const offset = d.offset();
                if (value < offset) continue;
                const candidate = value - offset;
                const range = @as(u64, 1) << @intCast(d.extraBits());
                if (@as(u64, candidate) >= range) continue;
                extra_bits = d.extraBits();
                extra_value = candidate;
            }

            const total_bits = @as(usize, 2) + extra_bits;
            if (!found or total_bits < best_total_bits) {
                found = true;
                best_selector = selector;
                best_extra_bits = extra_bits;
                best_extra_value = extra_value;
                best_total_bits = total_bits;
            }
        }

        if (!found) return error.GenericError;

        try writer.write(2, best_selector);
        if (best_extra_bits != 0) {
            try writer.write(best_extra_bits, best_extra_value);
        }
    }
};

// ── U64Coder ──

pub const U64Coder = struct {
    pub fn read(reader: *BitReader) u64 {
        const selector = reader.readBits(2);
        if (selector == 0) return 0;
        if (selector == 1) return 1 + reader.readBits(4);
        if (selector == 2) return 17 + reader.readBits(8);

        // selector 3: varint, first 12 bits, then groups of 8, last group 4
        var result: u64 = reader.readBits(12);
        var shift: u6 = 12;
        while (reader.readBits(1) != 0) {
            if (shift == 60) {
                result |= @as(u64, reader.readBits(4)) << shift;
                break;
            }
            result |= @as(u64, reader.readBits(8)) << shift;
            shift += 8;
        }
        return result;
    }

    /// Emits the shortest standard JXL U64 encoding, matching the selector
    /// structure that `read` consumes on the decode side.
    pub fn write(value: u64, writer: anytype) !void {
        if (value == 0) {
            try writer.write(2, 0);
            return;
        }
        if (value <= 16) {
            try writer.write(2, 1);
            try writer.write(4, value - 1);
            return;
        }
        if (value <= 272) {
            try writer.write(2, 2);
            try writer.write(8, value - 17);
            return;
        }

        try writer.write(2, 3);
        try writer.write(12, value & 0xfff);

        var remaining = value >> 12;
        var shift: u6 = 12;
        while (remaining != 0) {
            try writer.write(1, 1);
            if (shift == 60) {
                try writer.write(4, remaining & 0xf);
                return;
            }

            try writer.write(8, remaining & 0xff);
            remaining >>= 8;
            shift += 8;
        }

        try writer.write(1, 0);
    }
};

// ── F16Coder ──

pub const F16Coder = struct {
    pub fn read(reader: *BitReader) JxlError!f32 {
        const bits16: u16 = @intCast(reader.readBits(16));
        const sign: u32 = bits16 >> 15;
        const biased_exp: u32 = (@as(u32, bits16) >> 10) & 0x1F;
        const mantissa: u32 = bits16 & 0x3FF;

        if (biased_exp == 31) return error.GenericError; // infinity or NaN

        // Subnormal or zero
        if (biased_exp == 0) {
            var v: f32 = (1.0 / 16384.0) * (@as(f32, @floatFromInt(mantissa)) * (1.0 / 1024.0));
            if (sign != 0) v = -v;
            return v;
        }

        // Normalized
        const biased_exp32 = biased_exp + (127 - 15);
        const mantissa32 = mantissa << (23 - 10);
        const bits32 = (sign << 31) | (biased_exp32 << 23) | mantissa32;
        return @bitCast(bits32);
    }

	pub fn write(value: f32, writer: anytype) !void {
		if (!std.math.isFinite(value)) return error.Unsupported;

		const value16: f16 = @floatCast(value);
		const bits16: u16 = @bitCast(value16);
		if (((bits16 >> 10) & 0x1F) == 0x1F) return error.Unsupported;

		try writer.write(16, bits16);
	}
};

// ── Enum reader ──

/// Reads an enum value using the standard JXL enum encoding:
/// 00 -> 0, 01 -> 1, 10xxxx -> 2..17, 11yyyyyy -> 18..81
pub fn readEnum(reader: *BitReader) u32 {
    const enc = U32Enc.init(val(0), val(1), bitsOffset(4, 2), bitsOffset(6, 18));
    return U32Coder.read(enc, reader);
}

pub fn writeEnum(value: u32, writer: anytype) !void {
    const enc = U32Enc.init(val(0), val(1), bitsOffset(4, 2), bitsOffset(6, 18));
    try U32Coder.write(enc, value, writer);
}

// ── Extensions reader ──

/// Reads the extensions field (U64 bitmask). If non-zero, reads per-extension
/// size U64s and skips past all extension data. Returns the extensions bitmask.
pub fn readExtensions(reader: *BitReader) u64 {
    const extensions = U64Coder.read(reader);
    if (extensions == 0) return 0;

    // For each set bit, read a U64 giving the number of extension bits.
    var total_bits: u64 = 0;
    var remaining = extensions;
    while (remaining != 0) {
        const ext_bits = U64Coder.read(reader);
        total_bits +|= ext_bits;
        remaining &= remaining - 1;
    }

    // Skip all extension data bits.
    if (total_bits > 0) {
        reader.skipBits(@intCast(total_bits));
    }
    return extensions;
}

/// Reads the AllDefault bit. Returns true if all fields are default (caller should return defaults).
pub fn readAllDefault(reader: *BitReader) bool {
    return reader.readBits(1) != 0;
}

pub fn writeExtensions(extensions: u64, writer: anytype) !void {
    if (extensions != 0) return error.Unsupported;
    try U64Coder.write(extensions, writer);
}

pub fn writeAllDefault(all_default: bool, writer: anytype) !void {
    try writer.write(1, @intFromBool(all_default));
}

// ── Tests ──

const testing = std.testing;

test "U32Distr val" {
    const d = val(42);
    try testing.expect(d.isDirect());
    try testing.expectEqual(@as(u32, 42), d.direct());
}

test "U32Distr bitsOffset" {
    const d = bitsOffset(8, 16);
    try testing.expect(!d.isDirect());
    try testing.expectEqual(@as(u5, 8), d.extraBits());
    try testing.expectEqual(@as(u32, 16), d.offset());
}

test "U32Distr bits" {
    const d = bits(4);
    try testing.expect(!d.isDirect());
    try testing.expectEqual(@as(u5, 4), d.extraBits());
    try testing.expectEqual(@as(u32, 0), d.offset());
}

test "U32Coder read direct" {
    // Selector 0 = 00, maps to Val(42) -> direct 42
    var data = [_]u8{ 0b00000000, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const enc = U32Enc.init(val(42), val(7), bits(4), bits(8));
    const result = U32Coder.read(enc, &br);
    try testing.expectEqual(@as(u32, 42), result);
}

test "U32Coder read with extra bits" {
    // Selector 2 = 10, maps to Bits(4) -> read 4 extra bits
    // Byte: bits 0-1 = 10 (selector 2), bits 2-5 = 0101 (value 5+offset)
    // Binary: 10 0101 00 = 0b00010110 reversed per bit-reading order
    // BitReader reads LSB first: selector = bits[0:1] = 10b reversed = 01b? No...
    // BitReader.readBits reads from LSB. Let me construct carefully.
    // We want selector=2 (binary 10). readBits(2) returns bits 0-1 of first byte.
    // To get 2, we need bits 0-1 = 10 binary, i.e. byte & 0x3 = 2 -> byte[0] = 0bxxxxxx10
    // Then 4 extra bits: readBits(4) returns next 4 bits = bits 2-5 of first byte.
    // To get value 5: bits 2-5 = 0101 -> byte = 0b00010110 = 0x16
    var data = [_]u8{ 0b00010110, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const enc = U32Enc.init(val(0), val(1), bits(4), bits(8));
    const result = U32Coder.read(enc, &br);
    try testing.expectEqual(@as(u32, 5), result);
}

test "U32Coder write round-trips direct and ranged values" {
    const enc = U32Enc.init(val(42), val(7), bits(4), bitsOffset(8, 32));
    const values = [_]u32{ 42, 7, 11, 200 };

    var writer = BitWriter.init(testing.allocator);
    defer writer.deinit();
    for (values) |value| {
        try U32Coder.write(enc, value, &writer);
    }
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    for (values) |value| {
        try testing.expectEqual(value, U32Coder.read(enc, &br));
    }
    try br.jumpToByteBoundary();
    try br.close();
}

test "U32Coder write handles 30-bit bitsOffset selectors" {
	const enc = U32Enc.init(bitsOffset(9, 1), bitsOffset(13, 1), bitsOffset(18, 1), bitsOffset(30, 1));
	const values = [_]u32{ 7, 9, 1024, 1_000_000 };

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	for (values) |value| {
		try U32Coder.write(enc, value, &writer);
	}
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	for (values) |value| {
		try testing.expectEqual(value, U32Coder.read(enc, &br));
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "U64Coder read zero" {
    // selector 0 = 00 -> value 0
    var data = [_]u8{ 0b00000000, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = U64Coder.read(&br);
    try testing.expectEqual(@as(u64, 0), result);
}

test "U64Coder read selector 1" {
    // selector 1 = 01, then 4 bits = 0101 = 5, result = 1+5 = 6
    // byte: 01 0101 xx = 0b_xx010101
    var data = [_]u8{ 0b00010101, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = U64Coder.read(&br);
    try testing.expectEqual(@as(u64, 6), result);
}

test "U64Coder read selector 2" {
    // selector 2 = 10, then 8 bits = 0 -> result = 17+0 = 17
    var data = [_]u8{ 0b00000010, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = U64Coder.read(&br);
    try testing.expectEqual(@as(u64, 17), result);
}

test "U64Coder write round-trips mixed values" {
    const values = [_]u64{ 0, 1, 16, 17, 42, 272, 273, 0x12345, 0x123456789abcdef };

    var writer = BitWriter.init(testing.allocator);
    defer writer.deinit();
    for (values) |value| {
        try U64Coder.write(value, &writer);
    }
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    for (values) |value| {
        try testing.expectEqual(value, U64Coder.read(&br));
    }
    try br.jumpToByteBoundary();
    try br.close();
}

test "F16Coder read zero" {
    // 0x0000 = positive zero
    var data = [_]u8{ 0x00, 0x00, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = try F16Coder.read(&br);
    try testing.expectEqual(@as(f32, 0.0), result);
}

test "F16Coder read one" {
    // f16 1.0 = 0x3C00 = 0011 1100 0000 0000
    // BitReader reads LSB first from bytes, so bytes are little-endian:
    // 0x3C00 LE = bytes 0x00, 0x3C
    var data = [_]u8{ 0x00, 0x3C, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = try F16Coder.read(&br);
    try testing.expectEqual(@as(f32, 1.0), result);
}

test "F16Coder read NaN returns error" {
    // f16 NaN = 0x7E00 = 0111 1110 0000 0000
    var data = [_]u8{ 0x00, 0x7E, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    try testing.expectError(error.GenericError, F16Coder.read(&br));
}

test "F16Coder write round-trips finite values" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	try F16Coder.write(1.0, &writer);
	try F16Coder.write(0.5, &writer);
	try F16Coder.write(0.25, &writer);
	try F16Coder.write(0.75, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	try testing.expectEqual(@as(f32, 1.0), try F16Coder.read(&br));
	try testing.expectEqual(@as(f32, 0.5), try F16Coder.read(&br));
	try testing.expectEqual(@as(f32, 0.25), try F16Coder.read(&br));
	try testing.expectEqual(@as(f32, 0.75), try F16Coder.read(&br));
}

test "readEnum values" {
    // Selector 0 = 00 -> value 0
    var data0 = [_]u8{ 0b00000000, 0, 0, 0, 0, 0, 0, 0 };
    var br0 = BitReader.init(&data0);
    try testing.expectEqual(@as(u32, 0), readEnum(&br0));

    // Selector 1 = 01 -> value 1
    var data1 = [_]u8{ 0b00000001, 0, 0, 0, 0, 0, 0, 0 };
    var br1 = BitReader.init(&data1);
    try testing.expectEqual(@as(u32, 1), readEnum(&br1));
}

test "writeEnum round-trips mixed values" {
    const values = [_]u32{ 0, 1, 2, 7, 13, 18, 47 };

    var writer = BitWriter.init(testing.allocator);
    defer writer.deinit();
    for (values) |value| {
        try writeEnum(value, &writer);
    }
    try writer.zeroPadToByte();

    var br = BitReader.init(writer.bytes());
    for (values) |value| {
        try testing.expectEqual(value, readEnum(&br));
    }
    try br.jumpToByteBoundary();
    try br.close();
}
