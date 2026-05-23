const std = @import("std");
const bits = @import("../base/bits.zig");
const common = @import("../base/common.zig");

pub const Dct32 = [32]f32;

pub const zero_dct32: Dct32 = [_]f32{0} ** 32;
pub const kDesiredRenderingDistance: f32 = 1.0;

pub const ColorCorrelation = struct {
	base_correlation_x: f32 = 0.0,
	base_correlation_b: f32 = 1.0,
	color_factor: f32 = 84.0,

	pub fn YtoXRatio(self: ColorCorrelation, x_factor: i32) f32 {
		return self.base_correlation_x + @as(f32, @floatFromInt(x_factor)) / self.color_factor;
	}

	pub fn YtoBRatio(self: ColorCorrelation, b_factor: i32) f32 {
		return self.base_correlation_b + @as(f32, @floatFromInt(b_factor)) / self.color_factor;
	}
};

pub const Point = struct {
	x: f32 = 0.0,
	y: f32 = 0.0,

	pub fn approxEq(a: Point, b: Point, tolerance: f32) bool {
		return @abs(a.x - b.x) <= tolerance and @abs(a.y - b.y) <= tolerance;
	}
};

pub const Spline = struct {
	control_points: []Point = &.{},
	color_dct: [3]Dct32 = .{ zero_dct32, zero_dct32, zero_dct32 },
	sigma_dct: Dct32 = zero_dct32,

	pub fn deinit(self: *Spline, allocator: std.mem.Allocator) void {
		allocator.free(self.control_points);
		self.* = .{};
	}
};

const PointDelta = struct {
	x: i64,
	y: i64,
};

const PointToDraw = struct {
	point: Point,
	multiplier: f32,
};

const SegmentByY = struct {
	y: usize,
	index: usize,
};

const kChannelWeight = [4]f32{ 0.0042, 0.075, 0.07, 0.3333 };
const kSqrt2: f32 = 1.41421356237;
const kSqrt0_5: f32 = 0.70710678118;
const kSplinePosLimit: f64 = 1 << 23;
const kMaxNumControlPoints: usize = 1 << 20;
const kMaxNumControlPointsPerPixelRatio: usize = 2;
const kDistanceExp: f32 = 3.0;

pub const SplineSegment = struct {
	center_x: f32,
	center_y: f32,
	maximum_distance: f32,
	inv_sigma: f32,
	sigma_over_4_times_intensity: f32,
	color: [3]f32,
};

fn adjustedQuant(adjustment: i32) f32 {
	return if (adjustment >= 0)
		1.0 + 0.125 * @as(f32, @floatFromInt(adjustment))
	else
		1.0 / (1.0 - 0.125 * @as(f32, @floatFromInt(adjustment)));
}

fn invAdjustedQuant(adjustment: i32) f32 {
	return if (adjustment >= 0)
		1.0 / (1.0 + 0.125 * @as(f32, @floatFromInt(adjustment)))
	else
		1.0 - 0.125 * @as(f32, @floatFromInt(adjustment));
}

fn scalarToF64(value: anytype) f64 {
	return switch (@typeInfo(@TypeOf(value))) {
		.int, .comptime_int => @floatFromInt(value),
		.float, .comptime_float => value,
		else => @compileError("unsupported spline scalar type"),
	};
}

/// Guards dequantized control points and delta terms against absurd coordinates
/// that would later overflow Catmull-Rom or draw-cache math.
fn validateSplinePointPos(x: anytype, y: anytype) !void {
	const xf = scalarToF64(x);
	const yf = scalarToF64(y);
	if (xf >= kSplinePosLimit or xf <= -kSplinePosLimit or yf >= kSplinePosLimit or yf <= -kSplinePosLimit) {
		return error.GenericError;
	}
}

