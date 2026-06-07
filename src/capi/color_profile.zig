const std = @import("std");

const byte_order = @import("../lib/base/byte_order.zig");
const color_encoding_mod = @import("../lib/codec/color_encoding.zig");

pub const JxlColorSpace = enum(c_int) {
	JXL_COLOR_SPACE_RGB = 0,
	JXL_COLOR_SPACE_GRAY = 1,
	JXL_COLOR_SPACE_XYB = 2,
	JXL_COLOR_SPACE_UNKNOWN = 3,
};

pub const JxlWhitePoint = enum(c_int) {
	JXL_WHITE_POINT_D65 = 1,
	JXL_WHITE_POINT_CUSTOM = 2,
	JXL_WHITE_POINT_E = 10,
	JXL_WHITE_POINT_DCI = 11,
};

pub const JxlPrimaries = enum(c_int) {
	JXL_PRIMARIES_SRGB = 1,
	JXL_PRIMARIES_CUSTOM = 2,
	JXL_PRIMARIES_2100 = 9,
	JXL_PRIMARIES_P3 = 11,
};

pub const JxlTransferFunction = enum(c_int) {
	JXL_TRANSFER_FUNCTION_709 = 1,
	JXL_TRANSFER_FUNCTION_UNKNOWN = 2,
	JXL_TRANSFER_FUNCTION_LINEAR = 8,
	JXL_TRANSFER_FUNCTION_SRGB = 13,
	JXL_TRANSFER_FUNCTION_PQ = 16,
	JXL_TRANSFER_FUNCTION_DCI = 17,
	JXL_TRANSFER_FUNCTION_HLG = 18,
	JXL_TRANSFER_FUNCTION_GAMMA = 65535,
};

pub const JxlRenderingIntent = enum(c_int) {
	JXL_RENDERING_INTENT_PERCEPTUAL = 0,
	JXL_RENDERING_INTENT_RELATIVE = 1,
	JXL_RENDERING_INTENT_SATURATION = 2,
	JXL_RENDERING_INTENT_ABSOLUTE = 3,
};

pub const JxlColorEncoding = extern struct {
	color_space: JxlColorSpace,
	white_point: JxlWhitePoint,
	white_point_xy: [2]f64,
	primaries: JxlPrimaries,
	primaries_red_xy: [2]f64,
	primaries_green_xy: [2]f64,
	primaries_blue_xy: [2]f64,
	transfer_function: JxlTransferFunction,
	gamma: f64,
	rendering_intent: JxlRenderingIntent,
};

pub const IccEmbeddingShape = struct {
	main_color_channels: u32,
	requires_black_extra: bool = false,
};

pub fn defaultWhitePointXY() [2]f64 {
	return .{ 0.3127, 0.3290 };
}

pub fn defaultPrimariesRedXY() [2]f64 {
	return .{ 0.639998686, 0.330010138 };
}

pub fn defaultPrimariesGreenXY() [2]f64 {
	return .{ 0.300003784, 0.600003357 };
}

pub fn defaultPrimariesBlueXY() [2]f64 {
	return .{ 0.150002046, 0.059997204 };
}

pub fn customXYToF64Pair(xy: color_encoding_mod.Customxy) [2]f64 {
	return .{
		@as(f64, @floatFromInt(xy.x)) / 1000000.0,
		@as(f64, @floatFromInt(xy.y)) / 1000000.0,
	};
}

pub fn customXYFromF64Pair(pair: [2]f64) !color_encoding_mod.Customxy {
	for (pair) |coord| {
		if (!std.math.isFinite(coord)) return error.Unsupported;
	}

	const x = @as(i32, @intFromFloat(@round(pair[0] * 1000000.0)));
	const y = @as(i32, @intFromFloat(@round(pair[1] * 1000000.0)));
	if (x < -2097152 or x > 2097151 or y < -2097152 or y > 2097151) {
		return error.Unsupported;
	}
	return .{ .x = x, .y = y };
}

/// Builds libjxl-compatible default structured color metadata for sRGB and
/// linear-sRGB C API initializers, including the default chromaticity payloads.
pub fn defaultJxlColorEncoding(is_gray: bool, linear: bool) JxlColorEncoding {
	return .{
		.color_space = if (is_gray) .JXL_COLOR_SPACE_GRAY else .JXL_COLOR_SPACE_RGB,
		.white_point = .JXL_WHITE_POINT_D65,
		.white_point_xy = defaultWhitePointXY(),
		.primaries = .JXL_PRIMARIES_SRGB,
		.primaries_red_xy = defaultPrimariesRedXY(),
		.primaries_green_xy = defaultPrimariesGreenXY(),
		.primaries_blue_xy = defaultPrimariesBlueXY(),
		.transfer_function = if (linear) .JXL_TRANSFER_FUNCTION_LINEAR else .JXL_TRANSFER_FUNCTION_SRGB,
		.gamma = 1.0,
		.rendering_intent = .JXL_RENDERING_INTENT_RELATIVE,
	};
}

