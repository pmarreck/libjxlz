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

const sf = @import("soft_float.zig");
const JxlError = @import("status.zig").JxlError;

/// Reconstruct bitstream F16 as a randomz soft-float without IEEE-754 arithmetic.
pub fn loadFloat16Fixed(bits: u16) JxlError!sf.Fixed {
	const sign = (bits >> 15) != 0;
	const exp: i32 = @intCast((bits >> 10) & 0x1F);
	const frac: i64 = bits & 0x3FF;
	if (exp == 31) return error.GenericError;
	var value: sf.Fixed = undefined;
	if (exp == 0) {
		if (frac == 0) return sf.Fixed.zero;
		value = sf.div(sf.fromInt(frac), sf.fromInt(@as(i64, 1) << 24));
	} else {
		value = sf.div(sf.fromInt(1024 + frac), sf.fromInt(1024));
		const new_e: i64 = @as(i64, value.e) + (exp - 15);
		if (new_e < std.math.minInt(i32) or new_e > std.math.maxInt(i32)) return error.GenericError;
		value.e = @intCast(new_e);
	}
	return if (sign) sf.neg(value) else value;
}