pub const QuantizedSpline = struct {
	control_points: []PointDelta = &.{},
	color_dct: [3][32]i32 = [_][32]i32{[_]i32{0} ** 32} ** 3,
	sigma_dct: [32]i32 = [_]i32{0} ** 32,

	pub fn deinit(self: *QuantizedSpline, allocator: std.mem.Allocator) void {
		allocator.free(self.control_points);
		self.* = .{};
	}

	/// Encodes a dequantized spline into upstream-compatible delta-delta control
	/// points plus decorrelated integer DCT coefficients for later entropy coding.
	pub fn create(
		allocator: std.mem.Allocator,
		original: *const Spline,
		quantization_adjustment: i32,
		y_to_x: f32,
		y_to_b: f32,
	) !QuantizedSpline {
		if (original.control_points.len == 0) return error.GenericError;

		var result = QuantizedSpline{};
		result.control_points = try allocator.alloc(PointDelta, original.control_points.len - 1);
		errdefer result.deinit(allocator);

		const starting_point = original.control_points[0];
		var previous_x: i32 = @intFromFloat(@round(starting_point.x));
		var previous_y: i32 = @intFromFloat(@round(starting_point.y));
		var previous_delta_x: i32 = 0;
		var previous_delta_y: i32 = 0;

		for (original.control_points[1..], 0..) |point, i| {
			const new_x: i32 = @intFromFloat(@round(point.x));
			const new_y: i32 = @intFromFloat(@round(point.y));
			const new_delta_x = new_x - previous_x;
			const new_delta_y = new_y - previous_y;
			result.control_points[i] = .{
				.x = new_delta_x - previous_delta_x,
				.y = new_delta_y - previous_delta_y,
			};
			previous_delta_x = new_delta_x;
			previous_delta_y = new_delta_y;
			previous_x = new_x;
			previous_y = new_y;
		}

		const quant = adjustedQuant(quantization_adjustment);
		const inv_quant = invAdjustedQuant(quantization_adjustment);
		for ([_]usize{ 1, 0, 2 }) |c| {
			const factor: f32 = if (c == 0) y_to_x else if (c == 1) 0 else y_to_b;
			for (0..32) |i| {
				const dct_factor: f32 = if (i == 0) kSqrt2 else 1.0;
				const inv_dct_factor: f32 = if (i == 0) kSqrt0_5 else 1.0;
				const restored_y = @as(f32, @floatFromInt(result.color_dct[1][i])) * inv_dct_factor * kChannelWeight[1] * inv_quant;
				const decorrelated = original.color_dct[c][i] - factor * restored_y;
				result.color_dct[c][i] = toQuantizedInt(decorrelated * dct_factor * quant / kChannelWeight[c]);
			}
		}
		for (0..32) |i| {
			const dct_factor: f32 = if (i == 0) kSqrt2 else 1.0;
			result.sigma_dct[i] = toQuantizedInt(original.sigma_dct[i] * dct_factor * quant / kChannelWeight[3]);
		}

		return result;
	}

	/// Reconstructs dequantized control points and DCT coefficients while
	/// enforcing the same area guards upstream uses against pathological splines.
	pub fn dequantize(
		self: *const QuantizedSpline,
		allocator: std.mem.Allocator,
		starting_point: Point,
		quantization_adjustment: i32,
		y_to_x: f32,
		y_to_b: f32,
		image_size: u64,
		total_estimated_area_reached: *u64,
	) !Spline {
		const area_limit = @min(1024 * image_size + (@as(u64, 1) << 32), @as(u64, 1) << 42);

		var result = Spline{};
		result.control_points = try allocator.alloc(Point, self.control_points.len + 1);
		errdefer result.deinit(allocator);

		const px = @round(starting_point.x);
		const py = @round(starting_point.y);
		try validateSplinePointPos(px, py);
		var current_x: i32 = @intFromFloat(px);
		var current_y: i32 = @intFromFloat(py);
		result.control_points[0] = .{ .x = @floatFromInt(current_x), .y = @floatFromInt(current_y) };
		var current_delta_x: i32 = 0;
		var current_delta_y: i32 = 0;
		var manhattan_distance: u64 = 0;

		for (self.control_points, 0..) |point, i| {
			current_delta_x += @intCast(point.x);
			current_delta_y += @intCast(point.y);
			manhattan_distance += @abs(current_delta_x) + @abs(current_delta_y);
			if (manhattan_distance > area_limit) return error.GenericError;
			try validateSplinePointPos(current_delta_x, current_delta_y);
			current_x += current_delta_x;
			current_y += current_delta_y;
			try validateSplinePointPos(current_x, current_y);
			result.control_points[i + 1] = .{ .x = @floatFromInt(current_x), .y = @floatFromInt(current_y) };
		}

		const inv_quant = invAdjustedQuant(quantization_adjustment);
		for (0..3) |c| {
			for (0..32) |i| {
				const inv_dct_factor: f32 = if (i == 0) kSqrt0_5 else 1.0;
				result.color_dct[c][i] = @as(f32, @floatFromInt(self.color_dct[c][i])) * inv_dct_factor * kChannelWeight[c] * inv_quant;
			}
		}
		for (0..32) |i| {
			result.color_dct[0][i] += y_to_x * result.color_dct[1][i];
			result.color_dct[2][i] += y_to_b * result.color_dct[1][i];
		}

		var width_estimate: u64 = 0;
		var color: [3]u64 = .{ 0, 0, 0 };
		for (0..3) |c| {
			for (0..32) |i| {
				color[c] += @intFromFloat(@ceil(inv_quant * @abs(@as(f32, @floatFromInt(self.color_dct[c][i])))));
			}
		}
		color[0] += @as(u64, @intFromFloat(@ceil(@abs(y_to_x)))) * color[1];
		color[2] += @as(u64, @intFromFloat(@ceil(@abs(y_to_b)))) * color[1];
		const max_color = @max(color[1], @max(color[0], color[2]));
		const logcolor = @max(@as(u64, 1), @as(u64, bits.ceilLog2Nonzero(@as(u64, 1) + max_color)));
		const weight_limit = @ceil(@sqrt((@as(f32, @floatFromInt(area_limit)) / @as(f32, @floatFromInt(logcolor))) / @max(@as(f32, 1.0), @as(f32, @floatFromInt(manhattan_distance)))));

		for (0..32) |i| {
			const inv_dct_factor: f32 = if (i == 0) kSqrt0_5 else 1.0;
			result.sigma_dct[i] = @as(f32, @floatFromInt(self.sigma_dct[i])) * inv_dct_factor * kChannelWeight[3] * inv_quant;
			const weight_f = @ceil(inv_quant * @abs(@as(f32, @floatFromInt(self.sigma_dct[i]))));
			const weight = @as(u64, @intFromFloat(@min(weight_limit, @max(@as(f32, 1.0), weight_f))));
			width_estimate += weight * weight * logcolor;
		}

		total_estimated_area_reached.* += width_estimate * manhattan_distance;
		if (total_estimated_area_reached.* > area_limit) return error.GenericError;

		return result;
	}
};

