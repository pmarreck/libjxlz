const std = @import("std");
const math = @import("binary32_geometry.zig");
fn check(bits: u32) !void {
	@setFloatMode(.strict);
	const value: f32 = @bitCast(bits);
	const expected = [_]f32{ @sqrt(value), @floor(value), @ceil(value), @round(value) };
	const actual = [_]f32{ math.sqrt(value), math.floor(value), math.ceil(value), math.round(value) };
	for (expected, actual, 0..) |want, got, op| {
		const a: u32 = @bitCast(want);
		const b: u32 = @bitCast(got);
		if (a & 0x7fffffff > 0x7f800000) try std.testing.expect(b & 0x7fffffff > 0x7f800000) else if (a != b) {
			std.debug.print("geometry op={d} input={x} expected={x} actual={x}\n", .{ op, bits, a, b });
			return error.TestUnexpectedResult;
		}
	}
}
test "integer binary32 geometry matches native rounding and square root" {
	const edges = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x7fffff, 0x807fffff, 0x800000, 0x80800000, 0x3effffff, 0x3f000000, 0x3f000001, 0x3f800000, 0xbf800000, 0x3f7fffff, 0x3f800001, 0x4b000000, 0xcb000000, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345 };
	for (edges) |word| try check(word);
	var seed: u64 = 0x281904ef432bfefa;
	for (0..200000) |_| {
		seed = seed *% 6364136223846793005 +% 1442695040888963407;
		try check(@truncate(seed >> 16));
	}
}
fn approximate(expected: f32, actual: f32) !void {
	const want: u32 = @bitCast(expected);
	const got: u32 = @bitCast(actual);
	if (want & 0x7fffffff > 0x7f800000) return std.testing.expect(got & 0x7fffffff > 0x7f800000);
	if (want & 0x7fffffff == 0 or want & 0x7fffffff == 0x7f800000) return std.testing.expectEqual(want, got);
	const difference = if (want > got) want - got else got - want;
	if (difference > 1) {
		std.debug.print("geometry expected={x} actual={x} ulps={d}\n", .{ want, got, difference });
		return error.TestUnexpectedResult;
	}
}
test "integer binary32 logarithm and hypotenuse match independent native controls" {
	@setFloatMode(.strict);
	var seed: u64 = 0x43758a892340ca53;
	for (0..200000) |_| {
		seed = seed *% 6364136223846793005 +% 1442695040888963407;
		const a: f32 = @bitCast(@as(u32, @truncate(seed >> 16)));
		seed = seed *% 6364136223846793005 +% 1442695040888963407;
		const b: f32 = @bitCast(@as(u32, @truncate(seed >> 16)));
		try approximate(@log(a), math.log(a));
		try approximate(std.math.hypot(a, b), math.hypot(a, b));
	}
}
