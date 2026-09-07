const std = @import("std");
const api = @import("../capi_root.zig");
const encoder = @import("../lib/codec/enc_api.zig");

test "encoded preview contains a real frame before unchanged main pixels" {
	const input = [_]u8{0,10,20,30,40,50,60,70,80,90,100,110};
	const bytes = try encoder.encodeSimplePackedU8(std.testing.allocator, .{
		.width = 2, .height = 2, .num_color_channels = 3,
		.color_row_stride = 6, .color_pixels = &input,
		.preview_width = 1, .preview_height = 1,
	}, null);
	defer std.testing.allocator.free(bytes);
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200 | 0x1000));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, bytes.ptr, bytes.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
	var preview: [3]u8 = undefined;
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &preview, preview.len));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_PREVIEW_IMAGE, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqualSlices(u8, &.{0,10,20}, &preview);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
	var main: [12]u8 = undefined;
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &main, main.len));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
	try std.testing.expectEqualSlices(u8, &input, &main);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
}