/// Classifies the narrow embedded-ICC shapes we can faithfully map onto the
/// current JXL surface by inspecting ICC header signatures instead of pulling in a CMS.
pub fn classifyIccEmbeddingShape(icc: []const u8) !IccEmbeddingShape {
	if (icc.len < 128 or icc.len > std.math.maxInt(u32)) return error.InvalidArgs;
	const declared_size = byte_order.loadBE32(@ptrCast(icc[0..4]));
	if (declared_size != icc.len) return error.InvalidArgs;
	if (!std.mem.eql(u8, icc[36..40], "acsp")) return error.InvalidArgs;
	const color_space = icc[16..20];
	if (
		std.mem.eql(u8, color_space, "GRAY") or
		std.mem.eql(u8, color_space, "MCH1") or
		std.mem.eql(u8, color_space, "1CLR")
	) {
		return .{ .main_color_channels = 1 };
	}
	if (
		std.mem.eql(u8, color_space, "RGB ") or
		std.mem.eql(u8, color_space, "XYZ ") or
		std.mem.eql(u8, color_space, "Lab ") or
		std.mem.eql(u8, color_space, "Luv ") or
		std.mem.eql(u8, color_space, "YCbr") or
		std.mem.eql(u8, color_space, "Yxy ") or
		std.mem.eql(u8, color_space, "HSV ") or
		std.mem.eql(u8, color_space, "HLS ") or
		std.mem.eql(u8, color_space, "CMY ") or
		std.mem.eql(u8, color_space, "MCH3") or
		std.mem.eql(u8, color_space, "3CLR")
	) {
		return .{ .main_color_channels = 3 };
	}
	if (std.mem.eql(u8, color_space, "CMYK")) {
		return .{
			.main_color_channels = 3,
			.requires_black_extra = true,
		};
	}
	return error.Unsupported;
}

/// Builds the narrow internal color-encoding shell for embedded ICC streams:
/// channel count selects gray/RGB while exact colorimetry stays in ICC bytes.
pub fn internalIccColorEncoding(num_color_channels: u32) color_encoding_mod.ColorEncoding {
	return .{
		.want_icc = true,
		.color_space = if (num_color_channels == 1) .gray else .rgb,
	};
}

pub fn mapRenderingIntent(intent: JxlRenderingIntent) ?color_encoding_mod.RenderingIntent {
	return switch (intent) {
		.JXL_RENDERING_INTENT_PERCEPTUAL => .perceptual,
		.JXL_RENDERING_INTENT_RELATIVE => .relative,
		.JXL_RENDERING_INTENT_SATURATION => .saturation,
		.JXL_RENDERING_INTENT_ABSOLUTE => .absolute,
	};
}

pub fn fromInternalColorSpace(color_space: color_encoding_mod.ColorSpace) JxlColorSpace {
	return switch (color_space) {
		.rgb => .JXL_COLOR_SPACE_RGB,
		.gray => .JXL_COLOR_SPACE_GRAY,
		.xyb => .JXL_COLOR_SPACE_XYB,
		.unknown => .JXL_COLOR_SPACE_UNKNOWN,
	};
}

pub fn fromInternalWhitePoint(white_point: color_encoding_mod.WhitePoint) JxlWhitePoint {
	return switch (white_point) {
		.d65 => .JXL_WHITE_POINT_D65,
		.custom => .JXL_WHITE_POINT_CUSTOM,
		.e => .JXL_WHITE_POINT_E,
		.dci => .JXL_WHITE_POINT_DCI,
	};
}

pub fn fromInternalPrimaries(primaries: color_encoding_mod.Primaries) JxlPrimaries {
	return switch (primaries) {
		.srgb => .JXL_PRIMARIES_SRGB,
		.custom => .JXL_PRIMARIES_CUSTOM,
		.bt2100 => .JXL_PRIMARIES_2100,
		.p3 => .JXL_PRIMARIES_P3,
	};
}

