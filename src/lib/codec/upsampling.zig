//! JPEG XL 5x5 upsampling with compact symmetric weights and range clamping.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
pub const Plane = struct { width: usize, height: usize, data: []const sf.Fixed };
fn mirror(value: isize, size: usize) usize {
	const n: isize = @intCast(size);
	const v = @mod(value, 2 * n);
	return @intCast(if (v < n) v else 2 * n - 1 - v);
}
pub fn upsample(allocator: std.mem.Allocator, input: Plane, factor: u4, weights: []const sf.Fixed, width: usize, height: usize) jxl.base.status.JxlError![]sf.Fixed {
	if (factor != 2 and factor != 4 and factor != 8) return error.GenericError;
	const n: usize = factor;
	const half = n / 2;
	const dim = 5 * half;
	if (weights.len != dim * (dim + 1) / 2 or input.width == 0 or input.height == 0) return error.GenericError;
	if (input.width > std.math.maxInt(isize) / 2 or input.height > std.math.maxInt(isize) / 2) return error.GenericError;
	const area = std.math.mul(usize, input.width, input.height) catch return error.GenericError;
	if (input.data.len != area) return error.GenericError;
	const max_width = std.math.mul(usize, input.width, n) catch return error.GenericError;
	const max_height = std.math.mul(usize, input.height, n) catch return error.GenericError;
	if (width > max_width or width <= max_width - n or height > max_height or height <= max_height - n) return error.GenericError;
	const count = std.math.mul(usize, width, height) catch return error.GenericError;
	const output = try allocator.alloc(sf.Fixed, count);
	for (0..height) |y| for (0..width) |x| {
		const phase_x = x % n;
		const phase_y = y % n;
		const kx = if (phase_x < half) phase_x else n - 1 - phase_x;
		const ky = if (phase_y < half) phase_y else n - 1 - phase_y;
		var sum = sf.Fixed.zero;
		var low = input.data[(y / n) * input.width + x / n];
		var high = low;
		for (0..5) |py| for (0..5) |px| {
			const sy = mirror(@as(isize, @intCast(y / n)) + @as(isize, @intCast(py)) - 2, input.height);
			const sx = mirror(@as(isize, @intCast(x / n)) + @as(isize, @intCast(px)) - 2, input.width);
			const value = input.data[sy * input.width + sx];
			if (sf.cmp(value, low) < 0) low = value;
			if (sf.cmp(value, high) > 0) high = value;
			const i = 5 * kx + (if (phase_x < half) px else 4 - px);
			const j = 5 * ky + (if (phase_y < half) py else 4 - py);
			const lo = @min(i, j);
			const hi = @max(i, j);
			sum = sf.add(sum, sf.mul(value, weights[dim * lo - lo * (lo + 1) / 2 + hi]));
		};
		output[y * width + x] = if (sf.cmp(sum, low) < 0) low else if (sf.cmp(sum, high) > 0) high else sum;
	};
	return output;
}
pub fn fromMetadata(allocator: std.mem.Allocator, input: Plane, factor: u4, metadata: *const jxl.codec.image_metadata.CustomTransformData, width: usize, height: usize) jxl.base.status.JxlError![]sf.Fixed {
	const defaults = @import("upsampling_weights.zig");
	inline for (.{ 2, 4, 8 }, 0..) |n, index| {
		if (factor == n) {
			const weights = &@field(defaults, "weights" ++ std.fmt.comptimePrint("{d}", .{n}));
			if (metadata.custom_weights_mask & (@as(u32, 1) << index) == 0)
				return upsample(allocator, input, factor, weights, width, height);
			const custom = try allocator.alloc(sf.Fixed, weights.len);
			defer allocator.free(custom);
			for (@field(metadata, "upsampling" ++ std.fmt.comptimePrint("{d}", .{n}) ++ "_weights"), custom) |value, *dest| dest.* = try jxl.base.float16.loadFloat32Fixed(value);
			return upsample(allocator, input, factor, custom, width, height);
		}
	}
	return error.GenericError;
}
