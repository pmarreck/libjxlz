const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const bits = @import("../base/bits.zig");
const common = @import("../base/common.zig");
const pack_signed = @import("../base/pack_signed.zig");
const dec_ans = @import("../entropy/dec_ans.zig");

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
const kDistanceExp: f32 = 5.0;

const SplineEntropyContext = enum(usize) {
	quantization_adjustment = 0,
	starting_position = 1,
	num_splines = 2,
	num_control_points = 3,
	control_points = 4,
	dct = 5,
};

const kNumSplineContexts: usize = 6;
const kDeltaLimit: i32 = 1 << 30;

fn readHybrid(reader: anytype, context: SplineEntropyContext) !usize {
	return try reader.read(@intFromEnum(context));
}

fn unpackSignedHybrid(raw: usize) !i32 {
	if (raw > std.math.maxInt(u32)) return error.GenericError;
	return pack_signed.unpackSigned(@intCast(raw));
}

const AnsHybridReader = struct {
	decoder: *dec_ans.ANSSymbolReader,
	br: *BitReader,
	context_map: []const u8,

	fn read(self: *AnsHybridReader, context: usize) !usize {
		if (context >= self.context_map.len) return error.GenericError;
		return self.decoder.readHybridUint(context, self.br, self.context_map);
	}
};

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

	/// Decodes one upstream quantized spline from a hybrid-uint token source,
	/// preserving entropy-context order while keeping bit IO outside the model.
	pub fn decodeFromHybridReader(
		allocator: std.mem.Allocator,
		reader: anytype,
		max_control_points: usize,
		total_num_control_points: *usize,
	) !QuantizedSpline {
		const num_control_points = try readHybrid(reader, .num_control_points);
		if (num_control_points > max_control_points) return error.GenericError;
		total_num_control_points.* = common.safeAdd(total_num_control_points.*, num_control_points) orelse return error.GenericError;
		if (total_num_control_points.* > max_control_points) return error.GenericError;

		var result = QuantizedSpline{};
		result.control_points = try allocator.alloc(PointDelta, num_control_points);
		errdefer result.deinit(allocator);

		for (result.control_points) |*point| {
			const dx = try unpackSignedHybrid(try readHybrid(reader, .control_points));
			const dy = try unpackSignedHybrid(try readHybrid(reader, .control_points));
			if (dx >= kDeltaLimit or dx <= -kDeltaLimit or dy >= kDeltaLimit or dy <= -kDeltaLimit) {
				return error.GenericError;
			}
			point.* = .{ .x = dx, .y = dy };
		}

		for (0..3) |c| {
			try decodeDct(reader, &result.color_dct[c]);
		}
		try decodeDct(reader, &result.sigma_dct);

		return result;
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

	fn decodeDct(reader: anytype, out: *[32]i32) !void {
		for (out) |*coeff| {
			const value = try unpackSignedHybrid(try readHybrid(reader, .dct));
			if (value == std.math.minInt(i32)) return error.GenericError;
			coeff.* = value;
		}
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

	/// Decodes the frame-global spline payload from an abstract hybrid-uint
	/// stream, mirroring libjxl's context order while deferring rendering.
	pub fn decodeFromHybridReader(self: *Splines, reader: anytype, num_pixels: usize) !void {
		self.clear();

		const num_splines_raw = try readHybrid(reader, .num_splines);
		const max_control_points = @min(kMaxNumControlPoints, num_pixels / kMaxNumControlPointsPerPixelRatio);
		if (num_splines_raw > max_control_points or num_splines_raw +| 1 > max_control_points) return error.GenericError;
		const num_splines = num_splines_raw + 1;

		const starting_points = try self.allocator.alloc(Point, num_splines);
		errdefer self.allocator.free(starting_points);
		try decodeAllStartingPoints(reader, starting_points);

		const quantization_adjustment = try unpackSignedHybrid(try readHybrid(reader, .quantization_adjustment));

		var decoded_splines = try self.allocator.alloc(QuantizedSpline, num_splines);
		@memset(decoded_splines, QuantizedSpline{});
		var decoded_count: usize = 0;
		errdefer {
			for (decoded_splines[0..decoded_count]) |*spline| spline.deinit(self.allocator);
			self.allocator.free(decoded_splines);
		}

		var total_control_points: usize = num_splines;
		for (decoded_splines) |*spline| {
			spline.* = try QuantizedSpline.decodeFromHybridReader(
				self.allocator,
				reader,
				max_control_points,
				&total_control_points,
			);
			decoded_count += 1;
		}

		self.assignOwned(quantization_adjustment, decoded_splines, starting_points);
	}

	/// Decodes the real ANS-coded spline bitstream section into decoder-owned
	/// state; final image output remains gated until the float render seam lands.
	pub fn decode(self: *Splines, br: *BitReader, num_pixels: usize) !void {
		var code = dec_ans.ANSCode.init(self.allocator);
		defer code.deinit();

		const context_map = try dec_ans.decodeHistograms(self.allocator, br, kNumSplineContexts, &code);
		defer self.allocator.free(context_map);

		var ans_reader = try dec_ans.ANSSymbolReader.create(&code, br, 0, self.allocator);
		defer ans_reader.deinit();
		var reader = AnsHybridReader{
			.decoder = &ans_reader,
			.br = br,
			.context_map = context_map,
		};

		try self.decodeFromHybridReader(&reader, num_pixels);
		if (!ans_reader.checkANSFinalState()) return error.GenericError;
		if (!self.hasAny()) return error.GenericError;
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

/// Approximates cosine with upstream libjxl's FastCosf polynomial/range
/// reduction so spline DCT interpolation follows oracle-visible rounding.
fn fastCos(x: f32) f32 {
	const pi2: f32 = @bitCast(@as(u32, 0x40c90fdb));
	const pi2_inv: f32 = @bitCast(@as(u32, 0x3e22f983));
	const pi: f32 = @bitCast(@as(u32, 0x40490fdb));
	const pi_half: f32 = @bitCast(@as(u32, 0x3fc90fdb));
	const periods = @floor(x * pi2_inv);
	const xmodpi2 = @mulAdd(f32, -periods, pi2, x);
	const x_pi = @min(xmodpi2, pi2 - xmodpi2);
	const above_pihalf = x_pi >= pi_half;
	const x_pihalf = if (above_pihalf) pi - x_pi else x_pi;
	const xs = x_pihalf * 0.25;
	const x2 = xs * xs;
	const x4 = x2 * x2;
	const cosx_prescaling = @mulAdd(f32, x4, 0.06960438, @mulAdd(f32, x2, -0.84087373, 1.68179268));
	const cosx_scale1 = @mulAdd(f32, cosx_prescaling, cosx_prescaling, -1.414213562);
	const cosx_scale2 = @mulAdd(f32, cosx_scale1, cosx_scale1, -1.0);
	return if (above_pihalf) -cosx_scale2 else cosx_scale2;
}

/// Interpolates the spline's 32 DCT coefficients continuously so draw-cache
/// construction can sample color and sigma at arbitrary arc-length positions.
fn continuousIDCT(dct: Dct32, t: f32) f32 {
	var lanes = [_]f32{0.0} ** 8;
	for (dct, 0..) |coeff, i| {
		const multiplier: f32 = @floatCast(
			std.math.pi / 32.0 * @as(f64, @floatFromInt(i)),
		);
		const local = coeff * fastCos(multiplier * (t + 0.5));
		const lane = i % lanes.len;
		lanes[lane] = @mulAdd(f32, kSqrt2, local, lanes[lane]);
	}
	const sum_04 = lanes[0] + lanes[4];
	const sum_15 = lanes[1] + lanes[5];
	const sum_26 = lanes[2] + lanes[6];
	const sum_37 = lanes[3] + lanes[7];
	return (sum_04 + sum_37) + (sum_15 + sum_26);
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
			const dx = p[k + 1].x - p[k].x;
			const dy = p[k + 1].y - p[k].y;
			d[k] = @sqrt(std.math.hypot(dx, dy));
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
	const maximum_distance = maximumDistance(sigma, max_color);

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

/// Computes the spline cutoff radius exactly as libjxl v0.12.0's ComputeSegments
/// does, entirely in single precision. v0.11.x wrote `std::log(0.1)` with a double
/// literal, which promoted the whole term to double and yielded a one-ULP-larger
/// radius; v0.12.0 uses `-2.0f` and `std::log(0.1f)`, keeping every operation f32.
fn maximumDistance(sigma: f32, max_color: f32) f32 {
	const sigma_term: f32 = -2.0 * sigma * sigma;
	const log_term: f32 = @log(@as(f32, 0.1)) * kDistanceExp - @log(max_color);
	return @sqrt(sigma_term * log_term);
}

/// Applies the spline Gaussian's squared integration factor using the same
/// operation boundary as libjxl's SIMD render stage.
fn localIntensity(sigma_over_4_times_intensity: f32, factor: f32) f32 {
	return sigma_over_4_times_intensity * (factor * factor);
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
		const distance = @sqrt(@mulAdd(f32, dx, dx, dy * dy));
		const factor = erfApprox(@mulAdd(f32, distance, 0.5, 0.353553391) * segment.inv_sigma) -
			erfApprox(@mulAdd(f32, distance, 0.5, -0.353553391) * segment.inv_sigma);
		const local_intensity = localIntensity(segment.sigma_over_4_times_intensity, factor);
		const out_x = @as(usize, @intCast(x_abs - @as(i64, @intCast(x0))));
		const sign: f32 = if (add) 1.0 else -1.0;
		row_x[out_x] = @mulAdd(f32, sign * segment.color[0], local_intensity, row_x[out_x]);
		row_y[out_x] = @mulAdd(f32, sign * segment.color[1], local_intensity, row_y[out_x]);
		row_b[out_x] = @mulAdd(f32, sign * segment.color[2], local_intensity, row_b[out_x]);
	}
}

fn decodeAllStartingPoints(reader: anytype, points: []Point) !void {
	var last_x: i64 = 0;
	var last_y: i64 = 0;
	for (points, 0..) |*point, i| {
		const dx_raw = try readHybrid(reader, .starting_position);
		const dy_raw = try readHybrid(reader, .starting_position);
		const x: i64 = if (i == 0)
			blk: {
				try validateSplinePointPos(dx_raw, dy_raw);
				break :blk @intCast(dx_raw);
			}
		else
			last_x + try unpackSignedHybrid(dx_raw);
		const y: i64 = if (i == 0)
			@intCast(dy_raw)
		else
			last_y + try unpackSignedHybrid(dy_raw);
		try validateSplinePointPos(x, y);
		point.* = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
		last_x = x;
		last_y = y;
	}
}

/// Uses upstream libjxl's FastErff denominator polynomial so spline Gaussian
/// integration follows the same approximation family as the SIMD render path.
fn erfApprox(x: f32) f32 {
	const sign: f32 = if (x <= 0.0) -1.0 else 1.0;
	const ax = @abs(x);
	const denom1 = @mulAdd(f32, ax, 7.77394369e-02, 2.05260015e-04);
	const denom2 = @mulAdd(f32, denom1, ax, 2.32120216e-01);
	const denom3 = @mulAdd(f32, denom2, ax, 2.77820801e-01);
	const denom4 = @mulAdd(f32, denom3, ax, 1.0);
	const denom5 = denom4 * denom4;
	const inv_denom5 = 1.0 / denom5;
	return sign * @mulAdd(f32, -inv_denom5, inv_denom5, 1.0);
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

test "drawCentripetalCatmullRomSpline uses square-root chord lengths" {
	const points = [_]Point{
		.{ .x = 0.0, .y = 0.0 },
		.{ .x = 100.0, .y = 0.0 },
		.{ .x = 100.0, .y = 4.0 },
		.{ .x = 120.0, .y = 4.0 },
	};
	const smoothed = try drawCentripetalCatmullRomSpline(testing.allocator, &points);
	defer testing.allocator.free(smoothed);

	try testing.expectEqual(@as(usize, 49), smoothed.len);
	try testing.expectEqual(@as(u32, 0x4271aaaa), @as(u32, @bitCast(smoothed[8].x)));
	try testing.expectEqual(@as(u32, 0xc0055555), @as(u32, @bitCast(smoothed[8].y)));
	try testing.expectEqual(@as(u32, 0x42d88b8a), @as(u32, @bitCast(smoothed[40].x)));
	try testing.expectEqual(@as(u32, 0x4098b8ab), @as(u32, @bitCast(smoothed[40].y)));
}

test "erfApprox uses upstream FastErff constants" {
	try testing.expectEqual(@as(u32, 0x3f054a92), @as(u32, @bitCast(erfApprox(0.5))));
	try testing.expectEqual(@as(u32, 0xbf57bb53), @as(u32, @bitCast(erfApprox(-1.0))));
	try testing.expectEqual(@as(u32, 0x3f7ead49), @as(u32, @bitCast(erfApprox(2.0))));
}

test "fastCos uses upstream FastCosf constants" {
	try testing.expectApproxEqAbs(@as(f32, 0.8775844), fastCos(0.5), 2.0e-7);
	try testing.expectApproxEqAbs(@as(f32, 0.07073936), fastCos(1.5), 2.0e-7);
	try testing.expectApproxEqAbs(@as(f32, -0.4161461), fastCos(2.0), 2.0e-7);
}

test "continuous IDCT preserves pinned AVX2 lane reduction" {
	var isolated = zero_dct32;
	isolated[0] = 1.0;
	try testing.expectEqual(@as(u32, 0x3fb504eb), @as(u32, @bitCast(continuousIDCT(isolated, 12.345))));
	isolated = zero_dct32;
	isolated[1] = 1.0;
	try testing.expectEqual(@as(u32, 0x3edcb4e8), @as(u32, @bitCast(continuousIDCT(isolated, 12.345))));
	isolated = zero_dct32;
	isolated[5] = 1.0;
	try testing.expectEqual(@as(u32, 0x3fb4f99e), @as(u32, @bitCast(continuousIDCT(isolated, 12.345))));
	isolated = zero_dct32;
	isolated[17] = 1.0;
	try testing.expectEqual(@as(u32, 0xbf9a04cd), @as(u32, @bitCast(continuousIDCT(isolated, 12.345))));
	isolated = zero_dct32;
	isolated[31] = 1.0;
	try testing.expectEqual(@as(u32, 0x3e7f474d), @as(u32, @bitCast(continuousIDCT(isolated, 12.345))));

	var dct: Dct32 = undefined;
	for (&dct, 0..) |*coefficient, i| {
		coefficient.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 7)) - 3)) * 0.013;
	}
	const interpolated = continuousIDCT(dct, 12.345);
	try testing.expectEqual(@as(u32, 0x3c8e1060), @as(u32, @bitCast(interpolated)));
}

