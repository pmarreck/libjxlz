const std = @import("std");
const api = @import("../capi_root.zig");
const container = @import("../lib/codec/container.zig");

test "container public input rejects truncated or invalid codestream signatures" {
	for ([_][]const u8{ &.{}, &.{0xff}, &.{ 0xff, 0x0a }, &.{ 0, 0 }, &.{ 0, 0, 0, 0 } }) |stream| {
		const bytes = try container.wrapCodestream(std.testing.allocator, stream);
		defer std.testing.allocator.free(bytes);
		var result: api.JxlValidationResult = undefined;
		try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_CORRUPT, api.JxlValidate(bytes.ptr, bytes.len, null, &result));
	}
}

test "container public input classifies malformed boxes as corrupt" {
	const allocator = std.testing.allocator;
	const fixture = @import("../lib/codec/jpeg_coefficients_fixture.zig");
	var original = try container.extractCodestreamAndBoxes(allocator, &fixture.bytes_0);
	defer original.deinit(allocator);
	const valid = try container.wrapCodestream(allocator, original.codestream);
	defer allocator.free(valid);
	var result: api.JxlValidationResult = undefined;
	try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_VALID, api.JxlValidate(valid.ptr, valid.len, null, &result));
	for (0..4) |variant| {
		var bytes: std.ArrayListUnmanaged(u8) = .empty;
		defer bytes.deinit(allocator);
		try bytes.appendSlice(allocator, valid[0..12]);
		if (variant != 0) try bytes.appendSlice(allocator, valid[12..32]);
		try bytes.appendSlice(allocator, valid[32..]);
		if (variant == 1) bytes.items[20] = 'x';
		if (variant == 2) try bytes.appendSlice(allocator, &.{ 0, 0, 0, 13, 'j', 'x', 'l', 'p', 0x80, 0, 0, 0, 0 });
		if (variant == 3) try bytes.appendSlice(allocator, &.{ 0, 0, 0, 1, 't', 'e', 's', 't', 255, 255, 255, 255, 255, 255, 255, 255 });
		try std.testing.expectEqual(api.JxlValidationVerdict.JXL_VALIDATION_CORRUPT, api.JxlValidate(bytes.items.ptr, bytes.items.len, null, &result));
		try std.testing.expectEqual(api.JxlValidationFindingCode.JXL_VALIDATION_FINDING_MALFORMED, result.code);
	}
}
