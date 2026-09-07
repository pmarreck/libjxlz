const std = @import("std");
const api = @import("../capi_root.zig");

test "alpha output options match upstream across association depth and channel count" {
	try checkAlphaOutput(@import("alpha_output_fixture.zig"), false, false);
}

test "alpha output options match upstream grayscale and expanded grayscale" {
	try checkAlphaOutput(@import("alpha_gray_fixture.zig"), true, false);
}

test "alpha output options compose with RGB orientation" {
	try checkAlphaOutput(@import("alpha_oriented_fixture.zig"), false, false);
}

test "alpha output options compose with grayscale orientation" {
	try checkAlphaOutput(@import("alpha_gray_oriented_fixture.zig"), true, false);
}

test "alpha output options apply to actual RGB previews" {
	try checkAlphaOutput(@import("alpha_preview_fixture.zig"), false, true);
}

test "alpha output options apply to actual grayscale previews" {
	try checkAlphaOutput(@import("alpha_gray_preview_fixture.zig"), true, true);
}

test "alpha output options preserve floating input and tiny alpha" {
	try checkAlphaOutput(@import("alpha_float_input_fixture.zig"), false, false);
}

test "alpha output options preserve floating grayscale previews" {
	try checkAlphaOutput(@import("alpha_float_gray_preview_fixture.zig"), true, true);
}

test "alpha output options survive rewind and reset restores the default" {
	const fixture = @import("alpha_output_fixture.zig");
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	for (0..3) |attempt| {
		if (attempt == 1) api.JxlDecoderRewind(decoder);
		if (attempt == 2) api.JxlDecoderReset(decoder);
		if (attempt == 0) try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetUnpremultiplyAlpha(decoder, 1));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x1000));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &fixture.bytes_8_1, fixture.bytes_8_1.len));
		api.JxlDecoderCloseInput(decoder);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderSetUnpremultiplyAlpha(decoder, 0));
		const format: api.JxlPixelFormat = .{ .num_channels = 4, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
		var pixels: [24]u8 = undefined;
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &pixels, pixels.len));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
		try std.testing.expectEqualSlices(u8, if (attempt == 2) &fixture.pixels_8_1_0_8_4 else &fixture.pixels_8_1_1_8_4, &pixels);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
	}
}

fn checkOrientedAlphaAllocation(allocator: std.mem.Allocator, frame: *@import("../lib/codec/dec_frame.zig").FrameDecoder, metadata: *@import("../lib/codec/image_metadata.zig").CodecMetadata) !void {
	var pixels: [24]u8 = undefined;
	try @import("output_buffer.zig").writeConfiguredFrameDecoderOutput(allocator, frame, metadata, 6, true, .{ .num_channels = 4, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 }, &pixels, pixels.len);
	try std.testing.expectEqualSlices(u8, &@import("alpha_oriented_fixture.zig").pixels_8_1_1_8_4, &pixels);
}

test "alpha output options release oriented floating temporary allocations" {
	const FrameDecoder = @import("../lib/codec/dec_frame.zig").FrameDecoder;
	const CodecMetadata = @import("../lib/codec/image_metadata.zig").CodecMetadata;
	const Image = @import("../lib/modular/modular_image.zig").Image;
	var metadata: CodecMetadata = .{};
	metadata.m.xyb_encoded = false;
	metadata.m.bit_depth.bits_per_sample = 8;
	metadata.m.color_encoding.color_space = .rgb;
	metadata.m.num_extra_channels = 1;
	metadata.m.extra_channel_info[0].type = .alpha;
	metadata.m.extra_channel_info[0].bit_depth.bits_per_sample = 8;
	metadata.m.extra_channel_info[0].alpha_associated = true;
	var frame = FrameDecoder.init(std.testing.allocator, &metadata);
	defer frame.deinit();
	frame.frame_header.color_transform = .none;
	frame.modular_decoder.full_image.deinit();
	frame.modular_decoder.full_image = try Image.create(std.testing.allocator, 3, 2, 8, 4);
	const input = @import("alpha_output_fixture.zig").pixels_8_1_0_8_4;
	for (0..2) |y| for (0..3) |x| {
		for (0..4) |channel| frame.modular_decoder.full_image.channels.items[channel].row(y)[x] = input[(y * 3 + x) * 4 + channel];
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOrientedAlphaAllocation, .{ &frame, &metadata });
}

fn checkAlphaOutput(comptime fixture: type, comptime gray: bool, comptime preview: bool) !void {
	@setEvalBranchQuota(500_000);
	inline for (if (@hasDecl(fixture, "bytes_32_0")) .{32} else .{ 8, 16 }) |input_bits| {
		inline for (0..2) |associated| {
			inline for (0..2) |unpremultiply| {
				inline for (.{ 8, 16, 32, 17 }) |output_bits| {
					inline for (if (gray) .{ 1, 2, 3, 4 } else .{ 3, 4 }) |channels| {
						const input = @field(fixture, std.fmt.comptimePrint("bytes_{d}_{d}", .{ input_bits, associated }));
						const expected = @field(fixture, std.fmt.comptimePrint("pixels_{d}_{d}_{d}_{d}_{d}", .{ input_bits, associated, unpremultiply, output_bits, channels }));
						const info_expected = @field(fixture, std.fmt.comptimePrint("info_{d}_{d}_{d}", .{ input_bits, associated, unpremultiply }));
						const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
						defer api.JxlDecoderDestroy(decoder);
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetUnpremultiplyAlpha(decoder, unpremultiply));
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x40 | 0x1000 | (if (preview) @as(c_int, 0x200) else 0)));
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
						api.JxlDecoderCloseInput(decoder);
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO, api.JxlDecoderProcessInput(decoder));
						var info: api.JxlBasicInfo = undefined;
						var extra: api.JxlExtraChannelInfo = undefined;
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetBasicInfo(decoder, &info));
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetExtraChannelInfo(decoder, 0, &extra));
						try std.testing.expectEqualSlices(i32, &info_expected, &.{ info.alpha_premultiplied, extra.alpha_premultiplied });
						const format: api.JxlPixelFormat = .{ .num_channels = channels, .data_type = if (output_bits == 8) .JXL_TYPE_UINT8 else if (output_bits == 16) .JXL_TYPE_UINT16 else if (output_bits == 32) .JXL_TYPE_FLOAT else .JXL_TYPE_FLOAT16, .endianness = .JXL_BIG_ENDIAN, .@"align" = 0 };
						var output: [expected.len]u8 = undefined;
						if (preview) {
							try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
							try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &output, output.len));
							try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_PREVIEW_IMAGE, api.JxlDecoderProcessInput(decoder));
							try std.testing.expectEqualSlices(u8, &expected, &output);
							@memset(&output, 0xa5);
						}
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &output, output.len));
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
						try std.testing.expectEqualSlices(u8, &expected, &output);
						try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
					}
				}
			}
		}
	}
}
