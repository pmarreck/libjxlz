const std = @import("std");
const sf = @import("../base/soft_float.zig");
const fixture = @import("inverse_transform_fixture.zig");
const dct = @import("inverse_transform.zig");
const strategy = @import("ac_strategy.zig");

test "inverse block DCT matches upstream sampled outputs through 256" {
	const allocator = std.testing.allocator;
	const strategies = [_]u8{ 0, 4, 5, 6, 7, 8, 9, 10, 11, 18, 19, 20, 21, 22, 23, 24, 25, 26 };
	for (strategies) |raw| {
		const extent = try strategy.strategyExtent(raw);
		const width = 8 * extent.x;
		const height = 8 * extent.y;
		const coefficients = try allocator.alloc(sf.Fixed, width * height);
		defer allocator.free(coefficients);
		for (coefficients, 0..) |*value, i| value.* = sf.div(sf.fromInt(@as(i64, @intCast(i % 23)) - 11), sf.fromInt(1024));
		const pixels = try allocator.alloc(sf.Fixed, width * height);
		defer allocator.free(pixels);
		try dct.inverse(allocator, width, height, coefficients, pixels, width);
		for (fixture.positions[raw], fixture.samples[raw]) |position, expected| {
			const delta = sf.sub(pixels[position], sf.div(sf.fromInt(expected), sf.fromInt(1 << 20)));
			const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
			// Bound comparison with upstream's float32 arithmetic and rounded fixture.
			try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(4096))) < 0);
		}
	}
}

test "inverse block special transforms match upstream samples" {
	const allocator = std.testing.allocator;
	for ([_]u8{ 1, 2, 3, 12, 13, 14, 15, 16, 17 }) |raw| {
		const coefficients = try allocator.alloc(sf.Fixed, 64);
		defer allocator.free(coefficients);
		for (coefficients, 0..) |*value, i| value.* = sf.div(sf.fromInt(@as(i64, @intCast(i % 23)) - 11), sf.fromInt(1024));
		const pixels = try allocator.alloc(sf.Fixed, 64);
		defer allocator.free(pixels);
		try dct.transform(allocator, raw, coefficients, pixels, 8);
		for (fixture.positions[raw], fixture.samples[raw]) |position, expected| {
			const delta = sf.sub(pixels[position], sf.div(sf.fromInt(expected), sf.fromInt(1 << 20)));
			const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
			try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(4096))) < 0);
		}
	}
}

test "inverse block lowest frequencies match upstream DC reconstruction" {
	const allocator = std.testing.allocator;
	for (0..27) |raw| {
		const extent = try strategy.strategyExtent(@intCast(raw));
		const stride = extent.x + 3;
		const dc = try allocator.alloc(sf.Fixed, stride * extent.y);
		defer allocator.free(dc);
		@memset(dc, sf.fromInt(12345));
		for (0..extent.y) |y| for (0..extent.x) |x| {
			dc[y * stride + x] = sf.div(sf.fromInt(@as(i64, @intCast((x * 3 + y * 7) % 19)) - 9), sf.fromInt(128));
		};
		const coefficients = try allocator.alloc(sf.Fixed, 64 * extent.x * extent.y);
		defer allocator.free(coefficients);
		@memset(coefficients, sf.fromInt(777));
		const order = try allocator.alloc(u32, coefficients.len);
		defer allocator.free(order);
		try strategy.naturalOrder(@intCast(raw), order);
		try dct.lowestFrequencies(allocator, @intCast(raw), dc, stride, coefficients);
		for (fixture.low_frequency[raw], 0..) |expected, i| {
			const delta = sf.sub(coefficients[order[i]], sf.div(sf.fromInt(expected), sf.fromInt(1 << 24)));
			const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
			try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(1 << 18))) < 0);
		}
		for (order[extent.x * extent.y ..]) |position| try std.testing.expectEqual(sf.fromInt(777), coefficients[position]);
	}
}

test "inverse block DC impulse reconstructs constant pixels for every strategy" {
	const allocator = std.testing.allocator;
	for (0..27) |raw| {
		const extent = try strategy.strategyExtent(@intCast(raw));
		const width = 8 * extent.x;
		const height = 8 * extent.y;
		const coefficients = try allocator.alloc(sf.Fixed, width * height);
		defer allocator.free(coefficients);
		@memset(coefficients, sf.Fixed.zero);
		const dc = sf.div(sf.fromInt(-3), sf.fromInt(4));
		coefficients[0] = dc;
		const pixels = try allocator.alloc(sf.Fixed, width * height);
		defer allocator.free(pixels);
		try dct.transform(allocator, @intCast(raw), coefficients, pixels, width);
		for (pixels) |value| try std.testing.expectEqual(dc, value);
	}
}