pub fn fromInternalTransferFunction(tf: *const color_encoding_mod.CustomTransferFunction, gamma_out: *f64) JxlTransferFunction {
	if (tf.have_gamma) {
		gamma_out.* = @as(f64, @floatFromInt(tf.gamma)) / 10000000.0;
		return .JXL_TRANSFER_FUNCTION_GAMMA;
	}
	gamma_out.* = 0.0;
	return switch (tf.transfer_function) {
		.bt709 => .JXL_TRANSFER_FUNCTION_709,
		.unknown => .JXL_TRANSFER_FUNCTION_UNKNOWN,
		.linear => .JXL_TRANSFER_FUNCTION_LINEAR,
		.srgb => .JXL_TRANSFER_FUNCTION_SRGB,
		.pq => .JXL_TRANSFER_FUNCTION_PQ,
		.dci => .JXL_TRANSFER_FUNCTION_DCI,
		.hlg => .JXL_TRANSFER_FUNCTION_HLG,
	};
}

pub fn fromInternalRenderingIntent(intent: color_encoding_mod.RenderingIntent) JxlRenderingIntent {
	return switch (intent) {
		.perceptual => .JXL_RENDERING_INTENT_PERCEPTUAL,
		.relative => .JXL_RENDERING_INTENT_RELATIVE,
		.saturation => .JXL_RENDERING_INTENT_SATURATION,
		.absolute => .JXL_RENDERING_INTENT_ABSOLUTE,
	};
}

/// Maps the parsed structured JPEG XL color profile back onto the public C API
/// struct so decoder clients can inspect nominal color space without ICC.
pub fn populateColorEncoding(dst: *JxlColorEncoding, color: *const color_encoding_mod.ColorEncoding) void {
	dst.* = std.mem.zeroes(JxlColorEncoding);
	dst.color_space = fromInternalColorSpace(color.color_space);
	dst.white_point = fromInternalWhitePoint(color.white_point);
	dst.primaries = fromInternalPrimaries(color.primaries);
	dst.white_point_xy = if (color.white_point == .custom) customXYToF64Pair(color.white) else defaultWhitePointXY();
	dst.primaries_red_xy = if (color.primaries == .custom) customXYToF64Pair(color.red) else defaultPrimariesRedXY();
	dst.primaries_green_xy = if (color.primaries == .custom) customXYToF64Pair(color.green) else defaultPrimariesGreenXY();
	dst.primaries_blue_xy = if (color.primaries == .custom) customXYToF64Pair(color.blue) else defaultPrimariesBlueXY();
	dst.transfer_function = fromInternalTransferFunction(&color.tf, &dst.gamma);
	dst.rendering_intent = fromInternalRenderingIntent(color.rendering_intent);
}

/// Converts the public C color-encoding struct into the narrow non-ICC Zig
/// color model used by the current one-shot modular encoder.
pub fn toInternalColorEncoding(
	color: *const JxlColorEncoding,
	num_channels: u32,
) !color_encoding_mod.ColorEncoding {
	var internal = color_encoding_mod.ColorEncoding{};
	internal.want_icc = false;
	internal.rendering_intent = mapRenderingIntent(color.rendering_intent) orelse return error.Unsupported;

	switch (color.color_space) {
		.JXL_COLOR_SPACE_GRAY => {
			if (num_channels != 1) return error.Unsupported;
			internal.color_space = .gray;
			internal.primaries = .srgb;
			if (color.primaries != .JXL_PRIMARIES_SRGB) return error.Unsupported;
		},
		.JXL_COLOR_SPACE_RGB => {
			if (num_channels != 3) return error.Unsupported;
			internal.color_space = .rgb;
			internal.primaries = switch (color.primaries) {
				.JXL_PRIMARIES_SRGB => .srgb,
				.JXL_PRIMARIES_CUSTOM => .custom,
				.JXL_PRIMARIES_2100 => .bt2100,
				.JXL_PRIMARIES_P3 => .p3,
			};
			if (internal.primaries == .custom) {
				internal.red = try customXYFromF64Pair(color.primaries_red_xy);
				internal.green = try customXYFromF64Pair(color.primaries_green_xy);
				internal.blue = try customXYFromF64Pair(color.primaries_blue_xy);
			}
		},
		else => return error.Unsupported,
	}

	internal.white_point = switch (color.white_point) {
		.JXL_WHITE_POINT_D65 => .d65,
		.JXL_WHITE_POINT_CUSTOM => .custom,
		.JXL_WHITE_POINT_E => .e,
		.JXL_WHITE_POINT_DCI => .dci,
	};
	if (internal.white_point == .custom) {
		internal.white = try customXYFromF64Pair(color.white_point_xy);
	}

	switch (color.transfer_function) {
		.JXL_TRANSFER_FUNCTION_GAMMA => {
			if (!(color.gamma > 0.0 and color.gamma <= 1.0)) return error.Unsupported;
			internal.tf = .{
				.have_gamma = true,
				.gamma = @intFromFloat(@round(color.gamma * 10000000.0)),
			};
		},
		.JXL_TRANSFER_FUNCTION_709 => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .bt709,
		},
		.JXL_TRANSFER_FUNCTION_SRGB => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .srgb,
		},
		.JXL_TRANSFER_FUNCTION_LINEAR => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .linear,
		},
		.JXL_TRANSFER_FUNCTION_PQ => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .pq,
		},
		.JXL_TRANSFER_FUNCTION_DCI => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .dci,
		},
		.JXL_TRANSFER_FUNCTION_HLG => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .hlg,
		},
		else => return error.Unsupported,
	}

	return internal;
}

