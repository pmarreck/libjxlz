//! Scaled power-of-two inverse DCT with JPEG XL's transposed coefficient layout.
const std = @import("std");
const sf = @import("../base/soft_float.zig");
const JxlError = @import("../base/status.zig").JxlError;
const strategy = @import("ac_strategy.zig");

const sqrt2 = sf.sqrt(sf.fromInt(2));
const multipliers = blk: {
	@setEvalBranchQuota(2_000_000);
	var values: [256]sf.Fixed = @splat(sf.Fixed.zero);
	var n: usize = 4;
	while (n <= 256) : (n *= 2) {
		for (0..n / 2) |i| {
			const turns = sf.div(sf.fromInt(@intCast(2 * i + 1)), sf.fromInt(@intCast(4 * n)));
			values[n / 2 + i] = sf.div(sf.fromInt(1), sf.mul(sf.fromInt(2), sf.cosTurns(turns)));
		}
	}
	break :blk values;
};

/// O(width * height * (log width + log height)). Allocates one intermediate
/// plane and reusable recursion scratch; coefficient input is never modified.
pub fn inverse(allocator: std.mem.Allocator, width: usize, height: usize,
	coefficients: []const sf.Fixed, pixels: []sf.Fixed, stride: usize) JxlError!void
{
	if (width == 0 or height == 0 or width > 256 or height > 256 or
		width & (width - 1) != 0 or height & (height - 1) != 0) return error.GenericError;
	const area = width * height;
	if (coefficients.len != area or stride < width or pixels.len < width or
		height - 1 > (pixels.len - width) / stride) return error.GenericError;
	const workspace = try allocator.alloc(sf.Fixed, area + 2 * @max(width, height));
	defer allocator.free(workspace);
	const intermediate = workspace[0..area];
	const scratch = workspace[area..];
	for (0..height) |fy| {
		const start = if (height >= width) fy else fy * width;
		const step = if (height >= width) height else 1;
		inverse1D(width, coefficients[start..], step, intermediate[fy * width ..], 1, scratch);
	}
	for (0..width) |x| inverse1D(height, intermediate[x..], width, pixels[x..], stride, scratch);
}

fn inverse1D(n: usize, input: []const sf.Fixed, input_stride: usize,
	output: []sf.Fixed, output_stride: usize, scratch: []sf.Fixed) void
{
	if (n == 1) {
		output[0] = input[0];
		return;
	}
	if (n == 2) {
		const a = input[0];
		const b = input[input_stride];
		output[0] = sf.add(a, b);
		output[output_stride] = sf.sub(a, b);
		return;
	}
	const half = n / 2;
	const work = scratch[0..n];
	const next = scratch[n..];
	for (0..half) |i| {
		work[i] = input[2 * i * input_stride];
		work[half + i] = input[(2 * i + 1) * input_stride];
	}
	inverse1D(half, work[0..half], 1, work[0..half], 1, next);
	var i = n - 1;
	while (i > half) : (i -= 1) work[i] = sf.add(work[i], work[i - 1]);
	work[half] = sf.mul(work[half], sqrt2);
	inverse1D(half, work[half..], 1, work[half..], 1, next);
	for (0..half) |j| {
		const odd = sf.mul(work[half + j], multipliers[half + j]);
		output[j * output_stride] = sf.add(work[j], odd);
		output[(n - j - 1) * output_stride] = sf.sub(work[j], odd);
	}
}

