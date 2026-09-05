const std = @import("std");
const sf = @import("../root.zig").base.soft_float;
const blend = @import("blending.zig");
const fixture = @import("blending_fixture.zig");
test "all blend modes match upstream with alpha selection, clamping and association" {
	@setEvalBranchQuota(50000);
	inline for (0..64) |id| {
		const mode = id % 8;
		const clamp = (id / 8) % 2 != 0;
		const kind = id / 16;
		const n = if (kind == 0) 0 else if (kind == 1) 1 else 2;
		const channels = 3 + n;
		const alpha = if (kind == 2) 1 else 0;
		const color = blend.Info{ .mode = @enumFromInt(mode), .clamp = clamp, .alpha_channel = alpha };
		var extras: [n]blend.Extra = undefined;
		for (&extras, 0..) |*extra, i| extra.* = .{ .is_alpha = !(kind == 2 and i == 0), .associated = kind == 3 and i == 0, .blend = .{ .mode = @enumFromInt((mode + i + 1) % 8), .alpha_channel = alpha, .clamp = clamp } };
		const bg = @field(fixture, "bg_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const fg = @field(fixture, "fg_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const expected = @field(fixture, "output_" ++ std.fmt.comptimePrint("{d}", .{id}));
		for (0..16) |x| {
			var b: [channels]sf.Fixed = undefined;
			var f: [channels]sf.Fixed = undefined;
			var output: [channels]sf.Fixed = undefined;
			for (&b, &f, 0..) |*bv, *fv, c| {
				bv.* = sf.div(sf.fromInt(bg[x * channels + c]), sf.fromInt(8));
				fv.* = sf.div(sf.fromInt(fg[x * channels + c]), sf.fromInt(8));
			}
			const original_b = b;
			const original_f = f;
			try blend.pixel(&b, &f, &output, color, &extras);
			try std.testing.expectEqualDeep(original_b, b);
			try std.testing.expectEqualDeep(original_f, f);
			for (output, 0..) |value, c| {
				const delta = sf.sub(value, sf.div(sf.fromInt(expected[x * channels + c]), sf.fromInt(1 << 20)));
				if (sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(1), sf.fromInt(1 << 16))) > 0) {
					std.debug.print("id={d} pixel={d} channel={d}\n", .{ id, x, c });
					return error.TestUnexpectedResult;
				}
			}
		}
	}
}
test "blending rejects shape, output aliasing and alpha indexes before writes" {
	const one = sf.fromInt(1);
	var bg = [_]sf.Fixed{one} ** 4;
	const fg = bg;
	var output = [_]sf.Fixed{sf.fromInt(7)} ** 4;
	const untouched = output;
	var extras = [_]blend.Extra{.{ .is_alpha = true }};
	try std.testing.expectError(error.GenericError, blend.pixel(&bg, &fg, output[0..3], .{}, &extras));
	try std.testing.expectError(error.GenericError, blend.pixel(bg[0..3], &fg, &output, .{}, &extras));
	try std.testing.expectError(error.GenericError, blend.pixel(&bg, &fg, &bg, .{}, &extras));
	try std.testing.expectError(error.GenericError, blend.pixel(&bg, &fg, &output, .{ .mode = .blend_above, .alpha_channel = 1 }, &extras));
	extras[0].blend = .{ .mode = .alpha_add_below, .alpha_channel = 1 };
	try std.testing.expectError(error.GenericError, blend.pixel(&bg, &fg, &output, .{}, &extras));
	try std.testing.expectEqualDeep(untouched, output);
	try std.testing.expectEqualDeep(fg, bg);
}
test "color alpha blending overrides the selected extra channel blend" {
	const one = sf.fromInt(1);
	const half = sf.div(one, sf.fromInt(2));
	const bg = [_]sf.Fixed{ one, one, one, half };
	const fg = [_]sf.Fixed{ sf.Fixed.zero, sf.Fixed.zero, sf.Fixed.zero, half };
	var output: [4]sf.Fixed = undefined;
	const extras = [_]blend.Extra{.{ .is_alpha = true, .blend = .{ .mode = .replace } }};
	try blend.pixel(&bg, &fg, &output, .{ .mode = .blend_above }, &extras);
	for (output[0..3]) |value| try std.testing.expectEqualDeep(sf.div(one, sf.fromInt(3)), value);
	try std.testing.expectEqualDeep(sf.div(sf.fromInt(3), sf.fromInt(4)), output[3]);
}
