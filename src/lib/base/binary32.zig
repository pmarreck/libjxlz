//! Binary32 storage with integer arithmetic supplied by Zig's compiler runtime.
//! Floating arguments are ABI storage; the runtime computes with integer bits.
const std = @import("std");
pub const Fixed = u32;
pub const zero: u32 = 0;
const one: u32 = 0x3f800000;
extern fn __addsf3(f32, f32) callconv(.c) f32;
extern fn __subsf3(f32, f32) callconv(.c) f32;
extern fn __mulsf3(f32, f32) callconv(.c) f32;
extern fn __divsf3(f32, f32) callconv(.c) f32;
extern fn __extendsfdf2(f32) callconv(.c) f64;
extern fn __divdf3(f64, f64) callconv(.c) f64;
extern fn __truncdfsf2(f64) callconv(.c) f32;
pub fn add(a: u32, b: u32) u32 {
	if (@inComptime()) return @bitCast(@as(f32, @bitCast(a)) + @as(f32, @bitCast(b)));
	return @bitCast(__addsf3(@bitCast(a), @bitCast(b)));
}
pub fn sub(a: u32, b: u32) u32 {
	if (@inComptime()) return @bitCast(@as(f32, @bitCast(a)) - @as(f32, @bitCast(b)));
	return @bitCast(__subsf3(@bitCast(a), @bitCast(b)));
}
pub fn mul(a: u32, b: u32) u32 {
	if (@inComptime()) return @bitCast(@as(f32, @bitCast(a)) * @as(f32, @bitCast(b)));
	return @bitCast(__mulsf3(@bitCast(a), @bitCast(b)));
}
pub fn div(a: u32, b: u32) u32 {
	if (@inComptime()) return @bitCast(@as(f32, @bitCast(a)) / @as(f32, @bitCast(b)));
	const result: u32 = @bitCast(__divsf3(@bitCast(a), @bitCast(b)));
	// Zig 0.16's binary32 runtime divider flushes subnormal results to zero.
	// Finite binary32 ratios fit the normal binary64 range; integer widening,
	// division and narrowing preserve their gradual underflow instead.
	if (integerBits(result) & 0x7fffffff == 0 and integerBits(a) & 0x7fffffff != 0 and integerBits(b) & 0x7fffffff < 0x7f800000)
		return @bitCast(__truncdfsf2(__divdf3(__extendsfdf2(@bitCast(a)), __extendsfdf2(@bitCast(b)))));
	return result;
}
fn integerBits(value: u32) u32 {
	// LLVM otherwise folds these storage tests into floating comparisons.
	// An empty tied-register expression preserves the bits with no operation.
	return asm (""
		: [result] "=r" (-> u32),
		: [input] "0" (value),
	);
}
pub fn fromInt(comptime value: i64) u32 {
	return @bitCast(@as(f32, @floatFromInt(value)));
}
pub fn isNan(value: u32) bool {
	return value & 0x7fffffff > 0x7f800000;
}
pub fn negative(value: u32) bool {
	return value >> 31 != 0 and value & 0x7fffffff != 0 and !isNan(value);
}
pub fn cmp(a: u32, b: u32) i2 {
	if (isNan(a) or isNan(b) or (integerBits(a) & 0x7fffffff == 0 and integerBits(b) & 0x7fffffff == 0)) return 0;
	const ak = if (a >> 31 != 0) ~a else a ^ 0x80000000;
	const bk = if (b >> 31 != 0) ~b else b ^ 0x80000000;
	return if (ak < bk) -1 else if (ak > bk) 1 else 0;
}
pub fn divideAlpha(numerator: u32, alpha: u32) u32 {
	const reciprocal = if (cmp(alpha, zero) > 0) div(one, alpha) else zero;
	return mul(numerator, reciprocal);
}
test "binary32 integer division retains subnormal reciprocals" {
	try std.testing.expectEqual(@as(u32, 0x00200000), div(one, 0x7f7fffff));
	try std.testing.expectEqual(@as(u32, 0x80200000), div(one, 0xff7fffff));
}
pub fn parse(comptime value: []const u8) ?u32 {
	return comptime blk: {
		const parsed = std.fmt.parseFloat(f32, value) catch break :blk null;
		break :blk @as(u32, @bitCast(parsed));
	};
}
pub fn neg(value: u32) u32 {
	return value ^ 0x80000000;
}
pub fn fromF32(value: f32) @import("status.zig").JxlError!u32 {
	const bits: u32 = @bitCast(value);
	if (bits & 0x7fffffff >= 0x7f800000) return error.GenericError;
	return bits;
}
pub fn nonnegativeWeight(value: u32) u32 {
	return if (value >> 31 != 0) zero else value;
}
pub fn skipWeight(_: u32) bool {
	return false;
}
pub fn abs(value: u32) u32 {
	return value & 0x7fffffff;
}
test "binary32 absolute difference clears NaN signs before filter weights" {
	try std.testing.expectEqual(@as(u32, 0x7fc12345), abs(sub(0x3f800000, 0x7fc12345)));
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
	if (aa == 0 or bb == 0) return c;
	if (cc == 0) return mul(a, b);
	const left = finiteTerm(a);
	const right = finiteTerm(b);
	const extra = finiteTerm(c);
	const product: u64 = @as(u64, left.significand) * right.significand;
	const product_exp = left.exponent + right.exponent;
	const product_high = product_exp + 63 - @as(i32, @intCast(@clz(product)));
	const extra_high = extra.exponent + 31 - @as(i32, @intCast(@clz(extra.significand)));
	// Retain 61 significant bits. Cancellation between 48-bit products and
	// 24-bit addends is exact here; distant terms retain a sticky low bit.
	const unit = @max(product_high, extra_high) - 60;
	const p: i64 = @intCast(alignFused(product, product_exp - unit));
	const z: i64 = @intCast(alignFused(extra.significand, extra.exponent - unit));
	const sum = (if (product_sign != 0) -p else p) + (if (c >> 31 != 0) -z else z);
	if (sum == 0) return 0;
	const sign: u32 = if (sum < 0) 0x80000000 else 0;
	const magnitude: u64 = @intCast(if (sum < 0) -sum else sum);
	const high: i32 = 63 - @as(i32, @intCast(@clz(magnitude)));
	const shift_count = @max(high - 23, -149 - unit);
	if (shift_count >= 64) return sign;
	var shift = shift_count;
	var significand: u32 = undefined;
	if (shift <= 0) {
		significand = @intCast(magnitude << @intCast(-shift));
	} else {
		const count: u6 = @intCast(shift);
		significand = @intCast(magnitude >> count);
		const remainder = magnitude & ((@as(u64, 1) << count) - 1);
		const halfway = @as(u64, 1) << (count - 1);
		if (remainder > halfway or (remainder == halfway and significand & 1 != 0)) significand += 1;
	}
	if (significand < 0x800000) return sign | significand;
	if (significand == 0x1000000) {
		significand >>= 1;
		shift += 1;
	}
	const exponent: i32 = unit + @as(i32, shift) + 150;
	if (exponent >= 255) return sign | 0x7f800000;
	return sign | (@as(u32, @intCast(exponent)) << 23) | (significand & 0x7fffff);
}
fn alignFused(significand: u64, shift: i32) u64 {
	if (shift >= 0) return @as(u64, significand) << @intCast(shift);
	if (shift <= -64) return 1;
	const count: u6 = @intCast(-shift);
	return (significand >> count) | @intFromBool(significand & ((@as(u64, 1) << count) - 1) != 0);
}
fn finiteTerm(value: u32) struct { significand: u32, exponent: i32 } {
	const exponent = (value >> 23) & 255;
	return .{
		.significand = (value & 0x7fffff) | (if (exponent == 0) @as(u32, 0) else 0x800000),
		.exponent = if (exponent == 0) -149 else @as(i32, @intCast(exponent)) - 150,
	};
}
