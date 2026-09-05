const std = @import("std");
const api = @import("../capi_root.zig");
fn checkFloatFilter(data: []const u8, expected: []const u32, id: usize) !void {
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(dec, @intFromEnum(api.JxlDecoderStatus.JXL_DEC_FULL_IMAGE)));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(dec, data.ptr, data.len));
	api.JxlDecoderCloseInput(dec);
	const output = try std.testing.allocator.alloc(u8, expected.len * 4);
	defer std.testing.allocator.free(output);
	const format = api.JxlPixelFormat{ .num_channels = 3, .data_type = .JXL_TYPE_FLOAT, .endianness = .JXL_LITTLE_ENDIAN, .@"align" = 0 };
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(dec));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetImageOutBuffer(dec, &format, output.ptr, output.len));
	const status = api.JxlDecoderProcessInput(dec);
	if (status != .JXL_DEC_FULL_IMAGE) {
		std.debug.print("float filter id={d} status={any}\n", .{ id, status });
		return error.TestUnexpectedResult;
	}
	for (expected, 0..) |bits, i| {
		const actual = std.mem.readInt(u32, output[i * 4 ..][0..4], .little);
		if (id == 0 or bits & 0x7fffffff == 0 or bits & 0x7fffffff == 0x7f800000) try std.testing.expectEqual(bits, actual) else if (bits & 0x7fffffff > 0x7f800000) {
			if (actual & 0x7fffffff <= 0x7f800000) {
				std.debug.print("float filter nan id={d} sample={d} actual={x} expected={x}\n", .{ id, i, actual, bits });
				return error.TestUnexpectedResult;
			}
		} else {
			const wanted: f32 = @bitCast(bits);
			const got: f32 = @bitCast(actual);
			if (!std.math.isFinite(got) or @abs(got - wanted) > 0.0001 + 0.00001 * @abs(wanted)) {
				std.debug.print("float filter id={d} sample={d} actual={x} expected={x}\n", .{ id, i, actual, bits });
				return error.TestUnexpectedResult;
			}
		}
	}
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderProcessInput(dec));
}
test "nonfinite float filters match upstream Gaborish and EPF output" {
	const fixture = @import("../lib/codec/float_filter_fixture.zig");
	inline for (0..8) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, checkFloatFilter, .{ &@field(fixture, "bytes_" ++ key), &@field(fixture, "float_" ++ key), id });
	}
}
