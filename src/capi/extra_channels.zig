const std = @import("std");

const enc_api = @import("../lib/codec/enc_api.zig");
const image_metadata = @import("../lib/codec/image_metadata.zig");

pub const JXL_BOOL = c_int;

pub const JxlExtraChannelType = enum(c_int) {
	JXL_CHANNEL_ALPHA = 0,
	JXL_CHANNEL_DEPTH = 1,
	JXL_CHANNEL_SPOT_COLOR = 2,
	JXL_CHANNEL_SELECTION_MASK = 3,
	JXL_CHANNEL_BLACK = 4,
	JXL_CHANNEL_CFA = 5,
	JXL_CHANNEL_THERMAL = 6,
	JXL_CHANNEL_RESERVED0 = 7,
	JXL_CHANNEL_RESERVED1 = 8,
	JXL_CHANNEL_RESERVED2 = 9,
	JXL_CHANNEL_RESERVED3 = 10,
	JXL_CHANNEL_RESERVED4 = 11,
	JXL_CHANNEL_RESERVED5 = 12,
	JXL_CHANNEL_RESERVED6 = 13,
	JXL_CHANNEL_RESERVED7 = 14,
	JXL_CHANNEL_UNKNOWN = 15,
	JXL_CHANNEL_OPTIONAL = 16,
};

pub const JxlExtraChannelInfo = extern struct {
	type: JxlExtraChannelType,
	bits_per_sample: u32,
	exponent_bits_per_sample: u32,
	dim_shift: u32,
	name_length: u32,
	alpha_premultiplied: JXL_BOOL,
	spot_color: [4]f32,
	cfa_channel: u32,
};

pub const BasicExtraChannelShape = struct {
	num_extra_channels: u32,
	alpha_bits: u32,
	alpha_exponent_bits: u32,
	alpha_premultiplied: JXL_BOOL,
};

pub const PendingExtraChannel = struct {
	info_set: bool = false,
	info: JxlExtraChannelInfo = std.mem.zeroes(JxlExtraChannelInfo),
	name_len: usize = 0,
	name_buf: [1071]u8 = [_]u8{0} ** 1071,
	buffer: []u8 = &.{},
	row_stride: usize = 0,
	buffer_set: bool = false,
};

pub const QueuedPlaneBuffer = struct {
	buffer: []u8 = &.{},
	row_stride: usize = 0,
	buffer_set: bool = false,
};

pub const PreparedSimplePackedInput = struct {
	color_row_stride: usize,
	color_pixels: []u8,
	alpha_row_stride: usize,
	alpha_pixels: []u8,
	extra_planes: []enc_api.SimpleExtraPlaneU8,

	pub fn deinit(self: *PreparedSimplePackedInput, allocator: std.mem.Allocator) void {
		allocator.free(self.color_pixels);
		if (self.alpha_pixels.len != 0) allocator.free(self.alpha_pixels);
		allocator.free(self.extra_planes);
		self.* = .{
			.color_row_stride = 0,
			.color_pixels = &.{},
			.alpha_row_stride = 0,
			.alpha_pixels = &.{},
			.extra_planes = &.{},
		};
	}
};

/// Converts libjxl's public extra-channel enum to the internal metadata enum,
/// keeping unsupported/reserved values explicit at the C API boundary.
pub fn extraChannelTypeToInternal(extra_type: JxlExtraChannelType) ?image_metadata.ExtraChannel {
	return switch (extra_type) {
		.JXL_CHANNEL_ALPHA => .alpha,
		.JXL_CHANNEL_DEPTH => .depth,
		.JXL_CHANNEL_SPOT_COLOR => .spot_color,
		.JXL_CHANNEL_SELECTION_MASK => .selection_mask,
		.JXL_CHANNEL_BLACK => .black,
		.JXL_CHANNEL_CFA => .cfa,
		.JXL_CHANNEL_THERMAL => .thermal,
		.JXL_CHANNEL_OPTIONAL => .optional,
		else => null,
	};
}

/// Converts internal decoded metadata back to libjxl's public extra-channel enum
/// so decoder inspection mirrors the original codestream channel type.
pub fn extraChannelTypeFromInternal(extra_type: image_metadata.ExtraChannel) JxlExtraChannelType {
	return switch (extra_type) {
		.alpha => .JXL_CHANNEL_ALPHA,
		.depth => .JXL_CHANNEL_DEPTH,
		.spot_color => .JXL_CHANNEL_SPOT_COLOR,
		.selection_mask => .JXL_CHANNEL_SELECTION_MASK,
		.black => .JXL_CHANNEL_BLACK,
		.cfa => .JXL_CHANNEL_CFA,
		.thermal => .JXL_CHANNEL_THERMAL,
		.reserved0 => .JXL_CHANNEL_RESERVED0,
		.reserved1 => .JXL_CHANNEL_RESERVED1,
		.reserved2 => .JXL_CHANNEL_RESERVED2,
		.reserved3 => .JXL_CHANNEL_RESERVED3,
		.reserved4 => .JXL_CHANNEL_RESERVED4,
		.reserved5 => .JXL_CHANNEL_RESERVED5,
		.reserved6 => .JXL_CHANNEL_RESERVED6,
		.reserved7 => .JXL_CHANNEL_RESERVED7,
		.unknown => .JXL_CHANNEL_UNKNOWN,
		.optional => .JXL_CHANNEL_OPTIONAL,
	};
}

