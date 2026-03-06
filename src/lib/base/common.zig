const std = @import("std");

pub const bits_per_byte: usize = 8;
pub const pi: f64 = 3.14159265358979323846264338327950288;
pub const inv_log2e: f32 = 0.6931471805599453;
pub const default_intensity_target: f32 = 255;

pub const Color = [3]f32;

/// Round up bits to the next multiple of 8.
pub fn roundUpBitsToByteMultiple(bits: usize) usize {
	return (bits + 7) & ~@as(usize, 7);
}

/// Round up dimension to the next multiple of 8 (block dim).
pub fn roundUpToBlockDim(dim: usize) usize {
	return (dim + 7) & ~@as(usize, 7);
}

/// Safe addition that returns null on overflow.
pub fn safeAdd(a: u64, b: u64) ?u64 {
	const result = @addWithOverflow(a, b);
	if (result[1] != 0) return null;
	return result[0];
}

/// Ceiling division: divCeil(a, b) = ceil(a / b).
pub fn divCeil(a: anytype, b: anytype) @TypeOf(a) {
	return @divTrunc(a + b - 1, b);
}

/// Round `what` up to the next multiple of `align`.
pub fn roundUpTo(what: usize, alignment: usize) usize {
	return divCeil(what, alignment) * alignment;
}

/// Clamp `val` to [low, hi].
pub fn clamp1(val: anytype, low: anytype, hi: anytype) @TypeOf(val) {
	return if (val < low) low else if (val > hi) hi else val;
}

test "roundUpBitsToByteMultiple" {
	const testing = std.testing;
	try testing.expectEqual(@as(usize, 0), roundUpBitsToByteMultiple(0));
	try testing.expectEqual(@as(usize, 8), roundUpBitsToByteMultiple(1));
	try testing.expectEqual(@as(usize, 8), roundUpBitsToByteMultiple(7));
	try testing.expectEqual(@as(usize, 8), roundUpBitsToByteMultiple(8));
	try testing.expectEqual(@as(usize, 16), roundUpBitsToByteMultiple(9));
	try testing.expectEqual(@as(usize, 16), roundUpBitsToByteMultiple(16));
	try testing.expectEqual(@as(usize, 24), roundUpBitsToByteMultiple(17));
}

test "roundUpToBlockDim" {
	const testing = std.testing;
	try testing.expectEqual(@as(usize, 0), roundUpToBlockDim(0));
	try testing.expectEqual(@as(usize, 8), roundUpToBlockDim(1));
	try testing.expectEqual(@as(usize, 8), roundUpToBlockDim(8));
	try testing.expectEqual(@as(usize, 16), roundUpToBlockDim(9));
}

test "safeAdd" {
	const testing = std.testing;
	try testing.expectEqual(@as(?u64, 3), safeAdd(1, 2));
	try testing.expectEqual(@as(?u64, 0), safeAdd(0, 0));
	try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), safeAdd(std.math.maxInt(u64), 0));
	// Overflow
	try testing.expectEqual(@as(?u64, null), safeAdd(std.math.maxInt(u64), 1));
	try testing.expectEqual(@as(?u64, null), safeAdd(std.math.maxInt(u64), std.math.maxInt(u64)));
}

test "divCeil" {
	const testing = std.testing;
	try testing.expectEqual(@as(usize, 0), divCeil(@as(usize, 0), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 1), divCeil(@as(usize, 1), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 1), divCeil(@as(usize, 7), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 1), divCeil(@as(usize, 8), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 2), divCeil(@as(usize, 9), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 2), divCeil(@as(usize, 16), @as(usize, 8)));
	try testing.expectEqual(@as(usize, 3), divCeil(@as(usize, 17), @as(usize, 8)));
}

test "roundUpTo" {
	const testing = std.testing;
	try testing.expectEqual(@as(usize, 0), roundUpTo(0, 8));
	try testing.expectEqual(@as(usize, 8), roundUpTo(1, 8));
	try testing.expectEqual(@as(usize, 8), roundUpTo(8, 8));
	try testing.expectEqual(@as(usize, 16), roundUpTo(9, 8));
	try testing.expectEqual(@as(usize, 16), roundUpTo(16, 8));
	try testing.expectEqual(@as(usize, 24), roundUpTo(17, 8));
}

test "clamp1" {
	const testing = std.testing;
	try testing.expectEqual(@as(i32, 0), clamp1(@as(i32, -5), @as(i32, 0), @as(i32, 10)));
	try testing.expectEqual(@as(i32, 5), clamp1(@as(i32, 5), @as(i32, 0), @as(i32, 10)));
	try testing.expectEqual(@as(i32, 10), clamp1(@as(i32, 15), @as(i32, 0), @as(i32, 10)));
	try testing.expectEqual(@as(f32, 0.0), clamp1(@as(f32, -1.0), @as(f32, 0.0), @as(f32, 1.0)));
	try testing.expectEqual(@as(f32, 0.5), clamp1(@as(f32, 0.5), @as(f32, 0.0), @as(f32, 1.0)));
	try testing.expectEqual(@as(f32, 1.0), clamp1(@as(f32, 2.0), @as(f32, 0.0), @as(f32, 1.0)));
}

test "Color type alias" {
	const c: Color = .{ 1.0, 0.5, 0.0 };
	try std.testing.expectEqual(@as(f32, 1.0), c[0]);
	try std.testing.expectEqual(@as(f32, 0.5), c[1]);
	try std.testing.expectEqual(@as(f32, 0.0), c[2]);
}
