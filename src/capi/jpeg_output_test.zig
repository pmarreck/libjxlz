const std = @import("std");
const api = @import("../capi_root.zig");
const fixture = @import("../lib/codec/jpeg_coefficients_fixture.zig");
const Status = api.JxlDecoderStatus;
const success = Status.JXL_DEC_SUCCESS;
// Measured through pinned upstream JxlDecoder on three JPEG transcodes.
const events = [_]Status{ .JXL_DEC_BASIC_INFO, .JXL_DEC_COLOR_ENCODING, .JXL_DEC_JPEG_RECONSTRUCTION, .JXL_DEC_FRAME, .JXL_DEC_FULL_IMAGE, .JXL_DEC_SUCCESS };
fn checkOutput(input: []const u8, expected_jpeg: []const u8) !void {
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, 0x40 | 0x100 | 0x2000 | 0x400 | 0x1000));
	try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, input.ptr, input.len));
	api.JxlDecoderCloseInput(dec);
	const output = try std.testing.allocator.alloc(u8, expected_jpeg.len + 32);
	defer std.testing.allocator.free(output);
	@memset(output, 0xa5);
	for (events) |expected| {
		try std.testing.expectEqual(expected, api.JxlDecoderProcessInput(dec));
		if (expected == .JXL_DEC_JPEG_RECONSTRUCTION) try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, output.ptr, output.len));
	}
	try std.testing.expectEqual(@as(usize, 32), api.JxlDecoderReleaseJPEGBuffer(dec));
	try std.testing.expectEqualSlices(u8, expected_jpeg, output[0..expected_jpeg.len]);
	try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xa5))), output[expected_jpeg.len..]);
}
test "public JPEG reconstruction matches upstream events and original bytes" {
	const corpus = @import("jpeg_output_fixture.zig");
	inline for (0..3) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		errdefer std.debug.print("JPEG public corpus record {d}\n", .{id});
		try checkOutput(&@field(corpus, "bytes_" ++ key), &@field(corpus, "jpeg_" ++ key));
	}
}
test "public JPEG reconstruction restarts events and releases borrowed buffers on rewind" {
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, 0x40 | 0x100 | 0x2000 | 0x400 | 0x1000));
	const output = try std.testing.allocator.alloc(u8, fixture.jpeg_0.len + 1);
	defer std.testing.allocator.free(output);
	for (0..3) |_| {
		try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, &fixture.bytes_0, fixture.bytes_0.len));
		api.JxlDecoderCloseInput(dec);
		@memset(output, 0xa5);
		for (events) |expected| {
			try std.testing.expectEqual(expected, api.JxlDecoderProcessInput(dec));
			if (expected == .JXL_DEC_JPEG_RECONSTRUCTION) try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, output.ptr, output.len));
		}
		try std.testing.expectEqualSlices(u8, &fixture.jpeg_0, output[0..fixture.jpeg_0.len]);
		api.JxlDecoderRewind(dec);
		try std.testing.expectEqual(@as(usize, 0), api.JxlDecoderReleaseJPEGBuffer(dec));
	}
}
test "public JPEG reconstruction drains into repeated small output buffers" {
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, 0x2000 | 0x1000));
	try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, &fixture.bytes_0, fixture.bytes_0.len));
	api.JxlDecoderCloseInput(dec);
	try std.testing.expectEqual(Status.JXL_DEC_JPEG_RECONSTRUCTION, api.JxlDecoderProcessInput(dec));
	var chunk: [17]u8 = undefined;
	try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, &chunk, chunk.len));
	try std.testing.expectEqual(Status.JXL_DEC_ERROR, api.JxlDecoderSetJPEGBuffer(dec, &chunk, chunk.len));
	var position: usize = 0;
	while (position < fixture.jpeg_0.len) {
		const status = api.JxlDecoderProcessInput(dec);
		try std.testing.expect(status == .JXL_DEC_JPEG_NEED_MORE_OUTPUT or status == .JXL_DEC_FULL_IMAGE);
		const remaining = api.JxlDecoderReleaseJPEGBuffer(dec);
		try std.testing.expect(remaining < chunk.len);
		const count = chunk.len - remaining;
		try std.testing.expect(position + count <= fixture.jpeg_0.len);
		try std.testing.expectEqualSlices(u8, fixture.jpeg_0[position..][0..count], chunk[0..count]);
		position += count;
		try std.testing.expectEqual(position == fixture.jpeg_0.len, status == .JXL_DEC_FULL_IMAGE);
		if (status == .JXL_DEC_JPEG_NEED_MORE_OUTPUT) try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, &chunk, chunk.len));
	}
	try std.testing.expectEqual(success, api.JxlDecoderProcessInput(dec));
}