/// Apply any of the 27 JPEG XL block strategies to its coefficient block.
pub fn transform(allocator: std.mem.Allocator, raw: u8, coefficients: []const sf.Fixed,
	pixels: []sf.Fixed, stride: usize) JxlError!void
{
	const extent = try strategy.strategyExtent(raw);
	if (raw == 0 or extent.x * extent.y != 1)
		return inverse(allocator, 8 * extent.x, 8 * extent.y, coefficients, pixels, stride);
	if (coefficients.len != 64 or stride < 8 or pixels.len < 8 or 7 > (pixels.len - 8) / stride)
		return error.GenericError;
	const workspace = try allocator.alloc(sf.Fixed, 128);
	defer allocator.free(workspace);
	const source = workspace[0..64];
	const temp = workspace[64..];
	@memcpy(source, coefficients);
	if (raw == 2) {
		var side: usize = 2;
		while (side <= 8) : (side *= 2) {
			const half = side / 2;
			for (0..half) |y| for (0..half) |x| {
				const values = fourDCs(source[y * 8 + x], source[y * 8 + half + x],
					source[(y + half) * 8 + x], source[(y + half) * 8 + half + x]);
				temp[2 * y * 8 + 2 * x] = values[0];
				temp[2 * y * 8 + 2 * x + 1] = values[1];
				temp[(2 * y + 1) * 8 + 2 * x] = values[2];
				temp[(2 * y + 1) * 8 + 2 * x + 1] = values[3];
			};
			for (0..side) |y| @memcpy(source[y * 8 ..][0..side], temp[y * 8 ..][0..side]);
		}
		for (0..8) |y| @memcpy(pixels[y * stride ..][0..8], source[y * 8 ..][0..8]);
		return;
	}
	if (raw == 1 or raw == 3) {
		const dcs = fourDCs(source[0], source[1], source[8], source[9]);
		for (0..2) |y| for (0..2) |x| {
			if (raw == 1) {
				var residual = sf.Fixed.zero;
				for (0..4) |iy| for (0..4) |ix| {
					if (ix != 0 or iy != 0) residual = sf.add(residual, source[(y + iy * 2) * 8 + x + ix * 2]);
				};
				const center = sf.sub(dcs[y * 2 + x], sf.div(residual, sf.fromInt(16)));
				pixels[(4 * y + 1) * stride + 4 * x + 1] = center;
				for (0..4) |iy| for (0..4) |ix| {
					if (ix != 1 or iy != 1)
						pixels[(4 * y + iy) * stride + 4 * x + ix] = sf.add(source[(y + iy * 2) * 8 + x + ix * 2], center);
				};
				pixels[4 * y * stride + 4 * x] = sf.add(source[(y + 2) * 8 + x + 2], center);
			} else {
				temp[0] = dcs[y * 2 + x];
				for (0..4) |iy| for (0..4) |ix| {
					if (ix != 0 or iy != 0) temp[iy * 4 + ix] = source[(y + iy * 2) * 8 + x + ix * 2];
				};
				try inverse(allocator, 4, 4, temp[0..16], pixels[y * 4 * stride + x * 4 ..], stride);
			}
		};
		return;
	}
	if (raw == 12 or raw == 13) {
		for (0..2) |part| {
			temp[0] = if (part == 0) sf.add(source[0], source[8]) else sf.sub(source[0], source[8]);
			for (0..4) |iy| for (0..8) |ix| {
				if (ix != 0 or iy != 0) temp[iy * 8 + ix] = source[(part + iy * 2) * 8 + ix];
			};
			const width: usize = if (raw == 12) 8 else 4;
			const height: usize = if (raw == 12) 4 else 8;
			const offset = if (raw == 12) part * 4 * stride else part * 4;
			try inverse(allocator, width, height, temp[0..32], pixels[offset..], stride);
		}
		return;
	}
	const basis = @import("afv_basis.zig").basis;
	const afv_x: usize = (raw - 14) & 1;
	const afv_y: usize = (raw - 14) / 2;
	temp[0] = sf.mul(sf.add(sf.add(source[0], source[8]), source[1]), sf.fromInt(4));
	for (0..4) |iy| for (0..4) |ix| {
		if (ix != 0 or iy != 0) temp[iy * 4 + ix] = source[iy * 2 * 8 + ix * 2];
	};
	for (0..16) |p| {
		var sum = sf.Fixed.zero;
		for (0..16) |k| sum = sf.add(sum, sf.mul(temp[k], basis[k][p]));
		temp[16 + p] = sum;
	}
	for (0..4) |iy| for (0..4) |ix| {
		const sy = if (afv_y == 1) 3 - iy else iy;
		const sx = if (afv_x == 1) 3 - ix else ix;
		pixels[(iy + afv_y * 4) * stride + afv_x * 4 + ix] = temp[16 + sy * 4 + sx];
	};
	temp[0] = sf.sub(sf.add(source[0], source[8]), source[1]);
	for (0..4) |iy| for (0..4) |ix| {
		if (ix != 0 or iy != 0) temp[iy * 4 + ix] = source[iy * 2 * 8 + ix * 2 + 1];
	};
	try inverse(allocator, 4, 4, temp[0..16], pixels[afv_y * 4 * stride + (1 - afv_x) * 4 ..], stride);
	temp[0] = sf.sub(source[0], source[8]);
	for (0..4) |iy| for (0..8) |ix| {
		if (ix != 0 or iy != 0) temp[iy * 8 + ix] = source[(1 + iy * 2) * 8 + ix];
	};
	try inverse(allocator, 8, 4, temp[0..32], pixels[(1 - afv_y) * 4 * stride ..], stride);
}

