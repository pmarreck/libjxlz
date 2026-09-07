const std = @import("std");
const api = @import("../capi_root.zig");

// The retained coverage probe combines a 1x1 red preview with a 2x2 RGB main
// image. Upstream libjxl 0.12 decodes the main pixels to 0,10,...,110.
const preview_image = [_]u8{
	0xff, 0x0a, 0x08, 0x00, 0x02, 0x08, 0x01, 0x00, 0x00, 0x62, 0x02, 0x08,
	0x02, 0x01, 0x00, 0x4c, 0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00,
	0xc2, 0x8d, 0x4c, 0xc2, 0x1d, 0x94, 0x9f, 0x0d, 0x00, 0x0e, 0xf0, 0x3e,
	0x08, 0x02, 0x01, 0x00, 0x68, 0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02,
	0x00, 0xc2, 0x8d, 0x78, 0x1b, 0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f,
	0x94, 0xc8, 0xff, 0xa0, 0xa9, 0x14, 0xbc, 0x07,
};

// Upstream also accepts a 2x2 preview with a 1x1 main image.
const larger_preview_image = [_]u8{
	0xff, 0x0a, 0x00, 0x00, 0x00, 0x08, 0x11, 0x80, 0x00, 0x62, 0x02, 0x08,
	0x02, 0x01, 0x00, 0x68, 0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00,
	0xc2, 0x8d, 0x78, 0x1b, 0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f, 0x94,
	0xc8, 0xff, 0xa0, 0xa9, 0x14, 0xbc, 0x07, 0x08, 0x02, 0x01, 0x00, 0x4c,
	0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00, 0xc2, 0x8d, 0x4c, 0xc2,
	0x1d, 0x94, 0x9f, 0x0d, 0x00, 0x0e, 0xf0, 0x3e,
};

test "actual preview pixel limit applies when the preview exceeds main dimensions" {
	var result: api.JxlValidationResult = undefined;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(&larger_preview_image, larger_preview_image.len, null, &result));
	var options = api.default_validation_options;
	options.max_pixels = 1;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_INDETERMINATE, api.JxlValidate(&larger_preview_image, larger_preview_image.len, &options, &result));
	try std.testing.expectEqual(api.JxlValidationFindingCode.JXL_VALIDATION_FINDING_RESOURCE_LIMIT, result.code);
	try std.testing.expectEqual(@as(u32, 0), result.frames_validated);
}

test "actual preview precedes the main image during strict validation" {
	var result: api.JxlValidationResult = undefined;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(&preview_image, preview_image.len, null, &result));
}

test "actual preview subscription requests a preview buffer before main output" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200 | 0x1000));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
}

test "actual preview buffer requires a preview event subscription" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x40));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO, api.JxlDecoderProcessInput(decoder));
	const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
	var pixels: [3]u8 = undefined;
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &pixels, pixels.len));
}

test "actual preview buffer queries reject unsupported RGB channel layouts" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	const channels = [_]u32{ 0, 1, 2, 3, 4, 5, std.math.maxInt(u32) };
	const expected = [_]api.JxlDecoderStatus{ .JXL_DEC_ERROR, .JXL_DEC_ERROR, .JXL_DEC_ERROR, .JXL_DEC_SUCCESS, .JXL_DEC_SUCCESS, .JXL_DEC_ERROR, .JXL_DEC_ERROR };
	for (channels, expected) |count, status| {
		const format: api.JxlPixelFormat = .{ .num_channels = count, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
		var size: usize = 0;
		try std.testing.expectEqual(status, api.JxlDecoderPreviewOutBufferSize(decoder, &format, &size));
		try std.testing.expectEqual(status, api.JxlDecoderImageOutBufferSize(decoder, &format, &size));
	}
}

test "actual preview and main output omit trailing row padding" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 8 };
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200 | 0x1000));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	var needed: usize = 0;
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderPreviewOutBufferSize(decoder, &format, &needed));
	try std.testing.expectEqual(@as(usize, 3), needed);
	var preview: [4]u8 = @splat(0xa5);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &preview, 3));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_PREVIEW_IMAGE, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0xa5 }, &preview);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderImageOutBufferSize(decoder, &format, &needed));
	try std.testing.expectEqual(@as(usize, 14), needed);
	var pixels: [16]u8 = @splat(0xa5);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &pixels, 14));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 40, 50, 0xa5, 0xa5, 60, 70, 80, 90, 100, 110, 0xa5, 0xa5 }, &pixels);
}

test "actual preview output has its own buffer and replays after rewind and reset" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
	var needed: usize = 123;
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_MORE_INPUT, api.JxlDecoderPreviewOutBufferSize(decoder, &format, &needed));
	try std.testing.expectEqual(@as(usize, 123), needed);
	var preview_pixels: [4]u8 = undefined;
	var main_pixels: [12]u8 = undefined;
	for (0..3) |pass| {
		if (pass == 1) api.JxlDecoderRewind(decoder);
		if (pass == 2) api.JxlDecoderReset(decoder);
		if (pass != 1) try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200 | 0x1000));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
		api.JxlDecoderCloseInput(decoder);
		@memset(&preview_pixels, 0xa5);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderPreviewOutBufferSize(decoder, &format, &needed));
		try std.testing.expectEqual(@as(usize, 3), needed);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &preview_pixels, 2));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, null, 3));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &preview_pixels, preview_pixels.len));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_PREVIEW_IMAGE, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0xa5 }, &preview_pixels);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &main_pixels, main_pixels.len));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110 }, &main_pixels);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
	}
}

test "actual preview is skipped for ordinary main image output" {
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x1000));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &preview_image, preview_image.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	var pixels: [12]u8 = undefined;
	const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &pixels, pixels.len));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110 }, &pixels);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
}