test "toInternalColorEncoding accepts p3 hlg rgb" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_P3;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_HLG;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.Primaries.p3, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.hlg, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts bt2100 pq rgb" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_2100;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_PQ;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.Primaries.bt2100, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.pq, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts p3 dci white point" {
	var color = defaultJxlColorEncoding(false, false);
	color.white_point = .JXL_WHITE_POINT_DCI;
	color.primaries = .JXL_PRIMARIES_P3;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_DCI;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.WhitePoint.dci, internal.white_point);
	try std.testing.expectEqual(color_encoding_mod.Primaries.p3, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.dci, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts explicit gamma" {
	var color = defaultJxlColorEncoding(false, false);
	color.transfer_function = .JXL_TRANSFER_FUNCTION_GAMMA;
	color.gamma = 1.0 / 2.2;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.WhitePoint.d65, internal.white_point);
	try std.testing.expectEqual(color_encoding_mod.Primaries.srgb, internal.primaries);
	try std.testing.expect(internal.tf.have_gamma);
	try std.testing.expectEqual(@as(u32, 4545455), internal.tf.gamma);
}

test "toInternalColorEncoding accepts custom white point" {
	var color = defaultJxlColorEncoding(false, false);
	color.white_point = .JXL_WHITE_POINT_CUSTOM;
	color.white_point_xy = .{ 0.321, 0.345 };

	const internal = try toInternalColorEncoding(&color, 3);

	try std.testing.expectEqual(color_encoding_mod.WhitePoint.custom, internal.white_point);
	try std.testing.expectEqual(@as(i32, 321000), internal.white.x);
	try std.testing.expectEqual(@as(i32, 345000), internal.white.y);
}

test "toInternalColorEncoding accepts custom primaries" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_CUSTOM;
	color.primaries_red_xy = .{ 0.68, 0.32 };
	color.primaries_green_xy = .{ 0.265, 0.69 };
	color.primaries_blue_xy = .{ 0.15, 0.045 };

	const internal = try toInternalColorEncoding(&color, 3);

	try std.testing.expectEqual(color_encoding_mod.Primaries.custom, internal.primaries);
	try std.testing.expectEqual(@as(i32, 680000), internal.red.x);
	try std.testing.expectEqual(@as(i32, 320000), internal.red.y);
	try std.testing.expectEqual(@as(i32, 265000), internal.green.x);
	try std.testing.expectEqual(@as(i32, 690000), internal.green.y);
	try std.testing.expectEqual(@as(i32, 150000), internal.blue.x);
	try std.testing.expectEqual(@as(i32, 45000), internal.blue.y);
}

fn makeSyntheticIccHeader(data_color_space: [4]u8) [128]u8 {
	var icc = std.mem.zeroes([128]u8);
	icc[0] = 0x00;
	icc[1] = 0x00;
	icc[2] = 0x00;
	icc[3] = 0x80;
	icc[12] = 'm';
	icc[13] = 'n';
	icc[14] = 't';
	icc[15] = 'r';
	@memcpy(icc[16..20], &data_color_space);
	icc[20] = 'X';
	icc[21] = 'Y';
	icc[22] = 'Z';
	icc[23] = ' ';
	icc[36] = 'a';
	icc[37] = 'c';
	icc[38] = 's';
	icc[39] = 'p';
	return icc;
}

test "classifyIccEmbeddingShape maps ICC header component signatures" {
	try std.testing.expectEqual(IccEmbeddingShape{ .main_color_channels = 1 }, try classifyIccEmbeddingShape(&makeSyntheticIccHeader(.{ 'G', 'R', 'A', 'Y' })));
	try std.testing.expectEqual(IccEmbeddingShape{ .main_color_channels = 3 }, try classifyIccEmbeddingShape(&makeSyntheticIccHeader(.{ 'L', 'a', 'b', ' ' })));
	try std.testing.expectEqual(IccEmbeddingShape{ .main_color_channels = 3, .requires_black_extra = true }, try classifyIccEmbeddingShape(&makeSyntheticIccHeader(.{ 'C', 'M', 'Y', 'K' })));
	try std.testing.expectError(error.Unsupported, classifyIccEmbeddingShape(&makeSyntheticIccHeader(.{ '4', 'C', 'L', 'R' })));
}
