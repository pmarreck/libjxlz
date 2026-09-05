const std = @import("std");
const image_metadata = @import("image_metadata.zig");

/// Output color boundary shared by frame compositing and the C adapter.
pub fn toOutputRgb(x: f32, y: f32, b: f32, params: *const OpsinParams, metadata: *const image_metadata.ImageMetadata) @import("../base/status.zig").JxlError![3]f32 {
	var rgb = xybToLinearRgb(x, y, b, params);
	const tf = metadata.color_encoding.tf;
	if (tf.have_gamma) return @import("../base/unsupported.zig").unsupported(.color_encoding);
	switch (tf.transfer_function) {
		.linear => {},
		.srgb => for (&rgb) |*value| {
			const magnitude = @abs(value.*);
			const encoded = if (magnitude <= 0.0031308) magnitude * 12.92 else 1.055 * std.math.pow(f32, magnitude, 1.0 / 2.4) - 0.055;
			value.* = if (value.* < 0) -encoded else encoded;
		},
		else => return @import("../base/unsupported.zig").unsupported(.color_encoding),
	}
	return rgb;
}

const default_intensity_target: f32 = 255.0;
const default_opsin_bias: f32 = 0.0037930732552754493;
const default_neg_opsin_biases = [3]f32{
	-default_opsin_bias,
	-default_opsin_bias,
	-default_opsin_bias,
};
const default_inverse_matrix = [3][3]f32{
	.{ 11.031566901960783, -9.866943921568629, -0.16462299647058826 },
	.{ -3.254147380392157, 4.418770392156863, -0.16462299647058826 },
	.{ -3.6588512862745097, 2.7129230470588235, 1.9459282392156863 },
};

pub const OpsinParams = struct {
	inverse_matrix: [3][3]f32,
	neg_opsin_biases: [3]f32,
	neg_opsin_biases_cbrt: [3]f32,
};

fn signedCubeRoot(value: f32) f32 {
	return std.math.cbrt(value);
}

fn zeroOpsinMatrix(matrix: *const image_metadata.OpsinInverseMatrix) bool {
	for (matrix.inverse_matrix) |row| {
		for (row) |value| {
			if (value != 0.0) return false;
		}
	}
	for (matrix.opsin_biases) |value| {
		if (value != 0.0) return false;
	}
	return true;
}

/// Builds the upstream XYB inverse opsin parameters, scaling the inverse matrix
/// by tone-mapping intensity so scalar decode matches libjxl's OpsinParams.
pub fn opsinParams(metadata: *const image_metadata.ImageMetadata, transform_data: *const image_metadata.CustomTransformData) OpsinParams {
	const intensity_target = if (metadata.tone_mapping.intensity_target > 0.0)
		metadata.tone_mapping.intensity_target
	else
		default_intensity_target;
	const scale = default_intensity_target / intensity_target;
	const src = &transform_data.opsin_inverse_matrix;
	const use_default = !src.custom and zeroOpsinMatrix(src);

	var params = OpsinParams{
		.inverse_matrix = undefined,
		.neg_opsin_biases = if (use_default) default_neg_opsin_biases else src.opsin_biases,
		.neg_opsin_biases_cbrt = undefined,
	};

	for (0..3) |row| {
		for (0..3) |col| {
			const value = if (use_default) default_inverse_matrix[row][col] else src.inverse_matrix[row][col];
			params.inverse_matrix[row][col] = value * scale;
		}
		params.neg_opsin_biases_cbrt[row] = signedCubeRoot(params.neg_opsin_biases[row]);
	}

	return params;
}

/// Converts one XYB pixel into normalized linear RGB using libjxl's scalar
/// inverse-opsin formula; later C API layers handle sample packing and alpha.
pub fn xybToLinearRgb(x: f32, y: f32, b: f32, params: *const OpsinParams) [3]f32 {
	const gamma_r = y + x - params.neg_opsin_biases_cbrt[0];
	const gamma_g = y - x - params.neg_opsin_biases_cbrt[1];
	const gamma_b = b - params.neg_opsin_biases_cbrt[2];

	const mixed_r = @mulAdd(f32, gamma_r * gamma_r, gamma_r, params.neg_opsin_biases[0]);
	const mixed_g = @mulAdd(f32, gamma_g * gamma_g, gamma_g, params.neg_opsin_biases[1]);
	const mixed_b = @mulAdd(f32, gamma_b * gamma_b, gamma_b, params.neg_opsin_biases[2]);

	return .{
		@mulAdd(f32, params.inverse_matrix[0][2], mixed_b, @mulAdd(f32, params.inverse_matrix[0][1], mixed_g, params.inverse_matrix[0][0] * mixed_r)),
		@mulAdd(f32, params.inverse_matrix[1][2], mixed_b, @mulAdd(f32, params.inverse_matrix[1][1], mixed_g, params.inverse_matrix[1][0] * mixed_r)),
		@mulAdd(f32, params.inverse_matrix[2][2], mixed_b, @mulAdd(f32, params.inverse_matrix[2][1], mixed_g, params.inverse_matrix[2][0] * mixed_r)),
	};
}

const testing = std.testing;

test "xybToLinearRgb maps default XYB black to linear RGB black" {
	var metadata = image_metadata.ImageMetadata{};
	metadata.xyb_encoded = true;
	var transform_data = image_metadata.CustomTransformData{};
	const params = opsinParams(&metadata, &transform_data);

	const rgb = xybToLinearRgb(0.0, 0.0, 0.0, &params);
	try testing.expectApproxEqAbs(@as(f32, 0.0), rgb[0], 1.0e-6);
	try testing.expectApproxEqAbs(@as(f32, 0.0), rgb[1], 1.0e-6);
	try testing.expectApproxEqAbs(@as(f32, 0.0), rgb[2], 1.0e-6);
}

test "xybToLinearRgb keeps neutral default opsin white near normalized RGB white" {
	var metadata = image_metadata.ImageMetadata{};
	metadata.xyb_encoded = true;
	var transform_data = image_metadata.CustomTransformData{};
	const params = opsinParams(&metadata, &transform_data);

	const gamma = signedCubeRoot(1.0 + default_opsin_bias);
	const neutral = gamma + params.neg_opsin_biases_cbrt[0];
	const rgb = xybToLinearRgb(0.0, neutral, neutral, &params);
	try testing.expectApproxEqAbs(@as(f32, 1.0), rgb[0], 1.0e-5);
	try testing.expectApproxEqAbs(@as(f32, 1.0), rgb[1], 1.0e-5);
	try testing.expectApproxEqAbs(@as(f32, 1.0), rgb[2], 1.0e-5);
}
