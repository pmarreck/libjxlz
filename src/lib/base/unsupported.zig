//! Names the specific JPEG XL feature that stopped strict validation.
//!
//! Zig error sets carry no payload, so a bare `error.Unsupported` cannot say
//! *which* feature tripped, and a consumer is left with "unsupported" and no
//! way to tell a user what to do. Rejection sites call `unsupported(.patches)`,
//! which records the reason in a thread-local slot that the validation boundary
//! reads back. Thread-local rather than a plain global so two concurrent
//! validations cannot interleave reasons.
//!
//! A site that still returns a bare `error.Unsupported` leaves the slot at
//! `.none`, and the boundary reports `.unknown` for that case. Uninstrumented
//! sites are therefore visible in the output rather than silently mislabeled,
//! which is what makes the remaining sweep measurable.

const JxlError = @import("status.zig").JxlError;

/// Stable feature identifiers shared with the C `JxlValidationFeature` enum.
/// Values are ABI: append, never renumber.
pub const Feature = enum(c_int) {
	none = 0,
	unknown = 1,
	vardct_frame = 2,
	patches = 3,
	noise = 4,
	splines = 5,
	progressive_dc_frame = 6,
	reference_frame = 7,
	modular_transform = 8,
	extra_channel_type = 9,
	color_encoding = 10,
	icc_profile = 11,
	bit_depth = 12,
	chroma_subsampling = 13,
	frame_blending = 14,
	upsampling = 15,
	container_box = 16,
	jpeg_reconstruction = 17,
	animation = 18,
	preview_frame = 19,
	color_channel_count = 20,
	codestream_extension = 21,

	/// Stable ASCII name, so a consumer can show a user which feature stopped
	/// validation without mirroring this table on its own side.
	pub fn name(self: Feature) [*:0]const u8 {
		return switch (self) {
			.none => "none",
			.unknown => "unknown",
			.vardct_frame => "vardct_frame",
			.patches => "patches",
			.noise => "noise",
			.splines => "splines",
			.progressive_dc_frame => "progressive_dc_frame",
			.reference_frame => "reference_frame",
			.modular_transform => "modular_transform",
			.extra_channel_type => "extra_channel_type",
			.color_encoding => "color_encoding",
			.icc_profile => "icc_profile",
			.bit_depth => "bit_depth",
			.chroma_subsampling => "chroma_subsampling",
			.frame_blending => "frame_blending",
			.upsampling => "upsampling",
			.container_box => "container_box",
			.jpeg_reconstruction => "jpeg_reconstruction",
			.animation => "animation",
			.preview_frame => "preview_frame",
			.color_channel_count => "color_channel_count",
			.codestream_extension => "codestream_extension",
		};
	}
};

threadlocal var pending: Feature = .none;

/// Resets the slot. The validation boundary calls this before each run so a
/// reason cannot survive from a previous call and be reported against the next.
pub fn clear() void {
	pending = .none;
}

/// Reads back the recorded reason, mapping "nothing recorded" to `.unknown`
/// so an uninstrumented rejection site is never reported as no feature at all.
pub fn take() Feature {
	const feature = pending;
	pending = .none;
	return if (feature == .none) .unknown else feature;
}

/// Records `feature` and yields `error.Unsupported`. Rejection sites read
/// `return unsupported(.patches);`, which makes forgetting the reason a
/// visibly different line rather than a silent omission.
pub fn unsupported(feature: Feature) JxlError {
	pending = feature;
	return JxlError.Unsupported;
}

// ── Tests ──

const std = @import("std");
const testing = std.testing;

test "unsupported records the feature and take clears it" {
	clear();
	try testing.expectEqual(JxlError.Unsupported, unsupported(.patches));
	try testing.expectEqual(Feature.patches, take());
	// Second read must not repeat a consumed reason.
	try testing.expectEqual(Feature.unknown, take());
}

test "an uninstrumented site reads back as unknown, never none" {
	clear();
	try testing.expectEqual(Feature.unknown, take());
}

test "distinct sites are distinguishable" {
	clear();
	try testing.expectEqual(JxlError.Unsupported, unsupported(.vardct_frame));
	try testing.expectEqual(Feature.vardct_frame, take());
	try testing.expectEqual(JxlError.Unsupported, unsupported(.noise));
	try testing.expectEqual(Feature.noise, take());
}

test "every feature has a distinct non-empty name" {
	var seen = std.StringHashMap(void).init(testing.allocator);
	defer seen.deinit();
	inline for (@typeInfo(Feature).@"enum".fields) |field| {
		const feature: Feature = @enumFromInt(field.value);
		const text = std.mem.span(feature.name());
		try testing.expect(text.len != 0);
		// A duplicated name would make two different features indistinguishable
		// to a user reading the string form.
		try testing.expect(!seen.contains(text));
		try seen.put(text, {});
	}
}
