const std = @import("std");
const transfer = @import("output_transfer.zig");
const color = @import("color_encoding.zig");
const fixture = @import("transfer_stage_fixture.zig");
test "transfer stage matches upstream thresholds and intensity targets" {
	@setEvalBranchQuota(20000);
	const tfs = [_]color.TransferFunction{ .bt709, .linear, .srgb, .pq, .dci, .hlg, .unknown };
	inline for (0..28) |id| {
		const tf = color.CustomTransferFunction{ .transfer_function = tfs[id % 7], .have_gamma = id % 7 == 6, .gamma = 4500000 };
		const intensity: f32 = if (id / 7 == 0) 255 else if (id / 7 == 1) 334 else if (id / 7 == 2) 1000 else 10000;
		const expected = &@field(fixture, std.fmt.comptimePrint((if (id % 7 == 3) "scalar_" else "output_") ++ "{d}", .{id}));
		for (fixture.inputs, expected, 0..) |value, bits, i| {
			const actual = try transfer.fromLinear(.{ value, value * 0.5, value * 0.25 }, tf, intensity, .{ 0.2126, 0.7152, 0.0722 });
			for (actual, bits) |v, b| {
				const wanted: f32 = @bitCast(b);
				if (wanted == 0) try std.testing.expectEqual(b, @as(u32, @bitCast(v)));
				// The upstream rational sRGB approximation diverges above 1.
				const tolerance: f32 = if (id % 7 == 2 and @abs(value) > 1) 1.0 / 255.0 else if (id % 7 == 3) 0.000002 else 0.0002;
				if (!std.math.isFinite(v) or @abs(v - wanted) > tolerance) {
					std.debug.print("stage id={d} sample={d} actual={d} expected={d}\n", .{ id, i, v, wanted });
					return error.TestUnexpectedResult;
				}
			}
		}
	}
}
