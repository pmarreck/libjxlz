const std = @import("std");
const sf = @import("../root.zig").base.soft_float;
const filter = @import("vardct_filters.zig");
const fixture = @import("vardct_filters_fixture.zig");
fn check(allocator: std.mem.Allocator) !void {
	@setEvalBranchQuota(100000);
	inline for (0..4) |id| {
		const width: usize = if (id == 0) 1 else if (id == 1) 7 else 17;
		const height: usize = if (id == 0) 3 else if (id == 1) 9 else 17;
		const input = @field(fixture, "input_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const data = try allocator.alloc(sf.Fixed, input.len);
		defer allocator.free(data);
		const sigma = try allocator.alloc(sf.Fixed, ((width + 7) / 8) * ((height + 7) / 8));
		defer allocator.free(sigma);
		for (sigma, 0..) |*value, i| value.* = switch ((i % ((width + 7) / 8) + i / ((width + 7) / 8)) % 3) {
			0 => sf.parse("-0.75").?,
			1 => sf.parse("-1.5").?,
			else => sf.fromInt(-4),
		};
		var params = filter.Params{};
		if (id == 3) {
			params.gaborish = .{ .{ sf.parse("0.125").?, sf.parse("0.03125").? }, .{ sf.parse("-0.0625").?, sf.parse("0.125").? }, .{ sf.parse("0.25").?, sf.parse("-0.03125").? } };
			params.channel_scale = .{ sf.fromInt(32), sf.fromInt(4), sf.fromInt(2) };
			params.pass0_scale = sf.parse("0.75").?;
			params.pass2_scale = sf.fromInt(4);
			params.border_multiplier = sf.parse("0.5").?;
		}
		inline for (0..4) |kind| {
			for (data, input) |*value, raw| value.* = sf.div(sf.fromInt(raw), sf.fromInt(1 << 16));
			const image = filter.Image{ .width = width, .height = height, .data = data };
			if (kind == 0) try filter.gaborish(allocator, image, params) else try filter.epf(allocator, image, params, sigma, kind - 1);
			const expected = @field(fixture, "output_" ++ std.fmt.comptimePrint("{d}_{d}", .{ id, kind }));
			for (data, expected, 0..) |value, raw, i| {
				const delta = sf.sub(value, sf.div(sf.fromInt(raw), sf.fromInt(1 << 24)));
				const magnitude = if (delta.m < 0) sf.neg(delta) else delta;
				if (sf.cmp(magnitude, sf.div(sf.fromInt(1), sf.fromInt(1 << 18))) > 0) {
					std.debug.print("id={d} kind={d} index={d}\n", .{ id, kind, i });
					return error.TestUnexpectedResult;
				}
			}
		}
	}
}
test "Gaborish and EPF stages match complete upstream images including mirrored borders" {
	try check(std.testing.allocator);
}
test "filter headers preserve custom binary32 values without IEEE arithmetic" {
	var header = @import("../root.zig").codec.loop_filter.LoopFilter{};
	header.gab_custom = true;
	header.gab_x_weight1 = 0.125;
	header.gab_x_weight2 = 0.03125;
	header.gab_y_weight1 = 0;
	header.gab_y_weight2 = 0;
	header.gab_b_weight1 = 0;
	header.gab_b_weight2 = 0;
	header.epf_weight_custom = true;
	header.epf_channel_scale = .{ 32, 4, 2 };
	const params = try filter.Params.fromHeader(header);
	try std.testing.expectEqual(sf.div(sf.fromInt(1), sf.fromInt(8)), params.gaborish[0][0]);
	try std.testing.expectEqual(sf.fromInt(32), params.channel_scale[0]);
}

test "filters preserve constants and reject invalid planes kernels and sigma" {
	var data = [_]sf.Fixed{sf.fromInt(2)} ** 27;
	const image = filter.Image{ .width = 3, .height = 3, .data = &data };
	for ([_]u2{ 0, 1, 2 }) |stage| {
		try filter.epf(std.testing.allocator, image, .{}, &.{sf.fromInt(-1)}, stage);
		for (data) |value| try std.testing.expectEqual(sf.fromInt(2), value);
	}
	try std.testing.expectError(error.GenericError, filter.epf(std.testing.allocator, image, .{}, &.{}, 0));
	try std.testing.expectError(error.GenericError, filter.epf(std.testing.allocator, image, .{}, &.{sf.fromInt(-1)}, 3));
	var params = filter.Params{};
	params.gaborish[0] = .{ sf.div(sf.fromInt(-1), sf.fromInt(4)), sf.Fixed.zero };
	try std.testing.expectError(error.GenericError, filter.gaborish(std.testing.allocator, image, params));
	try std.testing.expectError(error.GenericError, filter.gaborish(std.testing.allocator, .{ .width = 3, .height = 2, .data = &data }, .{}));
}

test "filter allocation failures leave no partial buffers" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, check, .{});
}
