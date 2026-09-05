const std = @import("std");
const blend = @import("blending.zig");
const fixture = @import("float_blending_fixture.zig");
test "integer binary32 blending matches upstream finite and special sample classes" {
	@setEvalBranchQuota(50000);
	inline for (0..64) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		const mode = id % 8;
		const clamp = (id / 8) % 2 != 0;
		const kind = id / 16;
		const n = if (kind == 0) 0 else if (kind == 1) 1 else 2;
		const channels = 3 + n;
		const alpha = if (kind == 2) 1 else 0;
		const color = blend.Info{ .mode = @enumFromInt(mode), .clamp = clamp, .alpha_channel = alpha };
		var extras: [n]blend.Extra = undefined;
		for (&extras, 0..) |*extra, i| extra.* = .{ .is_alpha = !(kind == 2 and i == 0), .associated = kind == 3 and i == 0, .blend = .{ .mode = @enumFromInt((mode + i + 1) % 8), .alpha_channel = alpha, .clamp = clamp } };
		const bg = @field(fixture, "bg_" ++ key);
		const fg = @field(fixture, "fg_" ++ key);
		const expected = @field(fixture, "output_" ++ key);
		for (0..16) |x| {
			var output: [channels]u32 = undefined;
			try blend.pixelBinary32(bg[x * channels ..][0..channels], fg[x * channels ..][0..channels], &output, color, &extras);
			for (output, 0..) |actual, c| {
				const bits = expected[x * channels + c];
				if (bits & 0x7fffffff > 0x7f800000 and !(kind == 0 and mode <= 1)) {
					if (actual & 0x7fffffff <= 0x7f800000) {
						std.debug.print("blend id={d} x={d} c={d} expected NaN got={x}\n", .{ id, x, c, actual });
						return error.TestUnexpectedResult;
					}
				} else if (bits & 0x7f800000 == 0x7f800000 or bits & 0x7fffffff == 0) {
					if (actual != bits) {
						std.debug.print("blend id={d} x={d} c={d} expected={x} got={x}\n", .{ id, x, c, bits, actual });
						return error.TestUnexpectedResult;
					}
				} else {
					const got: f32 = @bitCast(actual);
					const wanted: f32 = @bitCast(bits);
					if (!std.math.isFinite(got) or @abs(got - wanted) > 0.000001 + 0.000001 * @abs(wanted)) {
						std.debug.print("blend id={d} x={d} c={d} expected={x} got={x}\n", .{ id, x, c, bits, actual });
						return error.TestUnexpectedResult;
					}
				}
			}
		}
	}
}
