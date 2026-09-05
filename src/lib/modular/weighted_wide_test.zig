const std = @import("std");
const weighted = @import("weighted.zig");
const fixture = @import("weighted_wide_fixture.zig");
test "weighted predictor wide samples match upstream wrapping state" {
	var state = try weighted.State.init(std.testing.allocator, .{}, 16, 4);
	defer state.deinit();
	const pixels = fixture.pixels;
	for (0..4) |y| for (0..16) |x| {
		const n: i64 = if (y > 0) pixels[(y - 1) * 16 + x] else 0;
		const w: i64 = if (x > 0) pixels[y * 16 + x - 1] else n;
		const ne: i64 = if (y > 0) pixels[(y - 1) * 16 + @min(x + 1, 15)] else 0;
		const nw: i64 = if (y > 0 and x > 0) pixels[(y - 1) * 16 + x - 1] else n;
		const nn: i64 = if (y > 1) pixels[(y - 2) * 16 + x] else n;
		const prediction = state.predictNoProps(x, y, 16, n, w, ne, nw, nn);
		state.updateErrors(pixels[y * 16 + x], x, y, 16);
		const expected = fixture.state[y * 16 + x];
		const index = (if (y & 1 != 0) @as(usize, 0) else 18) + x;
		try std.testing.expectEqual(expected[0], prediction);
		try std.testing.expectEqual(expected[1], state.errors[index]);
		for (0..4) |p| try std.testing.expectEqual(expected[p + 2], state.pred_errors[p][index]);
	};
}
