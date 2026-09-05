const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("float_upsampling_fixture.zig");
test "nonfinite upsampling matches upstream complete stage output" {
	inline for (0..4) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		const width = @field(fixture, "width_" ++ key);
		const height = @field(fixture, "height_" ++ key);
		inline for (.{ 2, 4, 8 }, 0..) |factor, index| {
			var params = jxl.codec.image_metadata.CustomTransformData{};
			if (id == 3) {
				params.custom_weights_mask = 1 << index;
				for (&@field(params, "upsampling" ++ std.fmt.comptimePrint("{d}", .{factor}) ++ "_weights"), 0..) |*value, i| value.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 7)) - 3)) / 64;
			}
			const output = try jxl.codec.upsampling.Binary32.fromMetadata(std.testing.allocator, .{ .width = width, .height = height, .data = &@field(fixture, "input_" ++ key) }, factor, &params, width * factor, height * factor);
			defer std.testing.allocator.free(output);
			const expected = &@field(fixture, "output_" ++ key ++ "_" ++ std.fmt.comptimePrint("{d}", .{factor}));
			try std.testing.expectEqual(expected.len, output.len);
			for (expected, output, 0..) |wanted, actual, i| {
				if (wanted & 0x7fffffff > 0x7f800000) {
					try std.testing.expect(actual & 0x7fffffff > 0x7f800000);
				} else if (wanted & 0x7fffffff == 0 or wanted & 0x7fffffff == 0x7f800000) {
					if (actual != wanted) std.debug.print("upsampling id={d} factor={d} i={d} expected={x} actual={x}\n", .{ id, factor, i, wanted, actual });
					try std.testing.expectEqual(wanted, actual);
				} else {
					const value: f32 = @bitCast(actual);
					try std.testing.expect(std.math.isFinite(value));
					try std.testing.expectApproxEqAbs(@as(f32, @bitCast(wanted)), value, 0.000001);
				}
			}
		}
	}
}
