//! JPEG XL 5x5 upsampling with compact symmetric weights and range clamping.
const std = @import("std");
const jxl = @import("../root.zig");
const original = jxl.base.soft_float;
const Finite = struct {
	pub const Fixed = original.Fixed;
	pub const zero = Fixed.zero;
	pub const add = original.add;
	pub const mul = original.mul;
	pub const cmp = original.cmp;
	pub const fromF32 = jxl.base.float16.loadFloat32Fixed;
	pub fn fromDefault(v: Fixed) Fixed {
		return v;
	}
};
const Float = struct {
	pub const Fixed = u32;
	pub const zero = @as(u32, 0);
	pub const add = @import("../base/binary32.zig").add;
	pub const mul = @import("../base/binary32.zig").mul;
	pub const cmp = @import("../base/binary32.zig").cmp;
	pub const fromF32 = @import("../base/binary32.zig").fromF32;
	pub fn fromDefault(v: original.Fixed) u32 {
		return @import("../base/fixed_display.zig").bits(v);
	}
	fn min(a: u32, b: u32) u32 {
		return if (cmp(a, b) < 0) a else b;
	}
	fn max(a: u32, b: u32) u32 {
		return if (cmp(a, b) > 0) a else b;
	}
	fn reduce(comptime op: fn (u32, u32) u32, v: [5]u32) u32 {
		return op(v[4], op(op(v[0], v[1]), op(v[2], v[3])));
	}
	fn bounds(v: [25]u32) [2]u32 {
		var low: [5]u32 = undefined;
		var high: [5]u32 = undefined;
		for (0..5) |x| {
			const column = [5]u32{ v[x], v[5 + x], v[10 + x], v[15 + x], v[20 + x] };
			low[x] = reduce(min, column);
			high[x] = reduce(max, column);
		}
		return .{ reduce(min, low), reduce(max, high) };
	}
	fn clamp(v: u32, low: u32, high: u32) u32 {
		return min(max(low, v), high);
	}
};
pub const Binary32 = Implementation(Float);
pub const Plane = Implementation(Finite).SamplePlane;
pub const upsample = Implementation(Finite).upsample;
pub const fromMetadata = Implementation(Finite).fromMetadata;
fn Implementation(comptime sf: type) type {
	return struct {
		pub const SamplePlane = struct { width: usize, height: usize, data: []const sf.Fixed };
		fn mirror(value: isize, size: usize) usize {
			const n: isize = @intCast(size);
			const v = @mod(value, 2 * n);
			return @intCast(if (v < n) v else 2 * n - 1 - v);
		}
		pub fn upsample(allocator: std.mem.Allocator, input: SamplePlane, factor: u4, weights: []const sf.Fixed, width: usize, height: usize) jxl.base.status.JxlError![]sf.Fixed {
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
				var sum = sf.zero;
				var low = input.data[(y / n) * input.width + x / n];
				var high = low;
				var neighborhood: if (sf == Float) [25]u32 else void = undefined;
				for (0..5) |py| for (0..5) |px| {
					const sy = mirror(@as(isize, @intCast(y / n)) + @as(isize, @intCast(py)) - 2, input.height);
					const sx = mirror(@as(isize, @intCast(x / n)) + @as(isize, @intCast(px)) - 2, input.width);
					const value = input.data[sy * input.width + sx];
					if (comptime sf == Float) neighborhood[5 * py + px] = value;
					if (sf.cmp(value, low) < 0) low = value;
					if (sf.cmp(value, high) > 0) high = value;
					const i = 5 * kx + (if (phase_x < half) px else 4 - px);
					const j = 5 * ky + (if (phase_y < half) py else 4 - py);
					const lo = @min(i, j);
					const hi = @max(i, j);
					sum = sf.add(sum, sf.mul(value, weights[dim * lo - lo * (lo + 1) / 2 + hi]));
				};
				if (comptime sf == Float) {
					const bounds = Float.bounds(neighborhood);
					output[y * width + x] = Float.clamp(sum, bounds[0], bounds[1]);
				} else output[y * width + x] = if (sf.cmp(sum, low) < 0) low else if (sf.cmp(sum, high) > 0) high else sum;
			};
			return output;
		}
		pub fn fromMetadata(allocator: std.mem.Allocator, input: SamplePlane, factor: u4, metadata: *const jxl.codec.image_metadata.CustomTransformData, width: usize, height: usize) jxl.base.status.JxlError![]sf.Fixed {
			const defaults = @import("upsampling_weights.zig");
			inline for (.{ 2, 4, 8 }, 0..) |n, index| {
				if (factor == n) {
					const values = @field(defaults, "weights" ++ std.fmt.comptimePrint("{d}", .{n}));
					const weights = comptime blk: {
						@setEvalBranchQuota(100000);
						var table: [values.len]sf.Fixed = undefined;
						for (values, &table) |v, *out| out.* = sf.fromDefault(v);
						break :blk table;
					};
					if (metadata.custom_weights_mask & (@as(u32, 1) << index) == 0)
						return @This().upsample(allocator, input, factor, &weights, width, height);
					const custom = try allocator.alloc(sf.Fixed, weights.len);
					defer allocator.free(custom);
					for (@field(metadata, "upsampling" ++ std.fmt.comptimePrint("{d}", .{n}) ++ "_weights"), custom) |value, *dest| dest.* = try sf.fromF32(value);
					return @This().upsample(allocator, input, factor, custom, width, height);
				}
			}
			return error.GenericError;
		}
	};
}
