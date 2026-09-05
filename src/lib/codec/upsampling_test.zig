const std = @import("std");
const sf = @import("../root.zig").base.soft_float;
const ups = @import("upsampling.zig");
const fixture = @import("upsampling_fixture.zig");
const defaults = @import("upsampling_weights.zig");
fn check(allocator: std.mem.Allocator, comptime count: usize) !void {
	inline for (0..count) |id| {
		const width: usize = if (id == 0) 1 else if (id == 1) 7 else 13;
		const height: usize = if (id == 0) 3 else if (id == 1) 5 else 9;
		const samples = @field(fixture, "input_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const input = try allocator.alloc(sf.Fixed, samples.len);
		defer allocator.free(input);
		for (input, samples) |*value, raw| value.* = sf.div(sf.fromInt(raw), sf.fromInt(256));
		inline for (.{ 2, 4, 8 }) |factor| {
			var weights = @field(defaults, "weights" ++ std.fmt.comptimePrint("{d}", .{factor}));
			if (id == 3) for (&weights, 0..) |*v, i| {
				v.* = sf.div(sf.fromInt(@as(i64, @intCast(i % 7)) - 3), sf.fromInt(64));
			};
			const output = try ups.upsample(allocator, .{ .width = width, .height = height, .data = input }, factor, &weights, width * factor, height * factor);
			defer allocator.free(output);
			const expected = @field(fixture, "output_" ++ std.fmt.comptimePrint("{d}_{d}", .{ id, factor }));
			try std.testing.expectEqual(expected.len, output.len);
			for (output, expected) |value, raw| {
				const delta = sf.sub(value, sf.div(sf.fromInt(raw), sf.fromInt(1 << 24)));
				try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(1), sf.fromInt(1 << 20))) <= 0);
			}
		}
	}
}
test "upsampling matches all upstream pixels at 2x 4x 8x and custom weights" {
	try check(std.testing.allocator, 4);
}
fn one(allocator: std.mem.Allocator) !void {
	try check(allocator, 1);
}
test "upsampling allocation failures release buffers" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, one, .{});
}
test "upsampling preserves constants, crops partial edges and leaves inputs unchanged" {
	const allocator = std.testing.allocator;
	const input = [_]sf.Fixed{sf.fromInt(-3)} ** 6;
	inline for (.{ 2, 4, 8 }) |factor| {
		const weights = @field(defaults, "weights" ++ std.fmt.comptimePrint("{d}", .{factor}));
		const output = try ups.upsample(allocator, .{ .width = 2, .height = 3, .data = &input }, factor, &weights, factor + 1, 2 * factor + 1);
		defer allocator.free(output);
		for (output) |value| try std.testing.expectEqualDeep(sf.fromInt(-3), value);
		try std.testing.expectEqualDeep([_]sf.Fixed{sf.fromInt(-3)} ** 6, input);
	}
	const samples = fixture.input_1;
	var varied: [samples.len]sf.Fixed = undefined;
	for (&varied, samples) |*v, raw| v.* = sf.div(sf.fromInt(raw), sf.fromInt(256));
	const original = varied;
	const output = try ups.upsample(allocator, .{ .width = 7, .height = 5, .data = &varied }, 4, &defaults.weights4, 25, 17);
	defer allocator.free(output);
	for (output, 0..) |v, i| {
		const expected = sf.div(sf.fromInt(fixture.output_1_4[(i / 25) * 28 + i % 25]), sf.fromInt(1 << 24));
		const delta = sf.sub(v, expected);
		try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(1), sf.fromInt(1 << 20))) <= 0);
	}
	try std.testing.expectEqualDeep(original, varied);
}
test "upsampling rejects invalid factors, dimensions and weight counts before allocation" {
	const a = std.testing.allocator;
	const input = [_]sf.Fixed{sf.fromInt(1)};
	const p = ups.Plane{ .width = 1, .height = 1, .data = &input };
	for ([_]u4{ 0, 1, 3, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15 }) |factor| try std.testing.expectError(error.GenericError, ups.upsample(a, p, factor, &defaults.weights2, 2, 2));
	try std.testing.expectError(error.GenericError, ups.upsample(a, p, 2, defaults.weights2[0..14], 2, 2));
	try std.testing.expectError(error.GenericError, ups.upsample(a, p, 2, &defaults.weights2, 0, 2));
	try std.testing.expectError(error.GenericError, ups.upsample(a, p, 2, &defaults.weights2, 3, 2));
	try std.testing.expectError(error.GenericError, ups.upsample(a, .{ .width = 0, .height = 1, .data = &.{} }, 2, &defaults.weights2, 1, 1));
	try std.testing.expectError(error.GenericError, ups.upsample(a, .{ .width = 2, .height = 1, .data = &input }, 2, &defaults.weights2, 4, 2));
	try std.testing.expectError(error.GenericError, ups.upsample(a, .{ .width = std.math.maxInt(usize), .height = 1, .data = &input }, 2, &defaults.weights2, 1, 1));
}
test "upsampling metadata selects each custom table and retains defaults for other factors" {
	const jxl = @import("../root.zig");
	const allocator = std.testing.allocator;
	var input: [fixture.input_3.len]sf.Fixed = undefined;
	for (&input, fixture.input_3) |*v, raw| v.* = sf.div(sf.fromInt(raw), sf.fromInt(256));
	inline for (.{ 2, 4, 8 }, 0..) |factor, index| {
		var metadata = jxl.codec.image_metadata.CustomTransformData{};
		metadata.custom_weights_mask = @as(u32, 1) << index;
		const field = "upsampling" ++ std.fmt.comptimePrint("{d}", .{factor}) ++ "_weights";
		for (&@field(metadata, field), 0..) |*v, i| v.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 7)) - 3)) / 64;
		const output = try ups.fromMetadata(allocator, .{ .width = 13, .height = 9, .data = &input }, factor, &metadata, 13 * factor, 9 * factor);
		defer allocator.free(output);
		const expected = @field(fixture, "output_3_" ++ std.fmt.comptimePrint("{d}", .{factor}));
		for (output, expected) |v, raw| {
			const delta = sf.sub(v, sf.div(sf.fromInt(raw), sf.fromInt(1 << 24)));
			try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(1), sf.fromInt(1 << 20))) <= 0);
		}
		metadata.custom_weights_mask = 0;
		const default_output = try ups.fromMetadata(allocator, .{ .width = 13, .height = 9, .data = &input }, factor, &metadata, 13 * factor, 9 * factor);
		defer allocator.free(default_output);
		const default_expected = @field(fixture, "output_2_" ++ std.fmt.comptimePrint("{d}", .{factor}));
		for (default_output, default_expected) |v, raw| {
			const delta = sf.sub(v, sf.div(sf.fromInt(raw), sf.fromInt(1 << 24)));
			try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(1), sf.fromInt(1 << 20))) <= 0);
		}
	}
}
fn customWeights(allocator: std.mem.Allocator) !void {
	const jxl = @import("../root.zig");
	var metadata = jxl.codec.image_metadata.CustomTransformData{};
	metadata.custom_weights_mask = 4;
	const input = [_]sf.Fixed{sf.fromInt(7)};
	const output = try ups.fromMetadata(allocator, .{ .width = 1, .height = 1, .data = &input }, 8, &metadata, 1, 1);
	defer allocator.free(output);
	try std.testing.expectEqualDeep(sf.fromInt(7), output[0]);
}
test "upsampling custom weights allocation failures release state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, customWeights, .{});
}
