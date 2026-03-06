const std = @import("std");

/// Count leading zeros. Returns bit_width for x == 0.
pub fn num0BitsAboveMS1Bit(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
	const T = @TypeOf(x);
	comptime std.debug.assert(@typeInfo(T) == .int);
	comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
	if (x == 0) return @bitSizeOf(T);
	return @clz(x);
}

/// Count trailing zeros. Returns bit_width for x == 0.
pub fn num0BitsBelowLS1Bit(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
	const T = @TypeOf(x);
	comptime std.debug.assert(@typeInfo(T) == .int);
	comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
	if (x == 0) return @bitSizeOf(T);
	return @ctz(x);
}

/// Floor of base-2 logarithm. Undefined for x == 0.
pub fn floorLog2Nonzero(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
	const T = @TypeOf(x);
	comptime std.debug.assert(@typeInfo(T) == .int);
	comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
	std.debug.assert(x != 0);
	const bits: std.math.Log2IntCeil(T) = @bitSizeOf(T) - 1;
	return bits ^ @clz(x);
}

/// Ceiling of base-2 logarithm. Undefined for x == 0.
pub fn ceilLog2Nonzero(x: anytype) std.math.Log2IntCeil(@TypeOf(x)) {
	const T = @TypeOf(x);
	comptime std.debug.assert(@typeInfo(T) == .int);
	comptime std.debug.assert(@typeInfo(T).int.signedness == .unsigned);
	std.debug.assert(x != 0);
	const floor = floorLog2Nonzero(x);
	// If x is a power of two, floor == ceil; otherwise ceil = floor + 1
	if ((x & (x - 1)) == 0) return floor;
	return floor + 1;
}

test "zero input CLZ/CTZ" {
	const testing = std.testing;
	try testing.expectEqual(@as(u6, 32), num0BitsAboveMS1Bit(@as(u32, 0)));
	try testing.expectEqual(@as(u7, 64), num0BitsAboveMS1Bit(@as(u64, 0)));
	try testing.expectEqual(@as(u6, 32), num0BitsBelowLS1Bit(@as(u32, 0)));
	try testing.expectEqual(@as(u7, 64), num0BitsBelowLS1Bit(@as(u64, 0)));
}

test "powers of 2 CLZ/CTZ" {
	const testing = std.testing;
	try testing.expectEqual(@as(u6, 31), num0BitsAboveMS1Bit(@as(u32, 1)));
	try testing.expectEqual(@as(u6, 30), num0BitsAboveMS1Bit(@as(u32, 2)));
	try testing.expectEqual(@as(u7, 63), num0BitsAboveMS1Bit(@as(u64, 1)));
	try testing.expectEqual(@as(u7, 62), num0BitsAboveMS1Bit(@as(u64, 2)));

	try testing.expectEqual(@as(u6, 0), num0BitsBelowLS1Bit(@as(u32, 1)));
	try testing.expectEqual(@as(u7, 0), num0BitsBelowLS1Bit(@as(u64, 1)));
	try testing.expectEqual(@as(u6, 1), num0BitsBelowLS1Bit(@as(u32, 2)));
	try testing.expectEqual(@as(u7, 1), num0BitsBelowLS1Bit(@as(u64, 2)));

	try testing.expectEqual(@as(u6, 0), num0BitsAboveMS1Bit(@as(u32, 0x80000000)));
	try testing.expectEqual(@as(u7, 0), num0BitsAboveMS1Bit(@as(u64, 0x8000000000000000)));
	try testing.expectEqual(@as(u6, 31), num0BitsBelowLS1Bit(@as(u32, 0x80000000)));
	try testing.expectEqual(@as(u7, 63), num0BitsBelowLS1Bit(@as(u64, 0x8000000000000000)));
}

test "FloorLog2Nonzero" {
	const testing = std.testing;
	const expected_u32 = [7]u6{ 0, 1, 1, 2, 2, 2, 2 };
	for (expected_u32, 1..) |exp, i| {
		try testing.expectEqual(exp, floorLog2Nonzero(@as(u32, @intCast(i))));
		try testing.expectEqual(@as(u7, exp), floorLog2Nonzero(@as(u64, @intCast(i))));
	}

	try testing.expectEqual(@as(u6, 11), floorLog2Nonzero(@as(u32, 0x00000fff)));
	try testing.expectEqual(@as(u6, 12), floorLog2Nonzero(@as(u32, 0x00001000)));
	try testing.expectEqual(@as(u6, 12), floorLog2Nonzero(@as(u32, 0x00001001)));

	try testing.expectEqual(@as(u6, 31), floorLog2Nonzero(@as(u32, 0x80000000)));
	try testing.expectEqual(@as(u6, 31), floorLog2Nonzero(@as(u32, 0x80000001)));
	try testing.expectEqual(@as(u6, 31), floorLog2Nonzero(@as(u32, 0xFFFFFFFF)));

	try testing.expectEqual(@as(u7, 31), floorLog2Nonzero(@as(u64, 0x80000000)));
	try testing.expectEqual(@as(u7, 31), floorLog2Nonzero(@as(u64, 0xFFFFFFFF)));

	try testing.expectEqual(@as(u7, 63), floorLog2Nonzero(@as(u64, 0x8000000000000000)));
	try testing.expectEqual(@as(u7, 63), floorLog2Nonzero(@as(u64, 0xFFFFFFFFFFFFFFFF)));
}

test "CeilLog2Nonzero" {
	const testing = std.testing;
	const expected_u32 = [7]u6{ 0, 1, 2, 2, 3, 3, 3 };
	for (expected_u32, 1..) |exp, i| {
		try testing.expectEqual(exp, ceilLog2Nonzero(@as(u32, @intCast(i))));
		try testing.expectEqual(@as(u7, exp), ceilLog2Nonzero(@as(u64, @intCast(i))));
	}

	try testing.expectEqual(@as(u6, 12), ceilLog2Nonzero(@as(u32, 0x00000fff)));
	try testing.expectEqual(@as(u6, 12), ceilLog2Nonzero(@as(u32, 0x00001000)));
	try testing.expectEqual(@as(u6, 13), ceilLog2Nonzero(@as(u32, 0x00001001)));

	try testing.expectEqual(@as(u6, 31), ceilLog2Nonzero(@as(u32, 0x80000000)));
	try testing.expectEqual(@as(u6, 32), ceilLog2Nonzero(@as(u32, 0x80000001)));
	try testing.expectEqual(@as(u6, 32), ceilLog2Nonzero(@as(u32, 0xFFFFFFFF)));

	try testing.expectEqual(@as(u7, 63), ceilLog2Nonzero(@as(u64, 0x8000000000000000)));
	try testing.expectEqual(@as(u7, 64), ceilLog2Nonzero(@as(u64, 0x8000000000000001)));
	try testing.expectEqual(@as(u7, 64), ceilLog2Nonzero(@as(u64, 0xFFFFFFFFFFFFFFFF)));
}