test "spline maximum distance uses upstream v0.12.0 all-float arithmetic" {
	// libjxl 0.12.0 changed this cutoff from `std::log(0.1)` (double literal, which
	// promoted the whole term to double) to `std::log(0.1f)` with `-2.0f`, making it
	// entirely single-precision. Independently computed from the C reference:
	// the 0.11.x mixed-f64 path yields 0x3b47afb8, the 0.12.0 all-float path 0x3b47afb9.
	const radius = maximumDistance(0.00100300903, 0.00100908172);
	try testing.expectEqual(@as(u32, 0x3b47afb9), @as(u32, @bitCast(radius)));
}

test "spline local intensity squares the integration factor before scaling" {
	const intensity = localIntensity(0.117839336, 0.00000499999987);
	try testing.expectEqual(@as(u32, 0x2c4f4e1e), @as(u32, @bitCast(intensity)));
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

const FakeHybridValue = struct {
	context: usize,
	value: usize,
};

const FakeHybridReader = struct {
	values: []const FakeHybridValue,
	index: usize = 0,

	fn read(self: *FakeHybridReader, context: usize) !usize {
		if (self.index >= self.values.len) return error.EndOfStream;
		const entry = self.values[self.index];
		self.index += 1;
		try testing.expectEqual(entry.context, context);
		return entry.value;
	}
};

test "QuantizedSpline decodeFromHybridReader reads control deltas and DCT payload" {
	var values = [_]FakeHybridValue{.{ .context = 3, .value = 2 }} ++
		[_]FakeHybridValue{
			.{ .context = 4, .value = pack_signed.packSigned(5) },
			.{ .context = 4, .value = pack_signed.packSigned(-2) },
			.{ .context = 4, .value = pack_signed.packSigned(0) },
			.{ .context = 4, .value = pack_signed.packSigned(7) },
			.{ .context = 5, .value = pack_signed.packSigned(11) },
		} ++ [_]FakeHybridValue{.{ .context = 5, .value = 0 }} ** 127;
	var reader = FakeHybridReader{ .values = &values };
	var total_control_points: usize = 0;

	var quantized = try QuantizedSpline.decodeFromHybridReader(
		testing.allocator,
		&reader,
		kMaxNumControlPoints,
		&total_control_points,
	);
	defer quantized.deinit(testing.allocator);

	try testing.expectEqual(@as(usize, values.len), reader.index);
	try testing.expectEqual(@as(usize, 2), total_control_points);
	try testing.expectEqual(@as(i64, 5), quantized.control_points[0].x);
	try testing.expectEqual(@as(i64, -2), quantized.control_points[0].y);
	try testing.expectEqual(@as(i64, 0), quantized.control_points[1].x);
	try testing.expectEqual(@as(i64, 7), quantized.control_points[1].y);
	try testing.expectEqual(@as(i32, 11), quantized.color_dct[0][0]);
	try testing.expectEqual(@as(i32, 0), quantized.sigma_dct[31]);
}

test "Splines decodeFromHybridReader populates upstream-shaped spline payload" {
	var values = [_]FakeHybridValue{
		.{ .context = 2, .value = 0 },
		.{ .context = 1, .value = 10 },
		.{ .context = 1, .value = 20 },
		.{ .context = 0, .value = pack_signed.packSigned(-3) },
		.{ .context = 3, .value = 2 },
		.{ .context = 4, .value = pack_signed.packSigned(5) },
		.{ .context = 4, .value = pack_signed.packSigned(0) },
		.{ .context = 4, .value = pack_signed.packSigned(0) },
		.{ .context = 4, .value = pack_signed.packSigned(5) },
	} ++ [_]FakeHybridValue{.{ .context = 5, .value = 0 }} ** 128;
	var reader = FakeHybridReader{ .values = &values };

	var decoded = Splines.init(testing.allocator);
	defer decoded.deinit();
	try decoded.decodeFromHybridReader(&reader, 64 * 64);

	try testing.expectEqual(@as(usize, values.len), reader.index);
	try testing.expect(decoded.hasAny());
	try testing.expectEqual(@as(i32, -3), decoded.quantization_adjustment);
	try testing.expectEqual(@as(usize, 1), decoded.splines.len);
	try testing.expect(decoded.starting_points[0].approxEq(.{ .x = 10, .y = 20 }, 1.0e-3));
	try testing.expectEqual(@as(usize, 2), decoded.splines[0].control_points.len);
}

test "Splines decodeFromHybridReader rejects more splines than image permits" {
	var values = [_]FakeHybridValue{
		.{ .context = 2, .value = 8 },
	};
	var reader = FakeHybridReader{ .values = &values };

	var decoded = Splines.init(testing.allocator);
	defer decoded.deinit();
	try testing.expectError(error.GenericError, decoded.decodeFromHybridReader(&reader, 4));
}