pub const Splines = struct {
	quantization_adjustment: i32 = 0,
	splines: []QuantizedSpline = &.{},
	starting_points: []Point = &.{},
	segments: []SplineSegment = &.{},
	segment_indices: []usize = &.{},
	segment_y_start: []usize = &.{},
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) Splines {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Splines) void {
		for (self.splines) |*spline| spline.deinit(self.allocator);
		self.allocator.free(self.splines);
		self.allocator.free(self.starting_points);
		self.allocator.free(self.segments);
		self.allocator.free(self.segment_indices);
		self.allocator.free(self.segment_y_start);
		self.* = .{ .allocator = self.allocator };
	}

	pub fn clear(self: *Splines) void {
		self.deinit();
	}

	pub fn hasAny(self: *const Splines) bool {
		return self.splines.len != 0;
	}

	/// Takes ownership of the provided quantized spline arrays so higher layers
	/// can build validation/render cache state without copying large DCT payloads.
	pub fn assignOwned(
		self: *Splines,
		quantization_adjustment: i32,
		splines: []QuantizedSpline,
		starting_points: []Point,
	) void {
		self.quantization_adjustment = quantization_adjustment;
		self.splines = splines;
		self.starting_points = starting_points;
	}

	/// Builds the per-row spline segment cache used by the render stage by
	/// dequantizing curves, sampling them uniformly, and bucketing spans by y.
	pub fn initializeDrawCache(self: *Splines, image_xsize: usize, image_ysize: usize, color_correlation: ColorCorrelation) !void {
		self.allocator.free(self.segments);
		self.allocator.free(self.segment_indices);
		self.allocator.free(self.segment_y_start);
		self.segments = &.{};
		self.segment_indices = &.{};
		self.segment_y_start = &.{};

		var total_estimated_area_reached: u64 = 0;
		var segments: std.ArrayListUnmanaged(SplineSegment) = .empty;
		defer segments.deinit(self.allocator);
		var segments_by_y: std.ArrayListUnmanaged(SegmentByY) = .empty;
		defer segments_by_y.deinit(self.allocator);

		for (self.splines, self.starting_points, 0..) |*quantized, starting_point, i| {
			var spline = try quantized.dequantize(
				self.allocator,
				starting_point,
				self.quantization_adjustment,
				color_correlation.YtoXRatio(0),
				color_correlation.YtoBRatio(0),
				image_xsize * image_ysize,
				&total_estimated_area_reached,
			);
			defer spline.deinit(self.allocator);

			if (hasAdjacentDuplicatePoints(spline.control_points)) {
				_ = i;
				return error.GenericError;
			}

			const intermediate_points = try drawCentripetalCatmullRomSpline(self.allocator, spline.control_points);
			defer self.allocator.free(intermediate_points);
			const points_to_draw = try collectEquallySpacedPoints(self.allocator, intermediate_points);
			defer self.allocator.free(points_to_draw);

			if (points_to_draw.len < 2) continue;
			const arc_length = @as(f32, @floatFromInt(points_to_draw.len - 2)) * kDesiredRenderingDistance + points_to_draw[points_to_draw.len - 1].multiplier;
			if (arc_length <= 0.0) continue;
			try segmentsFromPoints(&spline, points_to_draw, arc_length, &segments, &segments_by_y, self.allocator);
		}

		std.mem.sort(SegmentByY, segments_by_y.items, {}, struct {
			fn lessThan(_: void, a: SegmentByY, b: SegmentByY) bool {
				return if (a.y == b.y) a.index < b.index else a.y < b.y;
			}
		}.lessThan);

		self.segments = try segments.toOwnedSlice(self.allocator);
		self.segment_indices = try self.allocator.alloc(usize, segments_by_y.items.len);
		self.segment_y_start = try self.allocator.alloc(usize, image_ysize + 1);
		@memset(self.segment_y_start, 0);

		for (segments_by_y.items, 0..) |entry, i_entry| {
			self.segment_indices[i_entry] = entry.index;
			if (entry.y < image_ysize) self.segment_y_start[entry.y + 1] += 1;
		}
		for (0..image_ysize) |y| {
			self.segment_y_start[y + 1] += self.segment_y_start[y];
		}
	}

	pub fn addToRow(self: *const Splines, row_x: []f32, row_y: []f32, row_b: []f32, y: usize, x0: usize, x1: usize) void {
		self.applyToRow(true, row_x, row_y, row_b, y, x0, x1);
	}

	pub fn subtractFromRow(self: *const Splines, row_x: []f32, row_y: []f32, row_b: []f32, y: usize, x0: usize, x1: usize) void {
		self.applyToRow(false, row_x, row_y, row_b, y, x0, x1);
	}

	fn applyToRow(self: *const Splines, add: bool, row_x: []f32, row_y: []f32, row_b: []f32, y: usize, x0: usize, x1: usize) void {
		if (self.segments.len == 0 or y + 1 >= self.segment_y_start.len) return;
		for (self.segment_y_start[y]..self.segment_y_start[y + 1]) |i| {
			drawSegment(self.segments[self.segment_indices[i]], add, row_x, row_y, row_b, y, x0, x1);
		}
	}
};