/// Copies internal decoded extra-channel metadata into the public C ABI struct,
/// including names and per-channel interpretation fields.
pub fn populateExtraChannelInfo(info: *JxlExtraChannelInfo, extra: *const image_metadata.ExtraChannelInfo) void {
	info.* = std.mem.zeroes(JxlExtraChannelInfo);
	info.type = extraChannelTypeFromInternal(extra.type);
	info.bits_per_sample = extra.bit_depth.bits_per_sample;
	info.exponent_bits_per_sample = extra.bit_depth.exponent_bits_per_sample;
	info.dim_shift = extra.dim_shift;
	info.name_length = extra.name_len;
	info.alpha_premultiplied = @intFromBool(extra.alpha_associated);
	info.spot_color = extra.spot_color;
	info.cfa_channel = extra.cfa_channel;
}

/// Keeps the public encoder slice intentionally narrow: full-size uint8 extra
/// channels only, plus staged-alpha metadata that matches the declared basic info.
pub fn validateExtraChannelInfoForSimpleEncode(
	basic_info: BasicExtraChannelShape,
	index: usize,
	info: *const JxlExtraChannelInfo,
) !void {
	const extra_type = extraChannelTypeToInternal(info.type) orelse return error.Unsupported;
	if (basic_info.num_extra_channels == 0) return error.Unsupported;
	if (basic_info.alpha_bits != 0 and index == 0) {
		if (extra_type != .alpha) return error.Unsupported;
		if (info.bits_per_sample != basic_info.alpha_bits or info.exponent_bits_per_sample != basic_info.alpha_exponent_bits) return error.Unsupported;
		if (info.dim_shift > 3) return error.Unsupported;
		if (info.name_length > 1071) return error.Unsupported;
		if (info.alpha_premultiplied != basic_info.alpha_premultiplied) return error.Unsupported;
		if (!std.mem.eql(f32, &info.spot_color, &[_]f32{ 0, 0, 0, 0 })) return error.Unsupported;
		if (info.cfa_channel != 0) return error.Unsupported;
		return;
	}
	if (extra_type == .alpha) return error.Unsupported;
	if (info.bits_per_sample != 8 or info.exponent_bits_per_sample != 0) return error.Unsupported;
	if (info.dim_shift > 3) return error.Unsupported;
	if (info.name_length > 1071) return error.Unsupported;

	const zero_spot = [_]f32{ 0, 0, 0, 0 };
	switch (extra_type) {
		.depth, .selection_mask, .black, .thermal, .optional => {
			if (info.alpha_premultiplied != 0) return error.Unsupported;
			if (!std.mem.eql(f32, &info.spot_color, &zero_spot)) return error.Unsupported;
			if (info.cfa_channel != 0) return error.Unsupported;
		},
		.spot_color => {
			if (info.alpha_premultiplied != 0) return error.Unsupported;
			if (info.cfa_channel != 0) return error.Unsupported;
			for (info.spot_color) |component| {
				if (!std.math.isFinite(component)) return error.Unsupported;
			}
		},
		.cfa => {
			if (info.alpha_premultiplied != 0) return error.Unsupported;
			if (!std.mem.eql(f32, &info.spot_color, &zero_spot)) return error.Unsupported;
		},
		.alpha => return error.Unsupported,
		else => return error.Unsupported,
	}
}

/// Builds the encoder-core extra-channel metadata record from a staged C API
/// sidecar plane, preserving the caller-owned public name slice length.
pub fn toInternalExtraChannelInfo(pending: *const PendingExtraChannel) !image_metadata.ExtraChannelInfo {
	const extra_type = extraChannelTypeToInternal(pending.info.type) orelse return error.Unsupported;
	return .{
		.type = extra_type,
		.bit_depth = .{
			.floating_point_sample = pending.info.exponent_bits_per_sample != 0,
			.bits_per_sample = pending.info.bits_per_sample,
			.exponent_bits_per_sample = pending.info.exponent_bits_per_sample,
		},
		.dim_shift = pending.info.dim_shift,
		.name = pending.name_buf[0..pending.name_len],
		.name_len = @intCast(pending.name_len),
		.alpha_associated = pending.info.alpha_premultiplied != 0,
		.spot_color = pending.info.spot_color,
		.cfa_channel = pending.info.cfa_channel,
	};
}

test "extra-channel validation accepts matching staged alpha metadata" {
	var alpha = std.mem.zeroes(JxlExtraChannelInfo);
	alpha.type = .JXL_CHANNEL_ALPHA;
	alpha.bits_per_sample = 8;
	alpha.alpha_premultiplied = 1;

	try validateExtraChannelInfoForSimpleEncode(.{
		.num_extra_channels = 1,
		.alpha_bits = 8,
		.alpha_exponent_bits = 0,
		.alpha_premultiplied = 1,
	}, 0, &alpha);

	alpha.alpha_premultiplied = 0;
	try std.testing.expectError(error.Unsupported, validateExtraChannelInfoForSimpleEncode(.{
		.num_extra_channels = 1,
		.alpha_bits = 8,
		.alpha_exponent_bits = 0,
		.alpha_premultiplied = 1,
	}, 0, &alpha));
}

test "extra-channel validation preserves non-alpha sidecar constraints" {
	var mask = std.mem.zeroes(JxlExtraChannelInfo);
	mask.type = .JXL_CHANNEL_SELECTION_MASK;
	mask.bits_per_sample = 8;
	try validateExtraChannelInfoForSimpleEncode(.{
		.num_extra_channels = 1,
		.alpha_bits = 0,
		.alpha_exponent_bits = 0,
		.alpha_premultiplied = 0,
	}, 0, &mask);

	mask.bits_per_sample = 16;
	try std.testing.expectError(error.Unsupported, validateExtraChannelInfoForSimpleEncode(.{
		.num_extra_channels = 1,
		.alpha_bits = 0,
		.alpha_exponent_bits = 0,
		.alpha_premultiplied = 0,
	}, 0, &mask));
}
