const Splines = @import("lib/codec/splines.zig").Splines;
export fn spline_cache(splines: *Splines, width: usize, height: usize, x: u32, b: u32) c_int {
	splines.initializeDrawCache(width, height, .{ .base_correlation_x = @bitCast(x), .base_correlation_b = @bitCast(b) }) catch return 1;
	return 0;
}
export fn spline_draw(splines: *const Splines, x: [*]f32, y: [*]f32, b: [*]f32, width: usize, row: usize) void {
	splines.addToRow(x[0..width], y[0..width], b[0..width], row, 0, width);
}
