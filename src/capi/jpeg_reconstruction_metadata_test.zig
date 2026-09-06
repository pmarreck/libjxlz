const std = @import("std");
const api = @import("../capi_root.zig");
const container = @import("../lib/codec/container.zig");
const fixture = @import("../lib/codec/jpeg_coefficients_fixture.zig");
const reconstruction = @import("../lib/codec/jpeg_reconstruction_fixture.zig");
const success = api.JxlDecoderStatus.JXL_DEC_SUCCESS;
test "public decoder parses upstream JPEG reconstruction containers through rewind" {
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, @intFromEnum(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO)));
	for (0..2) |_| {
		try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, &fixture.bytes_0, fixture.bytes_0.len));
		api.JxlDecoderCloseInput(dec);
		try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO, api.JxlDecoderProcessInput(dec));
		var info: api.JxlBasicInfo = undefined;
		try std.testing.expectEqual(success, api.JxlDecoderGetBasicInfo(dec, &info));
		try std.testing.expectEqual(fixture.dimensions_0[0], info.xsize);
		try std.testing.expectEqual(fixture.dimensions_0[1], info.ysize);
		api.JxlDecoderRewind(dec);
	}
}
test "public decoder rejects malformed reconstruction metadata before basic info" {
	var original = try container.extractCodestreamAndBoxes(std.testing.allocator, &fixture.bytes_0);
	defer original.deinit(std.testing.allocator);
	const wrapped = try container.wrapCodestreamWithBoxes(std.testing.allocator, original.codestream, &.{.{ .box_type = "jbrd".*, .contents = reconstruction.bytes_0[0 .. reconstruction.bytes_0.len - 1] }});
	defer std.testing.allocator.free(wrapped);
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, @intFromEnum(api.JxlDecoderStatus.JXL_DEC_BASIC_INFO)));
	try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, wrapped.ptr, wrapped.len));
	api.JxlDecoderCloseInput(dec);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderProcessInput(dec));
}
