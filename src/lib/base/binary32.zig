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
	if (result & 0x7fffffff == 0 and a & 0x7fffffff != 0 and b & 0x7fffffff < 0x7f800000)
		return @bitCast(__truncdfsf2(__divdf3(__extendsfdf2(@bitCast(a)), __extendsfdf2(@bitCast(b)))));
	return result;
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
	if (isNan(a) or isNan(b) or (a & 0x7fffffff == 0 and b & 0x7fffffff == 0)) return 0;
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
