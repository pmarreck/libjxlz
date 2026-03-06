// Pack/UnpackSigned utilities.
// Transliterated from lib/jxl/pack_signed.h

/// Encodes non-negative (X) into (2 * X), negative (-X) into (2 * X - 1)
pub fn packSigned(value: i32) u32 {
    const v: u32 = @bitCast(value);
    return (v << 1) ^ ((~v >> 31) -% 1);
}

/// Reverse of packSigned: unpackSigned(packSigned(X)) == X.
pub fn unpackSigned(value: u32) i32 {
    return @bitCast((value >> 1) ^ ((~value & 1) -% 1));
}

// ── Tests ──

const testing = @import("std").testing;

test "packSigned/unpackSigned roundtrip" {
    try testing.expectEqual(@as(u32, 0), packSigned(0));
    try testing.expectEqual(@as(u32, 2), packSigned(1));
    try testing.expectEqual(@as(u32, 1), packSigned(-1));
    try testing.expectEqual(@as(u32, 4), packSigned(2));
    try testing.expectEqual(@as(u32, 3), packSigned(-2));

    try testing.expectEqual(@as(i32, 0), unpackSigned(0));
    try testing.expectEqual(@as(i32, -1), unpackSigned(1));
    try testing.expectEqual(@as(i32, 1), unpackSigned(2));
    try testing.expectEqual(@as(i32, -2), unpackSigned(3));
    try testing.expectEqual(@as(i32, 2), unpackSigned(4));
}

test "packSigned/unpackSigned roundtrip extended" {
    const values = [_]i32{ 0, 1, -1, 2, -2, 100, -100, 32767, -32768, 2147483647, -2147483648 };
    for (values) |v| {
        try testing.expectEqual(v, unpackSigned(packSigned(v)));
    }
}