fn hasAdjacentDuplicatePoints(points: []const Point) bool {
	for (points[1..], points[0 .. points.len - 1]) |point, previous| {
		if (point.approxEq(previous, 1.0e-3)) return true;
	}
	return false;
}

fn toQuantizedInt(value: f32) i32 {
	const max = @as(f32, @floatFromInt(std.math.maxInt(i32) - 127));
	const min = -max;
	return @intFromFloat(@round(common.clamp1(value, min, max)));
}

const Vector = struct {
	x: f32,
	y: f32,

	fn add(a: Vector, b: Vector) Vector {
		return .{ .x = a.x + b.x, .y = a.y + b.y };
	}

	fn sub(a: Vector, b: Vector) Vector {
		return .{ .x = a.x - b.x, .y = a.y - b.y };
	}

	fn scale(k: f32, vec: Vector) Vector {
		return .{ .x = k * vec.x, .y = k * vec.y };
	}

	fn squaredNorm(self: Vector) f32 {
		return self.x * self.x + self.y * self.y;
	}
};

fn pointAddVector(point: Point, vec: Vector) Point {
	return .{ .x = point.x + vec.x, .y = point.y + vec.y };
}

fn pointSub(a: Point, b: Point) Vector {
	return .{ .x = a.x - b.x, .y = a.y - b.y };
}

