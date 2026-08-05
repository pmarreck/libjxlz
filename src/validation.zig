const capi = @import("capi_root.zig");

pub const Verdict = capi.JxlValidationVerdict;
pub const FindingCode = capi.JxlValidationFindingCode;
pub const Options = capi.JxlValidationOptions;
pub const Result = capi.JxlValidationResult;

pub const default_options = capi.default_validation_options;

/// Strictly validates one bounded JPEG XL slice and returns an owned scalar result.
/// `host_byte_offset` maps findings back into an embedding TIFF or other host file.
pub fn validate(bytes: []const u8, options: Options) Result {
    var result: Result = undefined;
    _ = capi.JxlValidate(if (bytes.len == 0) null else bytes.ptr, bytes.len, &options, &result);
    return result;
}

test "invalid signature has an exact host-relative offset" {
	const result = validate(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, .{
		.struct_size = @sizeOf(Options),
		.host_byte_offset = 91,
		.max_input_bytes = 12,
        .max_pixels = 1,
        .max_frames = 1,
    });
    try @import("std").testing.expectEqual(Verdict.JXL_VALIDATION_CORRUPT, result.verdict);
    try @import("std").testing.expectEqual(FindingCode.JXL_VALIDATION_FINDING_INVALID_SIGNATURE, result.code);
    try @import("std").testing.expectEqual(@as(u64, 91), result.host_byte_offset);
    try @import("std").testing.expectEqual(@as(c_int, 1), result.offset_is_exact);
}
