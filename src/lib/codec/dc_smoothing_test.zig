const std = @import("std");
const sf = @import("../base/soft_float.zig");
const fixture = @import("dc_smoothing_fixture.zig");
const smoothing = @import("dc_smoothing.zig");

fn checkSmoothing(allocator: std.mem.Allocator) !void {
	@setEvalBranchQuota(20000);
	const steps = [3]sf.Fixed{ sf.div(sf.fromInt(1), sf.fromInt(4)), sf.div(sf.fromInt(1), sf.fromInt(2)), sf.fromInt(1) };
	inline for (0..4) |id| {
		const width: usize = if (id == 0) 2 else 5;
		const height = 5;
		var image = @import("dc_group.zig").DcGroup{ .allocator = allocator, .width = width, .height = height };
		defer image.deinit();
		const input = @field(fixture, "input_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const expected = @field(fixture, "output_" ++ std.fmt.comptimePrint("{d}", .{id}));
		for (&image.planes, 0..) |*plane, c| {
			plane.width = width;
			plane.height = height;
			plane.samples = try allocator.alloc(sf.Fixed, width * height);
			for (plane.samples, 0..) |*value, i| value.* = sf.div(sf.fromInt(input[c * width * height + i]), sf.fromInt(1 << 16));
		}
		try smoothing.smooth(allocator, image.planes, steps);
		for (image.planes, 0..) |plane, c| for (plane.samples, 0..) |value, i| {
			const delta = sf.sub(value, sf.div(sf.fromInt(expected[c * width * height + i]), sf.fromInt(1 << 24)));
			const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
			try std.testing.expect(sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(1 << 20))) < 0);
			if (i < width or i >= width * (height - 1) or i % width == 0 or i % width == width - 1)
				try std.testing.expectEqual(sf.div(sf.fromInt(input[c * width * height + i]), sf.fromInt(1 << 16)), value);
		};
	}
}

test "adaptive DC smoothing matches upstream full planes and preserves borders" {
	try checkSmoothing(std.testing.allocator);
}

test "adaptive DC smoothing allocation failures release working planes" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSmoothing, .{});
}

test "adaptive DC smoothing rejects mismatched planes and nonpositive scales" {
	const Plane = @import("dc_group.zig").Plane;
	var samples = [_]sf.Fixed{sf.fromInt(1)} ** 9;
	var planes = [_]Plane{.{ .width = 3, .height = 3, .samples = &samples }} ** 3;
	const steps = [_]sf.Fixed{sf.fromInt(1)} ** 3;
	planes[1].width = 2;
	try std.testing.expectError(error.GenericError, smoothing.smooth(std.testing.allocator, planes, steps));
	planes[1].width = 3;
	try std.testing.expectError(error.GenericError, smoothing.smooth(std.testing.allocator, planes, .{steps[0], sf.Fixed.zero, steps[2]}));
	try smoothing.smooth(std.testing.allocator, planes, steps);
	for (samples) |sample| try std.testing.expect(sf.cmp(sf.sub(sample, sf.fromInt(1)), sf.div(sf.fromInt(1), sf.fromInt(1 << 50))) < 0);
}
