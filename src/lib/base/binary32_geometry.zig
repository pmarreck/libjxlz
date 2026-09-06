//! Binary32 geometry storage, computed through integer bits and randomz Fixed.
const sf = @import("soft_float.zig");
const display = @import("fixed_display.zig");
const load = @import("float.zig").loadFloat32Fixed;
pub fn sqrt(value: f32) f32 {
	const word: u32 = @bitCast(value);
	const magnitude = word & 0x7fffffff;
	if (magnitude == 0 or word == 0x7f800000) return value;
	if (magnitude > 0x7f800000) return @bitCast(word | 0x400000);
	if (word >> 31 != 0) return @bitCast(@as(u32, 0x7fc00000));
	const field = magnitude >> 23;
	var significand = magnitude & 0x7fffff;
	var exponent: i32 = undefined;
	if (field == 0) {
		const shift: u5 = @intCast(@clz(significand) - 8);
		significand <<= shift;
		exponent = -126 - @as(i32, shift);
	} else {
		significand |= 0x800000;
		exponent = @as(i32, @intCast(field)) - 127;
	}
	if (@mod(exponent, 2) != 0) {
		significand <<= 1;
		exponent -= 1;
	}
	const radicand = @as(u64, significand) << 23;
	var root: u64 = @import("std").math.sqrt(radicand);
	// sqrt(n) is above r+1/2 iff n-r*r > r for integer n and r.
	if (radicand - root * root > root) root += 1;
	if (root == 0x1000000) {
		root >>= 1;
		exponent += 2;
	}
	return @bitCast((@as(u32, @intCast(@divExact(exponent, 2) + 127)) << 23) | (@as(u32, @intCast(root)) & 0x7fffff));
}
pub fn floor(value: f32) f32 {
	return integral(value, .floor);
}
pub fn ceil(value: f32) f32 {
	return integral(value, .ceil);
}
pub fn round(value: f32) f32 {
	return integral(value, .nearest);
}
fn integral(value: f32, comptime mode: enum { floor, ceil, nearest }) f32 {
	const word: u32 = @bitCast(value);
	const sign = word & 0x80000000;
	const magnitude = word & 0x7fffffff;
	const exponent = magnitude >> 23;
	if (magnitude == 0 or exponent >= 150) return value;
	const away = if (mode == .nearest) magnitude >= 0x3f000000 else if (mode == .floor) sign != 0 else sign == 0;
	if (exponent < 127) return @bitCast(sign | (if (away) @as(u32, 0x3f800000) else 0));
	const shift: u5 = @intCast(150 - exponent);
	const unit = @as(u32, 1) << shift;
	const fraction = magnitude & (unit - 1);
	const increment = if (mode == .nearest) fraction >= unit >> 1 else away and fraction != 0;
	return @bitCast(sign | ((magnitude & ~(unit - 1)) + (if (increment) unit else 0)));
}
pub fn log(value: f32) f32 {
	const word: u32 = @bitCast(value);
	const magnitude = word & 0x7fffffff;
	if (magnitude == 0) return @bitCast(@as(u32, 0xff800000));
	if (magnitude > 0x7f800000) return @bitCast(word | 0x400000);
	if (word >> 31 != 0) return @bitCast(@as(u32, 0x7fc00000));
	if (word == 0x7f800000) return value;
	return @bitCast(display.bits(sf.ln(load(value) catch unreachable)));
}
pub fn hypot(a: f32, b: f32) f32 {
	const aa = @as(u32, @bitCast(a)) & 0x7fffffff;
	const bb = @as(u32, @bitCast(b)) & 0x7fffffff;
	if (aa == 0x7f800000 or bb == 0x7f800000) return @bitCast(@as(u32, 0x7f800000));
	if (aa > 0x7f800000 or bb > 0x7f800000) return @bitCast(@as(u32, 0x7fc00000));
	const x = load(a) catch unreachable;
	const y = load(b) catch unreachable;
	return @bitCast(display.bits(sf.sqrt(sf.add(sf.mul(x, x), sf.mul(y, y)))));
}
const arithmetic = @import("binary32.zig");
pub fn add(a: f32, b: f32) f32 {
	return @bitCast(arithmetic.add(@bitCast(a), @bitCast(b)));
}
pub fn sub(a: f32, b: f32) f32 {
	return @bitCast(arithmetic.sub(@bitCast(a), @bitCast(b)));
}
pub fn mul(a: f32, b: f32) f32 {
	return @bitCast(arithmetic.mul(@bitCast(a), @bitCast(b)));
}
pub fn div(a: f32, b: f32) f32 {
	return @bitCast(arithmetic.div(@bitCast(a), @bitCast(b)));
}
pub fn fma(a: f32, b: f32, c: f32) f32 {
	return @bitCast(arithmetic.fma(@bitCast(a), @bitCast(b), @bitCast(c)));
}
pub fn neg(a: f32) f32 {
	return @bitCast(arithmetic.neg(@bitCast(a)));
}
pub fn abs(a: f32) f32 {
	return @bitCast(arithmetic.abs(@bitCast(a)));
}
pub fn fromInt(a: i64) f32 {
	return @bitCast(display.bits(sf.fromInt(a)));
}
pub fn toInt(a: f32) i64 {
	return sf.toIntTrunc(load(a) catch unreachable);
}
pub fn cmp(a: f32, b: f32) i2 {
	return arithmetic.cmp(@bitCast(a), @bitCast(b));
}
pub fn le(a: f32, b: f32) bool {
	return !arithmetic.isNan(@bitCast(a)) and !arithmetic.isNan(@bitCast(b)) and cmp(a, b) <= 0;
}
pub fn lt(a: f32, b: f32) bool {
	return !arithmetic.isNan(@bitCast(a)) and !arithmetic.isNan(@bitCast(b)) and cmp(a, b) < 0;
}
pub fn min(a: f32, b: f32) f32 {
	const x: u32 = @bitCast(a);
	const y: u32 = @bitCast(b);
	if (arithmetic.isNan(x)) return b;
	if (arithmetic.isNan(y)) return a;
	if ((x | y) & 0x7fffffff == 0) return @bitCast(x | y);
	return if (cmp(a, b) < 0) a else b;
}
pub fn max(a: f32, b: f32) f32 {
	const x: u32 = @bitCast(a);
	const y: u32 = @bitCast(b);
	if (arithmetic.isNan(x)) return b;
	if (arithmetic.isNan(y)) return a;
	if ((x | y) & 0x7fffffff == 0) return @bitCast(x & y);
	return if (cmp(a, b) > 0) a else b;
}
