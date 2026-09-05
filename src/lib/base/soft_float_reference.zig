//! Test oracle retained from 5ee037fa before arithmetic optimization.
const std = @import("std");
pub const TWO62: u64 = 0x4000000000000000;
pub const TWO61: u64 = 0x2000000000000000;
const POW2 = blk: {
	var out: [63]i64 = undefined;
	for (&out, 0..) |*v, i| v.* = @as(i64, 1) << @intCast(i);
	break :blk out;
};
pub const Fixed = struct {
	m: i64,
	e: i32,
	pub const zero: @This() = .{ .m = 0, .e = 0 };
};
pub fn norm(m: i64, e: i32) Fixed {
	if (m == 0) return Fixed.zero;

	const is_neg = m < 0;
	var u: u64 = @bitCast(if (is_neg) -%m else m);
	var ee = e;

	if (u >= 0x8000000000000000) {
		// Magnitude reached the sign bit. Only reachable from minInt(i64),
		// whose wrapped magnitude is exactly 2^63.
		u >>= 1;
		ee += 1;
	} else if (u < TWO62) {
		// Single @clz shift replacing the reference's `u = u * 2` loop.
		// A normalized magnitude occupies exactly 63 bits, i.e. @clz(u) == 1;
		// u currently occupies 64 - @clz(u), so the deficit is @clz(u) - 1.
		// u != 0 here (handled above), so @clz(u) <= 63 and the shift is
		// in range for a u6. Equivalence with the loop is not assumed --
		// tests/zig_differential sweeps every shift distance including the
		// extremes against the reference.
		const sh: u6 = @intCast(@clz(u) - 1);
		u <<= sh;
		ee -= sh;
	}

	// u < 2^63 here, so this bitcast cannot produce a negative value.
	const r: i64 = @bitCast(u);
	return .{ .m = if (is_neg) -%r else r, .e = ee };
}
pub fn fromInt(v: i64) Fixed {
	if (v == 0) return Fixed.zero;
	return norm(v, 62);
}
pub fn add(a: Fixed, b: Fixed) Fixed {
	// A zero operand returns the OTHER operand verbatim, not renormalized —
	// same as the reference.
	if (a.m == 0) return b;
	if (b.m == 0) return a;

	// Order so x carries the larger exponent (strict comparison: equal
	// exponents keep the original order, same as the reference's `e1 < e2`).
	var x = a;
	var y = b;
	if (a.e < b.e) {
		x = b;
		y = a;
	}
	// Gap in i64: maxInt - minInt overflows i32, and the reference computes
	// this in doubles where it cannot overflow.
	const d: i64 = @as(i64, x.e) - @as(i64, y.e);
	if (d >= 63) return x; // second operand is entirely below the ulp

	const shifted = @divTrunc(y.m, POW2[@intCast(d)]);
	// Unreachable under the normalization invariant (|y.m| >= 2^62 and
	// d <= 62 give |shifted| >= 1); kept as defense against an unnormalized
	// caller, mirroring the reference.
	if (shifted == 0) return x;

	var sum: i64 = undefined;
	var es: i64 = undefined;
	if ((x.m < 0) == (shifted < 0)) {
		// Same sign: magnitudes accumulate and could overflow i64, so halve
		// both first (truncating!) and bump the exponent. Error bound 2 ULP,
		// pinned below.
		sum = @divTrunc(x.m, 2) + @divTrunc(shifted, 2);
		es = @as(i64, x.e) + 1;
	} else {
		// Opposite signs: the sum's magnitude can only shrink, so it is exact
		// and cannot overflow.
		sum = x.m + shifted;
		es = x.e;
	}
	if (sum == 0) return Fixed.zero;
	std.debug.assert(es >= std.math.minInt(i32) and es <= std.math.maxInt(i32));
	return norm(sum, @intCast(es));
}
fn divmag(a: u64, b: u64) u64 {
	const q0 = a / b;
	var rem = a % b;
	var fbits: u64 = 0;
	for (0..62) |_| {
		rem *= 2;
		fbits *= 2;
		if (rem >= b) {
			rem -= b;
			fbits += 1;
		}
	}
	return q0 * TWO62 + fbits;
}
pub fn div(a: Fixed, b: Fixed) Fixed {
	// Divisor-zero check BEFORE the dividend shortcut: 0/0 is undefined, not
	// canonical zero — same stance, same order, as the reference.
	std.debug.assert(b.m != 0); // fixed.div: division by zero
	if (a.m == 0) return Fixed.zero;

	const is_neg = (a.m < 0) != (b.m < 0);
	const ua: u64 = @bitCast(if (a.m < 0) -%a.m else a.m);
	const ub: u64 = @bitCast(if (b.m < 0) -%b.m else b.m);
	std.debug.assert(ua >= TWO62 and ua < 0x8000000000000000); // operand 1 normalized
	std.debug.assert(ub >= TWO62 and ub < 0x8000000000000000); // operand 2 normalized

	// divmag's result is < 2^63, so the bitcast cannot go negative and the
	// negation cannot overflow.
	const mag: i64 = @bitCast(divmag(ua, ub));
	const r: i64 = if (is_neg) -%mag else mag;

	// Exponent difference in i64: maxInt - minInt overflows i32, and the
	// reference computes this in doubles then asserts inside norm.
	const es: i64 = @as(i64, a.e) - @as(i64, b.e);
	std.debug.assert(es >= std.math.minInt(i32) and es <= std.math.maxInt(i32));
	return norm(r, @intCast(es));
}
