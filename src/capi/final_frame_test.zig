const std = @import("std");
const api = @import("../capi_root.zig");

// The coverage probe's 2x2 control. Upstream libjxl 0.12 rejects this stream
// as truncated when byte 9's final-frame bit is cleared.
const control = [_]u8{
	0xff, 0x0a, 0x08, 0x00, 0x02, 0x80, 0x48, 0x08, 0x02, 0x01, 0x00, 0x68,
	0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00, 0xc2, 0x8d, 0x78, 0x1b,
	0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f, 0x94, 0xc8, 0xff, 0xa0, 0xa9,
	0x14, 0xbc, 0x07,
};

test "final frame marker is required by strict validation" {
	var result: api.JxlValidationResult = undefined;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(&control, control.len, null, &result));
	var truncated = control;
	truncated[9] = 0;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_CORRUPT, api.JxlValidate(&truncated, truncated.len, null, &result));
	try std.testing.expectEqual(api.JxlValidationFindingCode.JXL_VALIDATION_FINDING_TRUNCATED, result.code);
	try std.testing.expectEqual(@as(u32, 1), result.frames_validated);
}

test "final frame marker controls public decoder completion" {
	for ([_]bool{ true, false }) |is_last| {
		for ([_]bool{ true, false }) |closed| {
			var input = control;
			input[9] = @intFromBool(is_last);
			const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
			defer api.JxlDecoderDestroy(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetCoalescing(decoder, 0));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x400));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, &input, input.len));
			if (closed) api.JxlDecoderCloseInput(decoder);
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FRAME, api.JxlDecoderProcessInput(decoder));
			var header: api.JxlFrameHeader = undefined;
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderGetFrameHeader(decoder, &header));
			try std.testing.expectEqual(@as(c_int, @intFromBool(is_last)), header.is_last);
			const expected: api.JxlDecoderStatus = if (is_last) .JXL_DEC_SUCCESS else if (closed) .JXL_DEC_ERROR else .JXL_DEC_NEED_MORE_INPUT;
			try std.testing.expectEqual(expected, api.JxlDecoderProcessInput(decoder));
		}
	}
}