test "public JPEG reconstruction rejects missing duplicate and mismatched metadata" {
	const container = @import("../lib/codec/container.zig");
	const allocator = std.testing.allocator;
	var original = try container.extractCodestreamAndBoxes(allocator, &fixture.bytes_0);
	defer original.deinit(allocator);
	var required: [3]container.Box = undefined;
	var counts: [3]usize = @splat(0);
	for (original.boxes) |box| {
		const kind = try box.effectiveBoxType(true);
		const index: ?usize = if (std.mem.eql(u8, &kind, "jbrd")) 0 else if (std.mem.eql(u8, &kind, "Exif")) 1 else if (std.mem.eql(u8, &kind, "xml ")) 2 else null;
		if (index) |i| {
			required[i] = .{ .box_type = box.box_type, .contents = box.contents };
			counts[i] += 1;
		}
	}
	try std.testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, &counts);
	const cases = [_][]const container.Box{
		&.{ required[0], required[1], required[2] },
		&.{ required[0], required[2] },
		&.{ required[0], required[1] },
		&.{ required[0], required[1], required[1], required[2] },
		&.{ required[0], required[1], .{ .box_type = "xml ".*, .contents = "wrong length" } },
	};
	for (cases, 0..) |boxes, id| {
		const input = try container.wrapCodestreamWithBoxes(allocator, original.codestream, boxes);
		defer allocator.free(input);
		const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
		defer api.JxlDecoderDestroy(dec);
		const output = try allocator.alloc(u8, fixture.jpeg_0.len);
		defer allocator.free(output);
		try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, 0x2000 | 0x1000));
		try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, input.ptr, input.len));
		api.JxlDecoderCloseInput(dec);
		try std.testing.expectEqual(Status.JXL_DEC_JPEG_RECONSTRUCTION, api.JxlDecoderProcessInput(dec));
		try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, output.ptr, output.len));
		try std.testing.expectEqual(if (id == 0) Status.JXL_DEC_FULL_IMAGE else Status.JXL_DEC_ERROR, api.JxlDecoderProcessInput(dec));
		if (id == 0) try std.testing.expectEqualSlices(u8, &fixture.jpeg_0, output);
		_ = api.JxlDecoderReleaseJPEGBuffer(dec);
	}
}

test "public JPEG output buffer preserves pixel fallback when reconstruction metadata is absent" {
	const container = @import("../lib/codec/container.zig");
	var parsed = try container.extractCodestreamAndBoxes(std.testing.allocator, &fixture.bytes_0);
	defer parsed.deinit(std.testing.allocator);
	const dec = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(dec);
	var jpeg_buffer: [32]u8 = @splat(0xa5);
	try std.testing.expectEqual(success, api.JxlDecoderSetJPEGBuffer(dec, &jpeg_buffer, jpeg_buffer.len));
	try std.testing.expectEqual(success, api.JxlDecoderSubscribeEvents(dec, 0x2000 | 0x1000));
	try std.testing.expectEqual(success, api.JxlDecoderSetInput(dec, parsed.codestream.ptr, parsed.codestream.len));
	api.JxlDecoderCloseInput(dec);
	// Upstream decode.cc requires a pixel buffer when the ImageBundle has no JPEGData.
	try std.testing.expectEqual(Status.JXL_DEC_NEED_IMAGE_OUT_BUFFER, api.JxlDecoderProcessInput(dec));
	try std.testing.expectEqual(jpeg_buffer.len, api.JxlDecoderReleaseJPEGBuffer(dec));
	try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xa5))), &jpeg_buffer);
}
