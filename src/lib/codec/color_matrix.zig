const std = @import("std");
const color = @import("color_encoding.zig");
const Error = @import("../base/status.zig").JxlError;
pub const Matrix = [3][3]f32;
pub const Result = struct { matrix: Matrix, luminances: [3]f32 };
const srgb_luminances = [3]f32{ 0.2126, 0.7152, 0.0722 };
const bradford = Matrix{ .{ 0.8951, 0.2664, -0.1614 }, .{ -0.7502, 1.7135, 0.0367 }, .{ 0.0389, -0.0685, 1.0296 } };
const inverse_bradford = Matrix{ .{ 0.9869929, -0.1470543, 0.1599627 }, .{ 0.4323053, 0.5183603, 0.0492912 }, .{ -0.0085287, 0.0400428, 0.9684867 } };
fn mul(a: Matrix, b: Matrix) Matrix {
	var result: Matrix = undefined;
	for (0..3) |r| for (0..3) |c| {
		result[r][c] = @floatCast(@as(f64, a[r][0]) * b[0][c] + @as(f64, a[r][1]) * b[1][c] + @as(f64, a[r][2]) * b[2][c]);
	};
	return result;
}
fn vec(a: Matrix, b: [3]f32) [3]f32 {
	var result: [3]f32 = undefined;
	for (0..3) |r| result[r] = @floatCast(@as(f64, a[r][0]) * b[0] + @as(f64, a[r][1]) * b[1] + @as(f64, a[r][2]) * b[2]);
	return result;
}
fn inverse(a: Matrix) Error!Matrix {
	var cofactors: [3][3]f64 = undefined;
	for (0..3) |r| for (0..3) |c| {
		const r1 = (c + 1) % 3;
		const r2 = (c + 2) % 3;
		const c1 = (r + 1) % 3;
		const c2 = (r + 2) % 3;
		cofactors[r][c] = @as(f64, a[r1][c1]) * a[r2][c2] - @as(f64, a[r1][c2]) * a[r2][c1];
	};
	const determinant = @as(f64, a[0][0]) * cofactors[0][0] + @as(f64, a[0][1]) * cofactors[1][0] + @as(f64, a[0][2]) * cofactors[2][0];
	if (!std.math.isFinite(determinant) or @abs(determinant) < 1e-10) return error.GenericError;
	var result: Matrix = undefined;
	for (0..3) |r| for (0..3) |c| {
		result[r][c] = @floatCast(cofactors[r][c] / determinant);
		if (!std.math.isFinite(result[r][c])) return error.GenericError;
	};
	return result;
}
fn whiteVector(white: [2]f64) Error![3]f32 {
	const x: f32 = @floatCast(white[0]);
	const y: f32 = @floatCast(white[1]);
	if (!(x >= 0 and x <= 1 and y > 0 and y <= 1)) return error.GenericError;
	const result = [3]f32{ x / y, 1, (1 - x - y) / y };
	for (result) |v| if (!std.math.isFinite(v)) return error.GenericError;
	return result;
}
fn xyz(encoding: color.ColorEncoding) Error!Matrix {
	const xy = encoding.primariesXY();
	var p: Matrix = undefined;
	for (0..3) |c| {
		p[0][c] = @floatCast(xy[c][0]);
		p[1][c] = @floatCast(xy[c][1]);
		p[2][c] = 1 - p[0][c] - p[1][c];
	}
	const scales = vec(try inverse(p), try whiteVector(encoding.whitePointXY()));
	return mul(p, .{ .{ scales[0], 0, 0 }, .{ 0, scales[1], 0 }, .{ 0, 0, scales[2] } });
}
fn adapt(white: [2]f64) Error!Matrix {
	const source = vec(bradford, try whiteVector(white));
	const target = vec(bradford, .{ 0.96422, 1, 0.82521 });
	var diagonal: Matrix = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
	for (0..3) |c| {
		if (source[c] == 0) return error.GenericError;
		diagonal[c][c] = target[c] / source[c];
		if (!std.math.isFinite(diagonal[c][c])) return error.GenericError;
	}
	return mul(inverse_bradford, mul(diagonal, bradford));
}
/// RGB metadata must describe a usable profile even when pixels are skipped.
/// This mirrors the matrix checks performed by upstream's structured ICC writer.
pub fn validateRgb(encoding: color.ColorEncoding) error{InvalidColorEncoding}!void {
	if (encoding.want_icc or encoding.color_space != .rgb) return;
	if (encoding.primaries == .srgb and encoding.white_point == .d65) return;
	const native = xyz(encoding) catch return error.InvalidColorEncoding;
	const adaptation = adapt(encoding.whitePointXY()) catch return error.InvalidColorEncoding;
	const profile = mul(adaptation, native);
	// Upstream also rejects structured profiles whose ICC matrix entries cannot
	// be represented by its signed 15.16 writer, including near-singular primaries.
	const icc_s15_limit: f32 = 32767.995;
	for ([_]Matrix{ adaptation, profile }) |matrix| for (matrix) |row| for (row) |value| {
		if (!(value >= -icc_s15_limit and value <= icc_s15_limit)) return error.InvalidColorEncoding;
	};
}
/// Build the output conversion once per frame. Intermediate matrix products
/// follow upstream's double accumulation and float storage at this boundary.
pub fn convert(opsin: Matrix, encoding: color.ColorEncoding) Error!Result {
	if (encoding.isGray()) return .{ .matrix = mul(.{ srgb_luminances, srgb_luminances, srgb_luminances }, opsin), .luminances = srgb_luminances };
	if (encoding.primaries == .srgb and encoding.white_point == .d65) return .{ .matrix = opsin, .luminances = srgb_luminances };
	const srgb = color.ColorEncoding{};
	const source = mul(try adapt(srgb.whitePointXY()), try xyz(srgb));
	const dest_xyz = try xyz(encoding);
	const destination = try inverse(mul(try adapt(encoding.whitePointXY()), dest_xyz));
	return .{ .matrix = mul(mul(destination, source), opsin), .luminances = dest_xyz[1] };
}
