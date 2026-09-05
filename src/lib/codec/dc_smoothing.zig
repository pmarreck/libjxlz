//! Adaptive DC smoothing over the complete decoded DC image.
const std = @import("std");
const sf = @import("../base/soft_float.zig");
const JxlError = @import("../base/status.zig").JxlError;
const Plane = @import("dc_group.zig").Plane;
const side_weight = sf.parse("0.20345139757231578") orelse unreachable;
const corner_weight = sf.parse("0.0334829185968739") orelse unreachable;
const center_weight = sf.sub(sf.fromInt(1), sf.mul(sf.fromInt(4), sf.add(side_weight, corner_weight)));

/// All three planes must cover the same full-resolution DC grid. Reads the
/// original image throughout; commits the smoothed pixels after the last row.
pub fn smooth(allocator: std.mem.Allocator, planes: [3]Plane, dc_steps: [3]sf.Fixed) JxlError!void {
	const width = planes[0].width;
	const height = planes[0].height;
	const area = std.math.mul(usize, width, height) catch return error.GenericError;
	for (planes, dc_steps) |plane, step| {
		if (plane.width != width or plane.height != height or plane.samples.len != area or step.m <= 0)
			return error.GenericError;
	}
	if (width <= 2 or height <= 2) return;
	const storage_len = std.math.mul(usize, area, 3) catch return error.GenericError;
	const output = try allocator.alloc(sf.Fixed, storage_len);
	defer allocator.free(output);
	for (planes, 0..) |plane, c| @memcpy(output[c * area ..][0..area], plane.samples);
	for (1..height - 1) |y| for (1..width - 1) |x| {
		const i = y * width + x;
		var gap = sf.div(sf.fromInt(1), sf.fromInt(2));
		for (planes, dc_steps, 0..) |plane, step, c| {
			const row = plane.samples;
			const corners = sf.add(sf.add(row[i - width - 1], row[i - width + 1]), sf.add(row[i + width - 1], row[i + width + 1]));
			const sides = sf.add(sf.add(row[i - 1], row[i + 1]), sf.add(row[i - width], row[i + width]));
			const filtered = sf.add(sf.mul(corners, corner_weight), sf.add(sf.mul(sides, side_weight), sf.mul(row[i], center_weight)));
			output[c * area + i] = filtered;
			const difference = sf.div(sf.sub(row[i], filtered), step);
			const magnitude = if (difference.m < 0) sf.neg(difference) else difference;
			if (sf.cmp(magnitude, gap) > 0) gap = magnitude;
		}
		const factor_raw = sf.sub(sf.fromInt(3), sf.mul(sf.fromInt(4), gap));
		const factor = if (factor_raw.m < 0) sf.Fixed.zero else factor_raw;
		for (planes, 0..) |plane, c| {
			output[c * area + i] = sf.add(plane.samples[i], sf.mul(sf.sub(output[c * area + i], plane.samples[i]), factor));
		}
	};
	for (planes, 0..) |plane, c| @memcpy(plane.samples, output[c * area ..][0..area]);
}