/// Interpolates the spline's 32 DCT coefficients continuously so draw-cache
/// construction can sample color and sigma at arbitrary arc-length positions.
fn continuousIDCT(dct: Dct32, t: f32) f32 {
	var result: f32 = 0.0;
	for (dct, 0..) |coeff, i| {
		const multiplier = std.math.pi / 32.0 * @as(f32, @floatFromInt(i));
		result += kSqrt2 * coeff * @cos(multiplier * (t + 0.5));
	}
	return result;
}

/// Converts sparse control points into a denser centripetal Catmull-Rom polyline
/// so later sampling walks a smooth curve without cusps at sharp corners.
fn drawCentripetalCatmullRomSpline(allocator: std.mem.Allocator, points_in: []const Point) ![]Point {
	if (points_in.len == 0) return allocator.dupe(Point, &.{});
	if (points_in.len == 1) return allocator.dupe(Point, points_in);

	const kNumPoints: usize = 16;
	var result: std.ArrayListUnmanaged(Point) = .empty;
	errdefer result.deinit(allocator);
	try result.ensureTotalCapacity(allocator, (points_in.len - 1) * kNumPoints + 1);

	var points = try allocator.alloc(Point, points_in.len + 2);
	defer allocator.free(points);
	@memcpy(points[1 .. 1 + points_in.len], points_in);
	points[0] = pointAddVector(points_in[0], pointSub(points_in[0], points_in[1]));
	points[points.len - 1] = pointAddVector(points_in[points_in.len - 1], pointSub(points_in[points_in.len - 1], points_in[points_in.len - 2]));

	for (0..points.len - 3) |start| {
		const p = points[start .. start + 4];
		try result.append(allocator, p[1]);

		var d: [3]f32 = undefined;
		var t: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
		for (0..3) |k| {
			d[k] = @sqrt(std.math.pow(f32, p[k + 1].x - p[k].x, 2) + std.math.pow(f32, p[k + 1].y - p[k].y, 2));
			t[k + 1] = t[k] + d[k];
		}

		for (1..kNumPoints) |i| {
			const tt = d[0] + (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(kNumPoints))) * d[1];
			var a: [3]Point = undefined;
			for (0..3) |k| {
				a[k] = pointAddVector(p[k], Vector.scale((tt - t[k]) / d[k], pointSub(p[k + 1], p[k])));
			}
			var b: [2]Point = undefined;
			for (0..2) |k| {
				b[k] = pointAddVector(a[k], Vector.scale((tt - t[k]) / (d[k] + d[k + 1]), pointSub(a[k + 1], a[k])));
			}
			try result.append(allocator, pointAddVector(b[0], Vector.scale((tt - t[1]) / d[1], pointSub(b[1], b[0]))));
		}
	}

	try result.append(allocator, points[points.len - 2]);
	return result.toOwnedSlice(allocator);
}

/// Resamples the Catmull-Rom polyline at fixed pixel spacing so later rendering
/// uses bounded work per visible arc length instead of per-control-point density.
fn collectEquallySpacedPoints(allocator: std.mem.Allocator, points: []const Point) ![]PointToDraw {
	if (points.len == 0) return allocator.dupe(PointToDraw, &.{});

	var result: std.ArrayListUnmanaged(PointToDraw) = .empty;
	errdefer result.deinit(allocator);
	try result.append(allocator, .{ .point = points[0], .multiplier = kDesiredRenderingDistance });

	var current = points[0];
	var next_index: usize = 0;
	while (next_index < points.len) {
		var previous = current;
		var arc_from_previous: f32 = 0.0;
		while (true) {
			if (next_index == points.len) {
				try result.append(allocator, .{ .point = previous, .multiplier = arc_from_previous });
				return result.toOwnedSlice(allocator);
			}
			const next = points[next_index];
			const delta = pointSub(next, previous);
			const arc_to_next = @sqrt(delta.squaredNorm());
			if (arc_from_previous + arc_to_next >= kDesiredRenderingDistance) {
				current = pointAddVector(previous, Vector.scale((kDesiredRenderingDistance - arc_from_previous) / arc_to_next, delta));
				try result.append(allocator, .{ .point = current, .multiplier = kDesiredRenderingDistance });
				break;
			}
			arc_from_previous += arc_to_next;
			previous = next;
			next_index += 1;
		}
	}

	return result.toOwnedSlice(allocator);
}

