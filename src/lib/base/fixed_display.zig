//! Round Fixed values to binary32 wire bits without IEEE arithmetic.
const sf = @import("soft_float.zig");
fn roundedShift(value: u64, shift: i64) u64 {
	if (shift <= 0) return value << @as(u6, @intCast(-shift));
	if (shift > 64) return 0;
	if (shift == 64) return @intFromBool(value > (@as(u64, 1) << 63));
	const n: u6 = @intCast(shift);
	const high = value >> n;
	const half = @as(u64, 1) << @as(u6, @intCast(shift - 1));
	const low = value & ((@as(u64, 1) << n) - 1);
	return high + @intFromBool(low > half or (low == half and high & 1 != 0));
}
pub fn bits(value: sf.Fixed) u32 {
	if (value.m == 0) return 0;
	const sign: u32 = if (value.m < 0) 0x80000000 else 0;
	const magnitude: u64 = @abs(value.m);
	const highest: i64 = 63 - @as(i64, @intCast(@clz(magnitude)));
	var exponent: i64 = @as(i64, value.e) - 62 + highest + 127;
	if (exponent >= 255) return sign | 0x7f800000;
	if (exponent <= 0) return sign | @as(u32, @intCast(roundedShift(magnitude, -@as(i64, value.e) - 87)));
	var mantissa = roundedShift(magnitude, highest - 23);
	if (mantissa == 1 << 24) {
		mantissa >>= 1;
		exponent += 1;
	}
	if (exponent >= 255) return sign | 0x7f800000;
	return sign | (@as(u32, @intCast(exponent)) << 23) | (@as(u32, @intCast(mantissa)) & 0x7fffff);
}