fn checkLayout(allocator: std.mem.Allocator, raw: u8) !void {
	const extent = try strategy.strategyExtent(raw);
	const width = 8 * extent.x;
	const height = 8 * extent.y;
	const stride = width + 3;
	const coefficients = try allocator.alloc(sf.Fixed, width * height);
	defer allocator.free(coefficients);
	for (coefficients, 0..) |*value, i| value.* = sf.div(sf.fromInt(@as(i64, @intCast(i % 23)) - 11), sf.fromInt(1024));
	const original = try allocator.dupe(sf.Fixed, coefficients);
	defer allocator.free(original);
	const pixels = try allocator.alloc(sf.Fixed, stride * height);
	defer allocator.free(pixels);
	@memset(pixels, sf.fromInt(777));
	try dct.transform(allocator, raw, coefficients, pixels, stride);
	try std.testing.expectEqualSlices(sf.Fixed, original, coefficients);
	for (0..height) |y| for (pixels[y * stride + width ..][0..3]) |value| {
		try std.testing.expectEqual(sf.fromInt(777), value);
	};
	// In-place reconstruction must produce the same samples as strided output.
	try dct.transform(allocator, raw, coefficients, coefficients, width);
	for (0..height) |y| try std.testing.expectEqualSlices(sf.Fixed,
		pixels[y * stride ..][0..width], coefficients[y * width ..][0..width]);
	for (fixture.positions[raw], fixture.samples[raw]) |position, expected| {
		const delta = sf.sub(coefficients[position], sf.div(sf.fromInt(expected), sf.fromInt(1 << 20)));
		const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
		try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(4096))) < 0);
	}
}

test "inverse block transforms preserve padding support aliasing and release failed allocations" {
	for ([_]u8{ 0, 1, 2, 3, 6, 7, 12, 13, 14, 15, 16, 17 }) |raw| {
		try checkLayout(std.testing.allocator, raw);
		try std.testing.checkAllAllocationFailures(std.testing.allocator, checkLayout, .{raw});
	}
}

test "inverse block transforms reject invalid shape stride and strategy" {
	const allocator = std.testing.allocator;
	const coefficients = try allocator.alloc(sf.Fixed, 64);
	defer allocator.free(coefficients);
	@memset(coefficients, sf.Fixed.zero);
	const pixels = try allocator.alloc(sf.Fixed, 72);
	defer allocator.free(pixels);
	@memset(pixels, sf.fromInt(777));
	for ([_][2]usize{ .{ 0, 8 }, .{ 8, 0 }, .{ 257, 8 }, .{ 8, 257 }, .{ 3, 8 }, .{ 8, 3 } }) |size| {
		try std.testing.expectError(error.GenericError, dct.inverse(allocator, size[0], size[1], coefficients, pixels, 8));
	}
	for ([_]u8{ 0, 1, 2, 3, 12, 13, 14 }) |raw| {
		try std.testing.expectError(error.GenericError, dct.transform(allocator, raw, coefficients, pixels, 0));
		try std.testing.expectError(error.GenericError, dct.transform(allocator, raw, coefficients, pixels, 7));
		try std.testing.expectError(error.GenericError, dct.transform(allocator, raw, coefficients, pixels[0..70], 9));
		try std.testing.expectError(error.GenericError, dct.transform(allocator, raw, coefficients[0..63], pixels, 8));
	}
	try std.testing.expectError(error.GenericError, dct.transform(allocator, 27, coefficients, pixels, 8));
	try std.testing.expectError(error.GenericError, dct.lowestFrequencies(allocator, 27, coefficients, 8, pixels));
	try std.testing.expectError(error.GenericError, dct.lowestFrequencies(allocator, 4, coefficients, 1, pixels));
	try std.testing.expectError(error.GenericError, dct.lowestFrequencies(allocator, 0, &.{}, 1, coefficients));
	for (pixels) |value| try std.testing.expectEqual(sf.fromInt(777), value);
}

fn checkLowFrequencyAllocation(allocator: std.mem.Allocator) !void {
	const coefficients = try allocator.alloc(sf.Fixed, 256);
	defer allocator.free(coefficients);
	@memset(coefficients, sf.fromInt(777));
	const dc = [_]sf.Fixed{
		sf.div(sf.fromInt(-9), sf.fromInt(128)), sf.div(sf.fromInt(-6), sf.fromInt(128)),
		sf.div(sf.fromInt(-2), sf.fromInt(128)), sf.div(sf.fromInt(1), sf.fromInt(128)),
	};
	try dct.lowestFrequencies(allocator, 4, &dc, 2, coefficients);
	for ([_]usize{ 0, 1, 16, 17 }, fixture.low_frequency[4]) |position, expected| {
		const delta = sf.sub(coefficients[position], sf.div(sf.fromInt(expected), sf.fromInt(1 << 24)));
		const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
		try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(1 << 18))) < 0);
	}
}

test "inverse block lowest frequency allocation cleanup" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkLowFrequencyAllocation, .{});
}
