const std = @import("std");
const api = @import("../capi_root.zig");
const fixture = @import("orientation_crop_fixture.zig");

const Case = struct {
	input: []const u8,
	keep: c_int,
	headers: [2][5]i32,
	pixels: [2][]const u8,
};
const cases = blk: {
	@setEvalBranchQuota(100_000);
	var result: [32]Case = undefined;
	var index: usize = 0;
	for (1..9) |orientation| {
		for (0..2) |negative| {
			for (0..2) |keep| {
				result[index] = .{
					.input = &@field(fixture, std.fmt.comptimePrint("bytes_{d}_{d}", .{ orientation, negative })),
					.keep = keep,
					.headers = .{
						@field(fixture, std.fmt.comptimePrint("header_{d}_{d}_{d}_0", .{ orientation, negative, keep })),
						@field(fixture, std.fmt.comptimePrint("header_{d}_{d}_{d}_1", .{ orientation, negative, keep })),
					},
					.pixels = .{
						&@field(fixture, std.fmt.comptimePrint("pixels_{d}_{d}_{d}_0", .{ orientation, negative, keep })),
						&@field(fixture, std.fmt.comptimePrint("pixels_{d}_{d}_{d}_1", .{ orientation, negative, keep })),
					},
				};
				index += 1;
			}
		}
	}
	break :blk result;
};

test "orientation transforms cropped layer offsets and pixels for both origin signs" {
	for (cases) |case| {
		const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
		defer api.JxlDecoderDestroy(decoder);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, case.keep));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetCoalescing(decoder, 0));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x400 | 0x1000));
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, case.input.ptr, case.input.len));
		api.JxlDecoderCloseInput(decoder);
		for (case.headers, case.pixels) |expected_header, expected_pixels| {
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FRAME, api.JxlDecoderProcessInput(decoder));
			var header: api.JxlFrameHeader = undefined;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetFrameHeader(decoder, &header));
			try std.testing.expectEqualSlices(i32, &expected_header, &.{ @intCast(header.layer_info.xsize), @intCast(header.layer_info.ysize), header.layer_info.have_crop, header.layer_info.crop_x0, header.layer_info.crop_y0 });
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
			const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
			var needed: usize = 0;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderImageOutBufferSize(decoder, &format, &needed));
			try std.testing.expectEqual(expected_pixels.len, needed);
			const output = try std.testing.allocator.alloc(u8, needed);
			defer std.testing.allocator.free(output);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, output.ptr, output.len));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
			try std.testing.expectEqualSlices(u8, expected_pixels, output);
		}
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
	}
}