fn fourDCs(c00: sf.Fixed, c01: sf.Fixed, c10: sf.Fixed, c11: sf.Fixed) [4]sf.Fixed {
	const a = sf.add(c00, c01);
	const b = sf.add(c10, c11);
	const c = sf.sub(c00, c01);
	const d = sf.sub(c10, c11);
	return .{ sf.add(a, b), sf.sub(a, b), sf.add(c, d), sf.sub(c, d) };
}

const dcResample = blk: {
	@setEvalBranchQuota(2_000_000);
	var values: [64]sf.Fixed = @splat(sf.Fixed.zero);
	var n: usize = 1;
	while (n <= 32) : (n *= 2) {
		for (0..n) |i| {
			var scale = sf.fromInt(1);
			for ([_]usize{ 4, 2, 1 }) |divisor| {
				const turns = sf.div(sf.fromInt(@intCast(i)), sf.fromInt(@intCast(divisor * 8 * n)));
				scale = sf.mul(scale, sf.cosTurns(turns));
			}
			values[n + i] = sf.div(sf.fromInt(1), scale);
		}
	}
	break :blk values;
};

/// Convert a strategy's blockwise DC samples to its LLF coefficient rectangle.
/// The remaining coefficients retain their AC values.
pub fn lowestFrequencies(allocator: std.mem.Allocator, raw: u8, dc: []const sf.Fixed,
	stride: usize, coefficients: []sf.Fixed) JxlError!void
{
	const extent = try strategy.strategyExtent(raw);
	const width = extent.x;
	const height = extent.y;
	const area = width * height;
	if (stride < width or dc.len < width or height - 1 > (dc.len - width) / stride or
		coefficients.len != 64 * area) return error.GenericError;
	if (area == 1) {
		coefficients[0] = dc[0];
		return;
	}
	const max_side = @max(width, height);
	const workspace = try allocator.alloc(sf.Fixed, area + 3 * max_side);
	defer allocator.free(workspace);
	const intermediate = workspace[0..area];
	const vector = workspace[area .. area + max_side];
	const scratch = workspace[area + max_side ..];
	for (0..width) |x| {
		for (0..height) |y| vector[y] = dc[y * stride + x];
		forward1D(vector[0..height], scratch);
		for (0..height) |fy| intermediate[fy * width + x] = sf.div(vector[fy], sf.fromInt(@intCast(height)));
	}
	for (0..height) |fy| {
		const row = intermediate[fy * width ..][0..width];
		forward1D(row, scratch);
		for (row, 0..) |value, fx| {
			const position = if (height >= width) fx * 8 * height + fy else fy * 8 * width + fx;
			const normalized = sf.div(value, sf.fromInt(@intCast(width)));
			coefficients[position] = sf.mul(sf.mul(normalized, dcResample[width + fx]), dcResample[height + fy]);
		}
	}
}

fn forward1D(values: []sf.Fixed, scratch: []sf.Fixed) void {
	const n = values.len;
	if (n == 1) return;
	if (n == 2) {
		const a = values[0];
		const b = values[1];
		values[0] = sf.add(a, b);
		values[1] = sf.sub(a, b);
		return;
	}
	const half = n / 2;
	const temp = scratch[0..n];
	const next = scratch[n..];
	for (0..half) |i| temp[i] = sf.add(values[i], values[n - i - 1]);
	forward1D(temp[0..half], next);
	for (0..half) |i| temp[half + i] = sf.mul(sf.sub(values[i], values[n - i - 1]), multipliers[half + i]);
	forward1D(temp[half..], next);
	temp[half] = sf.add(sf.mul(temp[half], sqrt2), temp[half + 1]);
	for (1..half - 1) |i| temp[half + i] = sf.add(temp[half + i], temp[half + i + 1]);
	for (0..half) |i| {
		values[2 * i] = temp[i];
		values[2 * i + 1] = temp[half + i];
	}
}
