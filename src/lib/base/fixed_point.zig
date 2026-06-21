const std = @import("std");

fn saturateI64(value: i128) i64 {
	if (value > std.math.maxInt(i64)) return std.math.maxInt(i64);
	if (value < std.math.minInt(i64)) return std.math.minInt(i64);
	return @intCast(value);
}

fn absI128(value: i128) i128 {
	return if (value < 0) -value else value;
}

fn divRoundHalfAwayFromZero(numerator: i128, denominator: i128) i128 {
	std.debug.assert(denominator != 0);
	const negative = (numerator < 0) != (denominator < 0);
	const n = absI128(numerator);
	const d = absI128(denominator);
	const rounded = @divTrunc(n + @divTrunc(d, 2), d);
	return if (negative) -rounded else rounded;
}

/// Fixed-point signed decimal-like arithmetic for render and color paths that
/// need deterministic integer math instead of platform-sensitive float roundoff.
pub fn FixedPoint(comptime frac_bits: comptime_int) type {
	if (frac_bits < 0 or frac_bits > 62) @compileError("FixedPoint frac_bits must be 0...62");
	const scale: i64 = @as(i64, 1) << frac_bits;
	const scale_wide: i128 = scale;

	return struct {
		const Self = @This();

		raw: i64 = 0,

		pub fn zero() Self {
			return .{ .raw = 0 };
		}

		pub fn one() Self {
			return .{ .raw = scale };
		}

		pub fn fromRaw(raw: i64) Self {
			return .{ .raw = raw };
		}

		pub fn fromInt(value: i64) Self {
			return .{ .raw = saturateI64(@as(i128, value) * scale_wide) };
		}

		pub fn fromRatioRound(numerator: i64, denominator: i64) Self {
			std.debug.assert(denominator != 0);
			const scaled = @as(i128, numerator) * scale_wide;
			return .{ .raw = saturateI64(divRoundHalfAwayFromZero(scaled, denominator)) };
		}

		pub fn addSat(self: Self, other: Self) Self {
			return .{ .raw = saturateI64(@as(i128, self.raw) + other.raw) };
		}

		pub fn subSat(self: Self, other: Self) Self {
			return .{ .raw = saturateI64(@as(i128, self.raw) - other.raw) };
		}

		pub fn mulRound(self: Self, other: Self) Self {
			return .{ .raw = saturateI64(divRoundHalfAwayFromZero(@as(i128, self.raw) * other.raw, scale_wide)) };
		}

		pub fn divRound(self: Self, other: Self) Self {
			std.debug.assert(other.raw != 0);
			return .{ .raw = saturateI64(divRoundHalfAwayFromZero(@as(i128, self.raw) * scale_wide, other.raw)) };
		}

		pub fn clamp(self: Self, min_value: Self, max_value: Self) Self {
			return .{ .raw = std.math.clamp(self.raw, min_value.raw, max_value.raw) };
		}

		pub fn toNormalizedU8(self: Self) u8 {
			const clamped = self.clamp(Self.zero(), Self.one());
			const scaled = divRoundHalfAwayFromZero(@as(i128, clamped.raw) * 255, scale_wide);
			return @intCast(scaled);
		}
	};
}

const testing = std.testing;

test "FixedPoint converts ratios with half-away-from-zero rounding" {
	const Q8 = FixedPoint(8);
	try testing.expectEqual(@as(i64, 384), Q8.fromRatioRound(3, 2).raw);
	try testing.expectEqual(@as(i64, -384), Q8.fromRatioRound(-3, 2).raw);
	try testing.expectEqual(@as(i64, 1), Q8.fromRatioRound(1, 512).raw);
}

test "FixedPoint multiplies and divides without floating point" {
	const Q12 = FixedPoint(12);
	const half = Q12.fromRatioRound(1, 2);
	const quarter = Q12.fromRatioRound(1, 4);
	try testing.expectEqual(quarter.raw, half.mulRound(half).raw);
	try testing.expectEqual(half.raw, quarter.divRound(half).raw);
}

test "FixedPoint scales normalized samples to uint8" {
	const Q16 = FixedPoint(16);
	try testing.expectEqual(@as(u8, 0), Q16.zero().toNormalizedU8());
	try testing.expectEqual(@as(u8, 128), Q16.fromRatioRound(1, 2).toNormalizedU8());
	try testing.expectEqual(@as(u8, 255), Q16.one().toNormalizedU8());
	try testing.expectEqual(@as(u8, 255), Q16.fromInt(2).toNormalizedU8());
	try testing.expectEqual(@as(u8, 0), Q16.fromInt(-1).toNormalizedU8());
}