fn computeSegments(
	center: Point,
	intensity: f32,
	color: [3]f32,
	sigma: f32,
	segments: *std.ArrayListUnmanaged(SplineSegment),
	segments_by_y: *std.ArrayListUnmanaged(SegmentByY),
	allocator: std.mem.Allocator,
) !void {
	if (!std.math.isFinite(sigma) or sigma == 0.0 or !std.math.isFinite(1.0 / sigma) or !std.math.isFinite(intensity)) return;

	var max_color: f32 = 0.01;
	for (0..3) |c| max_color = @max(max_color, @abs(color[c] * intensity));
	const maximum_distance = @sqrt(-2.0 * sigma * sigma * (@log(@as(f32, 0.1)) * kDistanceExp - @log(max_color)));

	const segment = SplineSegment{
		.center_x = center.x,
		.center_y = center.y,
		.maximum_distance = maximum_distance,
		.inv_sigma = 1.0 / sigma,
		.sigma_over_4_times_intensity = 0.25 * sigma * intensity,
		.color = color,
	};

	const y0: i64 = @intFromFloat(@round(center.y - maximum_distance));
	const y1: i64 = @as(i64, @intFromFloat(@round(center.y + maximum_distance))) + 1;
	var y = @max(y0, 0);
	while (y < y1) : (y += 1) {
		try segments_by_y.append(allocator, .{ .y = @intCast(y), .index = segments.items.len });
	}
	try segments.append(allocator, segment);
}

fn segmentsFromPoints(
	spline: *const Spline,
	points_to_draw: []const PointToDraw,
	arc_length: f32,
	segments: *std.ArrayListUnmanaged(SplineSegment),
	segments_by_y: *std.ArrayListUnmanaged(SegmentByY),
	allocator: std.mem.Allocator,
) !void {
	const inv_arc_length = 1.0 / arc_length;
	for (points_to_draw, 0..) |point_to_draw, k| {
		const progress_along_arc = @min(1.0, (@as(f32, @floatFromInt(k)) * kDesiredRenderingDistance) * inv_arc_length);
		var color: [3]f32 = undefined;
		for (0..3) |c| {
			color[c] = continuousIDCT(spline.color_dct[c], 31.0 * progress_along_arc);
		}
		const sigma = continuousIDCT(spline.sigma_dct, 31.0 * progress_along_arc);
		try computeSegments(point_to_draw.point, point_to_draw.multiplier, color, sigma, segments, segments_by_y, allocator);
	}
}

fn drawSegment(segment: SplineSegment, add: bool, row_x: []f32, row_y: []f32, row_b: []f32, y: usize, x0: usize, x1: usize) void {
	const start: i64 = @intFromFloat(@round(segment.center_x - segment.maximum_distance));
	const end: i64 = @intFromFloat(@round(segment.center_x + segment.maximum_distance));
	if (end < @as(i64, @intCast(x0)) or start >= @as(i64, @intCast(x1))) return;

	const span_x0 = @max(@as(i64, @intCast(x0)), start);
	const span_x1 = @min(@as(i64, @intCast(x1)), end + 1);
	var x_abs = span_x0;
	while (x_abs < span_x1) : (x_abs += 1) {
		const dx = @as(f32, @floatFromInt(x_abs)) - segment.center_x;
		const dy = @as(f32, @floatFromInt(y)) - segment.center_y;
		const distance = @sqrt(dx * dx + dy * dy);
		const factor = erfApprox((distance * 0.5 + 0.353553391) * segment.inv_sigma) -
			erfApprox((distance * 0.5 - 0.353553391) * segment.inv_sigma);
		const local_intensity = segment.sigma_over_4_times_intensity * factor * factor;
		const out_x = @as(usize, @intCast(x_abs - @as(i64, @intCast(x0))));
		const sign: f32 = if (add) 1.0 else -1.0;
		row_x[out_x] += sign * segment.color[0] * local_intensity;
		row_y[out_x] += sign * segment.color[1] * local_intensity;
		row_b[out_x] += sign * segment.color[2] * local_intensity;
	}
}

