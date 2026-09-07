const std = @import("std");
const api = @import("../capi_root.zig");
const fixture = @import("orientation_fixture.zig");

test "orientation metadata follows the keep flag for all eight orientations" {
	inline for (1..9) |orientation| {
		inline for (0..2) |keep| {
			const input = @field(fixture, std.fmt.comptimePrint("bytes_{d}", .{orientation}));
			const expected = @field(fixture, std.fmt.comptimePrint("info_{d}_{d}", .{ orientation, keep }));
			const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
			defer api.JxlDecoderDestroy(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, keep));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x40));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
			api.JxlDecoderCloseInput(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO, api.JxlDecoderProcessInput(decoder));
			var info: api.JxlBasicInfo = undefined;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetBasicInfo(decoder, &info));
			try std.testing.expectEqualSlices(u32, &expected, &.{ info.xsize, info.ysize, @intCast(@intFromEnum(info.orientation)) });
		}
	}
}

test "orientation pixels match upstream for all eight orientations and keep flags" {
	inline for (1..9) |orientation| {
		inline for (0..2) |keep| {
			const input = @field(fixture, std.fmt.comptimePrint("bytes_{d}", .{orientation}));
			const expected = @field(fixture, std.fmt.comptimePrint("pixels_{d}_{d}", .{ orientation, keep }));
			const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
			defer api.JxlDecoderDestroy(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, keep));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x1000));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
			api.JxlDecoderCloseInput(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
			const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 };
			var output: [18]u8 = undefined;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &output, output.len));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
			try std.testing.expectEqualSlices(u8, &expected, &output);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
		}
	}
}

fn checkAlignedOutput(comptime prefix: []const u8, format: api.JxlPixelFormat) !void {
	@setEvalBranchQuota(100_000);
	inline for (1..9) |orientation| {
		inline for (0..2) |keep| {
			const input = @field(fixture, std.fmt.comptimePrint("bytes_{d}", .{orientation}));
			const expected = @field(fixture, std.fmt.comptimePrint("{s}_{d}_{d}", .{ prefix, orientation, keep }));
			const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
			defer api.JxlDecoderDestroy(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, keep));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x1000));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
			api.JxlDecoderCloseInput(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
			var needed: usize = 0;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderImageOutBufferSize(decoder, &format, &needed));
			try std.testing.expectEqual(expected.len, needed);
			var output: [expected.len + 1]u8 = @splat(0xa5);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &output, expected.len));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
			try std.testing.expectEqualSlices(u8, &expected, output[0..expected.len]);
			try std.testing.expectEqual(@as(u8, 0xa5), output[expected.len]);
		}
	}
}

test "orientation aligned buffers use the oriented width and preserve padding" {
	try checkAlignedOutput("aligned", .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 8 });
}

test "orientation preserves big endian 16 bit RGBA pixels and row padding" {
	try checkAlignedOutput("wide", .{ .num_channels = 4, .data_type = .JXL_TYPE_UINT16, .endianness = .JXL_BIG_ENDIAN, .@"align" = 16 });
}

test "orientation applies independently to actual preview output" {
	inline for (1..9) |orientation| {
		inline for (0..2) |keep| {
			const input = @field(fixture, std.fmt.comptimePrint("preview_bytes_{d}", .{orientation}));
			const expected = @field(fixture, std.fmt.comptimePrint("preview_pixels_{d}_{d}", .{ orientation, keep }));
			const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
			defer api.JxlDecoderDestroy(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, keep));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x200 | 0x1000));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
			api.JxlDecoderCloseInput(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_PREVIEW_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
			const format: api.JxlPixelFormat = .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 8 };
			var needed: usize = 0;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderPreviewOutBufferSize(decoder, &format, &needed));
			try std.testing.expectEqual(expected.len, needed);
			var output: [expected.len + 1]u8 = @splat(0xa5);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetPreviewOutBuffer(decoder, &format, &output, expected.len));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_PREVIEW_IMAGE, api.JxlDecoderProcessInput(decoder));
			try std.testing.expectEqualSlices(u8, &expected, output[0..expected.len]);
			try std.testing.expectEqual(@as(u8, 0xa5), output[expected.len]);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(decoder));
			@memset(&output, 0xa5);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(decoder, &format, &output, expected.len));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(decoder));
			try std.testing.expectEqualSlices(u8, &expected, output[0..expected.len]);
			try std.testing.expectEqual(@as(u8, 0xa5), output[expected.len]);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(decoder));
		}
	}
}

test "orientation frame dimensions follow keep and coalescing settings" {
	@setEvalBranchQuota(100_000);
	inline for (1..9) |orientation| {
		inline for (0..2) |keep| {
			inline for (0..2) |coalescing| {
				const input = @field(fixture, std.fmt.comptimePrint("bytes_{d}", .{orientation}));
				const expected = @field(fixture, std.fmt.comptimePrint("{s}_{d}_{d}", .{ if (coalescing == 1) "frame" else "layer", orientation, keep }));
				const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
				defer api.JxlDecoderDestroy(decoder);
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetKeepOrientation(decoder, keep));
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetCoalescing(decoder, coalescing));
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x400));
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
				api.JxlDecoderCloseInput(decoder);
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FRAME, api.JxlDecoderProcessInput(decoder));
				var header: api.JxlFrameHeader = undefined;
				try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetFrameHeader(decoder, &header));
				try std.testing.expectEqualSlices(u32, &expected, &.{ header.layer_info.xsize, header.layer_info.ysize });
			}
		}
	}
}
