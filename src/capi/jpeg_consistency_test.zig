const std = @import("std");
const api = @import("../capi_root.zig");
const container = @import("../lib/codec/container.zig");
const fixture = @import("../lib/codec/jpeg_coefficients_fixture.zig");
// The independently decoded 2x2 Modular control from capi_container.c.
const modular = [_]u8{
	0xff, 0x0a, 0x08, 0x00, 0x02, 0x80, 0x48, 0x08, 0x02, 0x01, 0x00, 0x68,
	0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00, 0xc2, 0x8d, 0x78, 0x1b,
	0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f, 0x94, 0xc8, 0xff, 0xa0, 0xa9,
	0x14, 0xbc, 0x07,
};

fn incompatibleInput(allocator: std.mem.Allocator) ![]u8 {
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
	return container.wrapCodestreamWithBoxes(allocator, &modular, &required);
}

test "strict JPEG reconstruction rejects metadata attached to a Modular codestream" {
	var result: api.JxlValidationResult = undefined;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(&modular, modular.len, null, &result));
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(&fixture.bytes_0, fixture.bytes_0.len, null, &result));
	const input = try incompatibleInput(std.testing.allocator);
	defer std.testing.allocator.free(input);
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_CORRUPT, api.JxlValidate(input.ptr, input.len, null, &result));
	try std.testing.expectEqual(api.JxlValidationFindingCode.JXL_VALIDATION_FINDING_MALFORMED, result.code);
}

test "public JPEG reconstruction rejects the same incompatible Modular control" {
	const input = try incompatibleInput(std.testing.allocator);
	defer std.testing.allocator.free(input);
	const decoder = api.JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer api.JxlDecoderDestroy(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSubscribeEvents(decoder, 0x2000 | 0x1000));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetInput(decoder, input.ptr, input.len));
	api.JxlDecoderCloseInput(decoder);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_JPEG_RECONSTRUCTION, api.JxlDecoderProcessInput(decoder));
	const pixels = try std.testing.allocator.alloc(u8, fixture.jpeg_0.len);
	defer std.testing.allocator.free(pixels);
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_SUCCESS, api.JxlDecoderSetJPEGBuffer(decoder, pixels.ptr, pixels.len));
	try std.testing.expectEqual(api.JxlDecoderStatus.JXL_DEC_ERROR, api.JxlDecoderProcessInput(decoder));
}

fn checkValidFixtures(comptime cases_module: type, comptime count: usize) !void {
	@setEvalBranchQuota(100_000);
	inline for (0..count) |index| {
		const bytes = @field(cases_module, std.fmt.comptimePrint("bytes_{d}", .{index}));
		var result: api.JxlValidationResult = undefined;
		const verdict = api.JxlValidate(&bytes, bytes.len, null, &result);
		if (verdict != .JXL_VALIDATION_VALID) std.debug.print("JPEG consistency fixture {d}: finding {d}\n", .{ index, @intFromEnum(result.code) });
		try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, verdict);
	}
}

test "strict JPEG consistency accepts three natural upstream controls" {
	try checkValidFixtures(@import("jpeg_output_fixture.zig"), 3);
}

test "strict JPEG consistency accepts all upstream sequential coefficient controls" {
	try checkValidFixtures(@import("../lib/codec/jpeg_coefficients_synthetic_fixture.zig"), 80);
}

test "strict JPEG consistency accepts all upstream progressive coefficient controls" {
	try checkValidFixtures(@import("../lib/codec/jpeg_writer_progressive_fixture.zig"), 80);
}
