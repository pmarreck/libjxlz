const std = @import("std");
const api = @import("../capi_root.zig");
const fixture = @import("../lib/codec/float_mixed_reference_fixture.zig");
const success = api.JxlDecoderStatus.JXL_DEC_SUCCESS;
fn check(comptime id: usize, comptime coalescing: bool) !void {
	const key = std.fmt.comptimePrint("{d}", .{id});
	const data = &@field(fixture, "bytes_" ++ key);
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSetCoalescing(dec, @intFromBool(coalescing)));
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, @intFromEnum(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE)));
	const format = api.JxlPixelFormat{ .num_channels = 3 + (id % 10) / 5, .data_type = .JXL_TYPE_FLOAT, .endianness = .JXL_LITTLE_ENDIAN, .@"align" = 0 };
	for (0..2) |_| {
		try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, data, data.len));
		api.JxlDecoderCloseInput(dec);
		inline for (0..@field(fixture, (if (coalescing) "frames_" else "layers_") ++ key)) |frame| {
			const expected = &@field(fixture, (if (coalescing) "float_" else "layer_") ++ key ++ "_" ++ std.fmt.comptimePrint("{d}", .{frame}));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(dec));
			var size: usize = 0;
			try std.testing.expectEqual(success, api.JxlDecoderImageOutBufferSize(dec, &format, &size));
			try std.testing.expectEqual(expected.len * 4, size);
			const output = try std.testing.allocator.alloc(u8, size);
			defer std.testing.allocator.free(output);
			try std.testing.expectEqual(success, api.JxlDecoderSetImageOutBuffer(dec, &format, output.ptr, size));
			try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE, api.JxlDecoderProcessInput(dec));
			for (expected, 0..) |bits, i| {
				const actual = std.mem.readInt(u32, output[i * 4 ..][0..4], .little);
				if (bits & 0x7fffffff == 0 or bits & 0x7fffffff == 0x7f800000) try std.testing.expectEqual(bits, actual) else if (bits & 0x7fffffff > 0x7f800000) try std.testing.expect(actual & 0x7fffffff > 0x7f800000) else {
					const value: f32 = @bitCast(actual);
					try std.testing.expect(std.math.isFinite(value));
					try std.testing.expectApproxEqAbs(@as(f32, @bitCast(bits)), value, 0.000001);
				}
			}
		}
		try std.testing.expectEqual(success, api.JxlDecoderProcessInput(dec));
		api.JxlDecoderRewind(dec);
	}
}
test "mixed floating reference color transforms match upstream and rewind" {
	inline for (0..20) |id| {
		try check(id, false);
		try check(id, true);
	}
}
