const std = @import("std");

/// Convert IEEE 754 half-precision (float16) bits to f32.
/// Matches the C++ jxl::detail::LoadFloat16 implementation.
pub fn loadFloat16(bits16: u16) f32 {
	const sign: u32 = @as(u32, bits16) >> 15;
	const biased_exp: u32 = (@as(u32, bits16) >> 10) & 0x1F;
	const mantissa: u32 = @as(u32, bits16) & 0x3FF;

	// Subnormal or zero
	if (biased_exp == 0) {
		const subnormal: f32 = (1.0 / 16384.0) * (@as(f32, @floatFromInt(mantissa)) * (1.0 / 1024.0));
		return if (sign != 0) -subnormal else subnormal;
	}

	// Normalized: convert representation directly
	const biased_exp32: u32 = if (biased_exp == 0x1F) 0xFF else biased_exp + (127 - 15);
	const mantissa32: u32 = mantissa << (23 - 10);
	const bits32: u32 = (sign << 31) | (biased_exp32 << 23) | mantissa32;

	return @bitCast(bits32);
}

test "float16 zero" {
	try std.testing.expectEqual(@as(f32, 0.0), loadFloat16(0x0000));
}

test "float16 negative zero" {
	// Negative zero
	const neg_zero = loadFloat16(0x8000);
	try std.testing.expect(neg_zero == 0.0); // -0.0 == 0.0 in IEEE
	try std.testing.expect(@as(u32, @bitCast(neg_zero)) == 0x80000000); // but sign bit is set
}

test "float16 one (0x3C00)" {
	try std.testing.expectEqual(@as(f32, 1.0), loadFloat16(0x3C00));
}

test "float16 negative one (0xBC00)" {
	try std.testing.expectEqual(@as(f32, -1.0), loadFloat16(0xBC00));
}

test "float16 subnormal (0x0001) is positive" {
	const val = loadFloat16(0x0001);
	try std.testing.expect(val > 0.0);
	// Smallest subnormal: 2^-14 * 2^-10 = 2^-24
	try std.testing.expectApproxEqAbs(@as(f32, 5.960464477539063e-8), val, 1e-15);
}

test "float16 infinity (0x7C00)" {
	const val = loadFloat16(0x7C00);
	try std.testing.expect(std.math.isInf(val));
	try std.testing.expect(val > 0);
}

test "float16 negative infinity (0xFC00)" {
	const val = loadFloat16(0xFC00);
	try std.testing.expect(std.math.isInf(val));
	try std.testing.expect(val < 0);
}

test "float16 NaN" {
	const val = loadFloat16(0x7C01);
	try std.testing.expect(std.math.isNan(val));
}

test "float16 two (0x4000)" {
	try std.testing.expectEqual(@as(f32, 2.0), loadFloat16(0x4000));
}

test "float16 half (0x3800)" {
	try std.testing.expectEqual(@as(f32, 0.5), loadFloat16(0x3800));
}