/// Uses a compact Abramowitz-Stegun approximation for the Gaussian error
/// function, matching the spirit of upstream's fast spline hot-path math.
fn erfApprox(x: f32) f32 {
	const sign: f32 = if (x < 0.0) -1.0 else 1.0;
	const ax = @abs(x);
	const t = 1.0 / (1.0 + 0.3275911 * ax);
	const poly = (((((1.061405429 * t) - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592;
	const y = 1.0 - poly * t * @exp(-(ax * ax));
	return sign * y;
}

const testing = std.testing;

test "QuantizedSpline create/dequantize preserves integer control points" {
	var spline = Spline{
		.control_points = try testing.allocator.dupe(Point, &.{
			.{ .x = 9, .y = 54 },
			.{ .x = 118, .y = 159 },
			.{ .x = 97, .y = 3 },
			.{ .x = 10, .y = 40 },
		}),
		.color_dct = .{ zero_dct32, zero_dct32, zero_dct32 },
		.sigma_dct = zero_dct32,
	};
	defer spline.deinit(testing.allocator);

	var quantized = try QuantizedSpline.create(testing.allocator, &spline, 0, 0.0, 1.0);
	defer quantized.deinit(testing.allocator);

	var total_estimated_area_reached: u64 = 0;
	var restored = try quantized.dequantize(
		testing.allocator,
		spline.control_points[0],
		0,
		0.0,
		1.0,
		320 * 320,
		&total_estimated_area_reached,
	);
	defer restored.deinit(testing.allocator);

	try testing.expectEqual(spline.control_points.len, restored.control_points.len);
	for (spline.control_points, restored.control_points) |expected, actual| {
		try testing.expect(actual.approxEq(expected, 1.0e-3));
	}
}

test "Splines initializeDrawCache rejects duplicate successive control points" {
	var spline = Spline{
		.control_points = try testing.allocator.dupe(Point, &.{
			.{ .x = 9, .y = 54 },
			.{ .x = 118, .y = 159 },
			.{ .x = 97, .y = 3 },
			.{ .x = 97, .y = 3 },
			.{ .x = 10, .y = 40 },
			.{ .x = 150, .y = 25 },
			.{ .x = 120, .y = 300 },
		}),
		.color_dct = .{ zero_dct32, zero_dct32, zero_dct32 },
		.sigma_dct = zero_dct32,
	};
	defer spline.deinit(testing.allocator);

	const quantized = try QuantizedSpline.create(testing.allocator, &spline, 0, 0.0, 1.0);
	var owned_splines = try testing.allocator.alloc(QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try testing.allocator.dupe(Point, &.{spline.control_points[0]});

	var splines = Splines.init(testing.allocator);
	defer splines.deinit();
	splines.assignOwned(0, owned_splines, starting_points);

	try testing.expectError(error.GenericError, splines.initializeDrawCache(320, 320, .{}));
}

test "Splines initializeDrawCache builds drawable segments for simple spline" {
	var color = zero_dct32;
	color[0] = 0.49497476;
	var sigma = zero_dct32;
	sigma[0] = 2.357;
	var spline = Spline{
		.control_points = try testing.allocator.dupe(Point, &.{
			.{ .x = 10, .y = 10 },
			.{ .x = 20, .y = 10 },
			.{ .x = 30, .y = 10 },
		}),
		.color_dct = .{ zero_dct32, zero_dct32, color },
		.sigma_dct = sigma,
	};
	defer spline.deinit(testing.allocator);

	const quantized = try QuantizedSpline.create(testing.allocator, &spline, 0, 0.0, 1.0);
	var owned_splines = try testing.allocator.alloc(QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try testing.allocator.dupe(Point, &.{spline.control_points[0]});

	var splines = Splines.init(testing.allocator);
	defer splines.deinit();
	splines.assignOwned(0, owned_splines, starting_points);

	try splines.initializeDrawCache(64, 64, .{});
	try testing.expect(splines.segments.len > 0);
	try testing.expect(splines.segment_indices.len > 0);
	try testing.expectEqual(@as(usize, 65), splines.segment_y_start.len);

	var row_x = [_]f32{0} ** 64;
	var row_y = [_]f32{0} ** 64;
	var row_b = [_]f32{0} ** 64;
	splines.addToRow(&row_x, &row_y, &row_b, 10, 0, row_b.len);

	var touched = false;
	for (row_b) |value| {
		if (@abs(value) > 0.0) {
			touched = true;
			break;
		}
	}
	try testing.expect(touched);
}
