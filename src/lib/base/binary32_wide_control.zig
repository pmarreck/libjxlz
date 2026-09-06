//! Exact integer FMA oracle with a 576-bit accumulator; test and benchmark only.
fn isNan(value: u32) bool {
	return value & 0x7fffffff > 0x7f800000;
}
pub fn fma(a: u32, b: u32, c: u32) u32 {
	const aa = a & 0x7fffffff;
	const bb = b & 0x7fffffff;
	const cc = c & 0x7fffffff;
	const product_sign = (a ^ b) & 0x80000000;
	if (isNan(a)) return a | 0x400000;
	if (isNan(b)) return b | 0x400000;
	if (isNan(c)) return c | 0x400000;
	if (aa == 0x7f800000 or bb == 0x7f800000) {
		if (aa == 0 or bb == 0 or (cc == 0x7f800000 and product_sign != c & 0x80000000)) return 0x7fc00000;
		return product_sign | 0x7f800000;
	}
	if (cc == 0x7f800000) return c;
	if ((aa == 0 or bb == 0) and cc == 0) return product_sign & c;
	// Every finite binary32 product is an integer multiple of 2^-298.
	// The largest product needs 554 bits at that scale. Keeping the exact sum
	// avoids intermediate overflow and preserves ties through cancellation.
	const left = finiteTerm(a);
	const right = finiteTerm(b);
	const extra = finiteTerm(c);
	const product: i576 = @as(i576, @as(u64, left.significand) * right.significand) << @intCast(left.exponent + right.exponent + 298);
	const addend: i576 = @as(i576, extra.significand) << @intCast(extra.exponent + 298);
	const sum = (if (product_sign != 0) -product else product) + (if (c >> 31 != 0) -addend else addend);
	if (sum == 0) return 0;
	const sign: u32 = if (sum < 0) 0x80000000 else 0;
	const magnitude: u576 = @intCast(if (sum < 0) -sum else sum);
	const high: i32 = 575 - @as(i32, @intCast(@clz(magnitude)));
	var shift: u10 = @intCast(@max(high - 23, 149));
	var significand: u32 = @intCast(magnitude >> shift);
	const remainder = magnitude & ((@as(u576, 1) << shift) - 1);
	const halfway = @as(u576, 1) << (shift - 1);
	if (remainder > halfway or (remainder == halfway and significand & 1 != 0)) significand += 1;
	if (significand < 0x800000) return sign | significand;
	if (significand == 0x1000000) {
		significand >>= 1;
		shift += 1;
	}
	const exponent: u32 = shift - 148;
	if (exponent >= 255) return sign | 0x7f800000;
	return sign | (exponent << 23) | (significand & 0x7fffff);
}
fn finiteTerm(value: u32) struct { significand: u32, exponent: i32 } {
	const exponent = (value >> 23) & 255;
	return .{
		.significand = (value & 0x7fffff) | (if (exponent == 0) @as(u32, 0) else 0x800000),
		.exponent = if (exponent == 0) -149 else @as(i32, @intCast(exponent)) - 150,
	};
}
