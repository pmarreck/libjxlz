const std = @import("std");
const modular_image = @import("../modular/modular_image.zig");
const splines_mod = @import("splines.zig");

fn bitDepthMax(bits: i32) f32 {
	if (bits <= 0) return 1.0;
	if (bits >= 31) return @floatFromInt(std.math.maxInt(u31));
	const shift: u5 = @intCast(bits);
	return @floatFromInt((@as(u32, 1) << shift) - 1);
}

pub const FloatImage = struct {
	data: []f32 = &.{},
	xsize: usize = 0,
	ysize: usize = 0,
	channels: usize = 0,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator, xsize: usize, ysize: usize, channels: usize) !FloatImage {
		const data = try allocator.alloc(f32, xsize * ysize * channels);
		@memset(data, 0.0);
		return .{
			.data = data,
			.xsize = xsize,
			.ysize = ysize,
			.channels = channels,
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *FloatImage) void {
		self.allocator.free(self.data);
		self.* = .{
			.allocator = self.allocator,
		};
	}

	/// Lifts modular integer output into normalized planar float rows so later
	/// render stages can apply splines and blending in the render-pipeline domain.
	pub fn fromModularImage(allocator: std.mem.Allocator, image: *const modular_image.Image, channels: usize) !FloatImage {
		if (channels > image.channels.items.len) return error.GenericError;
		var result = try FloatImage.init(allocator, image.w, image.h, channels);
		errdefer result.deinit();
		const max_value = bitDepthMax(image.bitdepth);

		for (0..channels) |c| {
			const src_ch = &image.channels.items[c];
			if (src_ch.w != image.w or src_ch.h != image.h) return error.GenericError;
			for (0..image.h) |y| {
				const src = src_ch.rowConst(y);
				const dst = result.row(y, c);
				for (src, 0..) |value, x| {
					dst[x] = @as(f32, @floatFromInt(value)) / max_value;
				}
			}
		}

		return result;
	}

	pub fn row(self: *FloatImage, y: usize, channel: usize) []f32 {
		const start = (channel * self.ysize + y) * self.xsize;
		return self.data[start .. start + self.xsize];
	}

	pub fn rowConst(self: *const FloatImage, y: usize, channel: usize) []const f32 {
		const start = (channel * self.ysize + y) * self.xsize;
		return self.data[start .. start + self.xsize];
	}

	/// Applies already-cached spline contributions to the first three float
	/// planes, which matches the upstream XYB row-rendering seam.
	pub fn applySplines(self: *FloatImage, splines: *const splines_mod.Splines) !void {
		if (self.channels < 3) return error.GenericError;
		for (0..self.ysize) |y| {
			splines.addToRow(self.row(y, 0), self.row(y, 1), self.row(y, 2), y, 0, self.xsize);
		}
	}
};

const testing = std.testing;

test "FloatImage fromModularImage normalizes integer color channels into float planes" {
	const allocator = testing.allocator;
	var image = try modular_image.Image.create(allocator, 3, 2, 8, 3);
	defer image.deinit();
	for (0..3) |c| {
		for (0..2) |y| {
			for (0..3) |x| {
				image.channels.items[c].row(y)[x] = @intCast(100 * c + 10 * y + x);
			}
		}
	}

	var rendered = try FloatImage.fromModularImage(allocator, &image, 3);
	defer rendered.deinit();

	try testing.expectEqual(@as(usize, 3), rendered.xsize);
	try testing.expectEqual(@as(usize, 2), rendered.ysize);
	try testing.expectEqual(@as(usize, 3), rendered.channels);
	try testing.expectEqual(@as(f32, 0), rendered.rowConst(0, 0)[0]);
	try testing.expectApproxEqAbs(@as(f32, 112.0 / 255.0), rendered.rowConst(1, 1)[2], 1.0e-6);
	try testing.expectApproxEqAbs(@as(f32, 211.0 / 255.0), rendered.rowConst(1, 2)[1], 1.0e-6);
}

test "FloatImage applySplines uses parsed draw cache to modify XYB rows" {
	const allocator = testing.allocator;
	var image = try modular_image.Image.create(allocator, 64, 64, 8, 3);
	defer image.deinit();

	var color = splines_mod.zero_dct32;
	color[0] = 0.49497476;
	var sigma = splines_mod.zero_dct32;
	sigma[0] = 2.357;
	var spline = splines_mod.Spline{
		.control_points = try allocator.dupe(splines_mod.Point, &.{
			.{ .x = 10, .y = 10 },
			.{ .x = 20, .y = 10 },
			.{ .x = 30, .y = 10 },
		}),
		.color_dct = .{ splines_mod.zero_dct32, splines_mod.zero_dct32, color },
		.sigma_dct = sigma,
	};
	defer spline.deinit(allocator);

	const quantized = try splines_mod.QuantizedSpline.create(allocator, &spline, 0, 0.0, 1.0);
	var owned_splines = try allocator.alloc(splines_mod.QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try allocator.dupe(splines_mod.Point, &.{spline.control_points[0]});

	var splines = splines_mod.Splines.init(allocator);
	defer splines.deinit();
	splines.assignOwned(0, owned_splines, starting_points);
	try splines.initializeDrawCache(64, 64, .{});

	var rendered = try FloatImage.fromModularImage(allocator, &image, 3);
	defer rendered.deinit();
	try rendered.applySplines(&splines);

	var touched = false;
	for (0..64) |x| {
		if (@abs(rendered.rowConst(10, 2)[x]) > 0.0) {
			touched = true;
			break;
		}
	}
	try testing.expect(touched);
}

test "FloatImage fromModularImage rejects subsampled color channels for now" {
	const allocator = testing.allocator;
	var image = try modular_image.Image.create(allocator, 4, 4, 8, 3);
	defer image.deinit();
	image.channels.items[1].deinit();
	image.channels.items[1] = try modular_image.Channel.create(allocator, 2, 2, 1, 1);

	try testing.expectError(error.GenericError, FloatImage.fromModularImage(allocator, &image, 3));
}

test "FloatImage applySplines rejects images without three XYB planes" {
	const allocator = testing.allocator;
	var rendered = try FloatImage.init(allocator, 4, 4, 1);
	defer rendered.deinit();
	var splines = splines_mod.Splines.init(allocator);
	defer splines.deinit();

	try testing.expectError(error.GenericError, rendered.applySplines(&splines));
}
