const std = @import("std");

const common = @import("lib/base/common.zig");
const byte_order = @import("lib/base/byte_order.zig");
const BitReader = @import("lib/base/bit_reader.zig").BitReader;
const JxlError = @import("lib/base/status.zig").JxlError;
const headers = @import("lib/codec/headers.zig");
const color_encoding_mod = @import("lib/codec/color_encoding.zig");
const image_metadata = @import("lib/codec/image_metadata.zig");
const frame_header_mod = @import("lib/codec/frame_header.zig");
const dec_frame = @import("lib/codec/dec_frame.zig");
const enc_api = @import("lib/codec/enc_api.zig");
const Image = @import("lib/modular/modular_image.zig").Image;

pub const JXL_BOOL = c_int;

pub const JxlDataType = enum(c_int) {
	JXL_TYPE_FLOAT = 0,
	JXL_TYPE_UINT8 = 2,
	JXL_TYPE_UINT16 = 3,
	JXL_TYPE_FLOAT16 = 5,
};

pub const JxlEndianness = enum(c_int) {
	JXL_NATIVE_ENDIAN = 0,
	JXL_LITTLE_ENDIAN = 1,
	JXL_BIG_ENDIAN = 2,
};

pub const JxlPixelFormat = extern struct {
	num_channels: u32,
	data_type: JxlDataType,
	endianness: JxlEndianness,
	@"align": usize,
};

pub const JxlOrientation = enum(c_int) {
	JXL_ORIENT_IDENTITY = 1,
	JXL_ORIENT_FLIP_HORIZONTAL = 2,
	JXL_ORIENT_ROTATE_180 = 3,
	JXL_ORIENT_FLIP_VERTICAL = 4,
	JXL_ORIENT_TRANSPOSE = 5,
	JXL_ORIENT_ROTATE_90_CW = 6,
	JXL_ORIENT_ANTI_TRANSPOSE = 7,
	JXL_ORIENT_ROTATE_90_CCW = 8,
};

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

pub const JxlPreviewHeader = extern struct {
	xsize: u32,
	ysize: u32,
};

pub const JxlAnimationHeader = extern struct {
	tps_numerator: u32,
	tps_denominator: u32,
	num_loops: u32,
	have_timecodes: JXL_BOOL,
};

pub const JxlBasicInfo = extern struct {
	have_container: JXL_BOOL,
	xsize: u32,
	ysize: u32,
	bits_per_sample: u32,
	exponent_bits_per_sample: u32,
	intensity_target: f32,
	min_nits: f32,
	relative_to_max_display: JXL_BOOL,
	linear_below: f32,
	uses_original_profile: JXL_BOOL,
	have_preview: JXL_BOOL,
	have_animation: JXL_BOOL,
	orientation: JxlOrientation,
	num_color_channels: u32,
	num_extra_channels: u32,
	alpha_bits: u32,
	alpha_exponent_bits: u32,
	alpha_premultiplied: JXL_BOOL,
	preview: JxlPreviewHeader,
	animation: JxlAnimationHeader,
	intrinsic_xsize: u32,
	intrinsic_ysize: u32,
	padding: [100]u8,
};

pub const JxlSignature = enum(c_int) {
	JXL_SIG_NOT_ENOUGH_BYTES = 0,
	JXL_SIG_INVALID = 1,
	JXL_SIG_CODESTREAM = 2,
	JXL_SIG_CONTAINER = 3,
};

pub const JxlDecoderStatus = enum(c_int) {
	JXL_DEC_SUCCESS = 0,
	JXL_DEC_ERROR = 1,
	JXL_DEC_NEED_MORE_INPUT = 2,
	JXL_DEC_NEED_PREVIEW_OUT_BUFFER = 3,
	JXL_DEC_NEED_IMAGE_OUT_BUFFER = 5,
	JXL_DEC_JPEG_NEED_MORE_OUTPUT = 6,
	JXL_DEC_BOX_NEED_MORE_OUTPUT = 7,
	JXL_DEC_BASIC_INFO = 0x40,
	JXL_DEC_COLOR_ENCODING = 0x100,
	JXL_DEC_PREVIEW_IMAGE = 0x200,
	JXL_DEC_FRAME = 0x400,
	JXL_DEC_FULL_IMAGE = 0x1000,
};

pub const JxlEncoderStatus = enum(c_int) {
	JXL_ENC_SUCCESS = 0,
	JXL_ENC_ERROR = 1,
	JXL_ENC_NEED_MORE_OUTPUT = 2,
};

pub const JxlColorSpace = enum(c_int) {
	JXL_COLOR_SPACE_RGB = 0,
	JXL_COLOR_SPACE_GRAY = 1,
	JXL_COLOR_SPACE_XYB = 2,
	JXL_COLOR_SPACE_UNKNOWN = 3,
};

pub const JxlWhitePoint = enum(c_int) {
	JXL_WHITE_POINT_D65 = 1,
	JXL_WHITE_POINT_CUSTOM = 2,
	JXL_WHITE_POINT_E = 10,
	JXL_WHITE_POINT_DCI = 11,
};

pub const JxlPrimaries = enum(c_int) {
	JXL_PRIMARIES_SRGB = 1,
	JXL_PRIMARIES_CUSTOM = 2,
	JXL_PRIMARIES_2100 = 9,
	JXL_PRIMARIES_P3 = 11,
};

pub const JxlTransferFunction = enum(c_int) {
	JXL_TRANSFER_FUNCTION_709 = 1,
	JXL_TRANSFER_FUNCTION_UNKNOWN = 2,
	JXL_TRANSFER_FUNCTION_LINEAR = 8,
	JXL_TRANSFER_FUNCTION_SRGB = 13,
	JXL_TRANSFER_FUNCTION_PQ = 16,
	JXL_TRANSFER_FUNCTION_DCI = 17,
	JXL_TRANSFER_FUNCTION_HLG = 18,
	JXL_TRANSFER_FUNCTION_GAMMA = 65535,
};

pub const JxlRenderingIntent = enum(c_int) {
	JXL_RENDERING_INTENT_PERCEPTUAL = 0,
	JXL_RENDERING_INTENT_RELATIVE = 1,
	JXL_RENDERING_INTENT_SATURATION = 2,
	JXL_RENDERING_INTENT_ABSOLUTE = 3,
};

pub const JxlColorEncoding = extern struct {
	color_space: JxlColorSpace,
	white_point: JxlWhitePoint,
	white_point_xy: [2]f64,
	primaries: JxlPrimaries,
	primaries_red_xy: [2]f64,
	primaries_green_xy: [2]f64,
	primaries_blue_xy: [2]f64,
	transfer_function: JxlTransferFunction,
	gamma: f64,
	rendering_intent: JxlRenderingIntent,
};

pub const jpegxl_alloc_func = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
pub const jpegxl_free_func = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const JxlMemoryManager = extern struct {
	@"opaque": ?*anyopaque,
	alloc: ?jpegxl_alloc_func,
	free: ?jpegxl_free_func,
};

pub const JxlParallelRetCode = c_int;
pub const JxlParallelRunInit = *const fn (?*anyopaque, usize) callconv(.c) JxlParallelRetCode;
pub const JxlParallelRunFunction = *const fn (?*anyopaque, u32, usize) callconv(.c) void;
pub const JxlParallelRunner = *const fn (?*anyopaque, ?*anyopaque, JxlParallelRunInit, JxlParallelRunFunction, u32, u32) callconv(.c) JxlParallelRetCode;

pub const JxlDecoder = opaque {};
pub const JxlEncoder = opaque {};
pub const JxlEncoderFrameSettings = opaque {};

const container_signature = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };

const DecoderImpl = struct {
	memory_manager: ?JxlMemoryManager = null,
	input_data: ?[*]const u8 = null,
	input_size: usize = 0,
	input_closed: bool = false,
	input_released: bool = false,
	started_processing: bool = false,
	subscribed_events: c_int = 0,
	keep_orientation: bool = false,
	unpremultiply_alpha: bool = false,
	render_spotcolors: bool = true,
	coalescing: bool = true,

	basic_info_available: bool = false,
	basic_info_emitted: bool = false,
	basic_info: JxlBasicInfo = std.mem.zeroes(JxlBasicInfo),
	codec_meta: image_metadata.CodecMetadata = .{},
	frame_data: []const u8 = &.{},

	output_format: JxlPixelFormat = .{
		.num_channels = 0,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	},
	output_buffer: ?[*]u8 = null,
	output_buffer_size: usize = 0,
	full_image_emitted: bool = false,
	decode_complete: bool = false,

	fn inputSlice(self: *const DecoderImpl) []const u8 {
		if (self.input_data) |ptr| {
			return ptr[0..self.input_size];
		}
		return &.{};
	}
};

const EncoderImpl = struct {
	memory_manager: ?JxlMemoryManager = null,
	basic_info_set: bool = false,
	color_encoding_set: bool = false,
	added_frame: bool = false,
	input_closed: bool = false,
	started_processing: bool = false,
	basic_info: JxlBasicInfo = std.mem.zeroes(JxlBasicInfo),
	color_encoding: JxlColorEncoding = undefined,
	encoded_bytes: []u8 = &.{},
	output_offset: usize = 0,
	frame_settings: std.ArrayListUnmanaged(*EncoderFrameSettingsImpl) = .{},
	internal_color_encoding: ?color_encoding_mod.ColorEncoding = null,
	image_format: JxlPixelFormat = .{
		.num_channels = 0,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	},
	image_bytes: []u8 = &.{},
	pending_extra_channels: [256]EncoderPendingExtraChannel = [_]EncoderPendingExtraChannel{.{}} ** 256,
};

const EncoderFrameSettingsImpl = struct {
	owner: *EncoderImpl,
};

const EncoderPendingExtraChannel = struct {
	info_set: bool = false,
	info: JxlExtraChannelInfo = std.mem.zeroes(JxlExtraChannelInfo),
	name_len: usize = 0,
	name_buf: [1071]u8 = [_]u8{0} ** 1071,
	buffer: []u8 = &.{},
	row_stride: usize = 0,
	buffer_set: bool = false,
};

fn decoderVersion() u32 {
	return 1000;
}

fn encoderVersion() u32 {
	return (@as(u32, 0) << 24) | (@as(u32, 1) << 16) | (@as(u32, 0) << 8);
}

fn statusFromError(err: JxlError, input_closed: bool) JxlDecoderStatus {
	return switch (err) {
		error.NotEnoughBytes => if (input_closed) .JXL_DEC_ERROR else .JXL_DEC_NEED_MORE_INPUT,
		else => .JXL_DEC_ERROR,
	};
}

fn allocDecoder(mm: ?*const JxlMemoryManager) ?*DecoderImpl {
	if (mm) |manager| {
		if (manager.alloc != null and manager.free != null) {
			const raw = manager.alloc.?(manager.@"opaque", @sizeOf(DecoderImpl)) orelse return null;
			const dec: *DecoderImpl = @ptrCast(@alignCast(raw));
			dec.* = .{ .memory_manager = manager.* };
			return dec;
		}
		if ((manager.alloc == null) != (manager.free == null)) return null;
	}

	const dec = std.heap.c_allocator.create(DecoderImpl) catch return null;
	dec.* = .{};
	if (mm) |manager| dec.memory_manager = manager.*;
	return dec;
}

fn freeDecoder(dec: *DecoderImpl) void {
	if (dec.memory_manager) |manager| {
		if (manager.alloc != null and manager.free != null) {
			manager.free.?(manager.@"opaque", dec);
			return;
		}
	}
	std.heap.c_allocator.destroy(dec);
}

fn allocEncoder(mm: ?*const JxlMemoryManager) ?*EncoderImpl {
	if (mm) |manager| {
		if (manager.alloc != null and manager.free != null) {
			const raw = manager.alloc.?(manager.@"opaque", @sizeOf(EncoderImpl)) orelse return null;
			const enc: *EncoderImpl = @ptrCast(@alignCast(raw));
			enc.* = .{ .memory_manager = manager.* };
			return enc;
		}
		if ((manager.alloc == null) != (manager.free == null)) return null;
	}

	const enc = std.heap.c_allocator.create(EncoderImpl) catch return null;
	enc.* = .{};
	if (mm) |manager| enc.memory_manager = manager.*;
	return enc;
}

fn freeEncoderState(enc: *EncoderImpl) void {
	clearPendingEncodeBuffers(enc);
	for (enc.frame_settings.items) |settings| {
		std.heap.c_allocator.destroy(settings);
	}
	enc.frame_settings.deinit(std.heap.c_allocator);
	enc.frame_settings = .{};
	enc.output_offset = 0;
}

fn freeEncoder(enc: *EncoderImpl) void {
	freeEncoderState(enc);
	if (enc.memory_manager) |manager| {
		if (manager.alloc != null and manager.free != null) {
			manager.free.?(manager.@"opaque", enc);
			return;
		}
	}
	std.heap.c_allocator.destroy(enc);
}

fn defaultWhitePointXY() [2]f64 {
	return .{ 0.3127, 0.3290 };
}

fn defaultPrimariesRedXY() [2]f64 {
	return .{ 0.639998686, 0.330010138 };
}

fn defaultPrimariesGreenXY() [2]f64 {
	return .{ 0.300003784, 0.600003357 };
}

fn defaultPrimariesBlueXY() [2]f64 {
	return .{ 0.150002046, 0.059997204 };
}

fn defaultJxlColorEncoding(is_gray: bool, linear: bool) JxlColorEncoding {
	return .{
		.color_space = if (is_gray) .JXL_COLOR_SPACE_GRAY else .JXL_COLOR_SPACE_RGB,
		.white_point = .JXL_WHITE_POINT_D65,
		.white_point_xy = defaultWhitePointXY(),
		.primaries = .JXL_PRIMARIES_SRGB,
		.primaries_red_xy = defaultPrimariesRedXY(),
		.primaries_green_xy = defaultPrimariesGreenXY(),
		.primaries_blue_xy = defaultPrimariesBlueXY(),
		.transfer_function = if (linear) .JXL_TRANSFER_FUNCTION_LINEAR else .JXL_TRANSFER_FUNCTION_SRGB,
		.gamma = 1.0,
		.rendering_intent = .JXL_RENDERING_INTENT_RELATIVE,
	};
}

fn defaultBasicInfo() JxlBasicInfo {
	var info = std.mem.zeroes(JxlBasicInfo);
	info.bits_per_sample = 8;
	info.orientation = .JXL_ORIENT_IDENTITY;
	info.num_color_channels = 3;
	return info;
}

fn mapRenderingIntent(intent: JxlRenderingIntent) ?color_encoding_mod.RenderingIntent {
	return switch (intent) {
		.JXL_RENDERING_INTENT_PERCEPTUAL => .perceptual,
		.JXL_RENDERING_INTENT_RELATIVE => .relative,
		.JXL_RENDERING_INTENT_SATURATION => .saturation,
		.JXL_RENDERING_INTENT_ABSOLUTE => .absolute,
	};
}

/// Converts the public C color-encoding struct into the narrow non-ICC Zig
/// color model used by the current one-shot modular encoder.
fn toInternalColorEncoding(
	color: *const JxlColorEncoding,
	num_channels: u32,
) !color_encoding_mod.ColorEncoding {
	var internal = color_encoding_mod.ColorEncoding{};
	internal.want_icc = false;
	internal.rendering_intent = mapRenderingIntent(color.rendering_intent) orelse return error.Unsupported;

	switch (color.color_space) {
		.JXL_COLOR_SPACE_GRAY => {
			if (num_channels != 1) return error.Unsupported;
			internal.color_space = .gray;
			internal.primaries = .srgb;
		},
		.JXL_COLOR_SPACE_RGB => {
			if (num_channels != 3) return error.Unsupported;
			internal.color_space = .rgb;
			if (color.primaries != .JXL_PRIMARIES_SRGB) return error.Unsupported;
			internal.primaries = .srgb;
		},
		else => return error.Unsupported,
	}

	if (color.white_point != .JXL_WHITE_POINT_D65) return error.Unsupported;
	internal.white_point = .d65;

	switch (color.transfer_function) {
		.JXL_TRANSFER_FUNCTION_SRGB => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .srgb,
		},
		.JXL_TRANSFER_FUNCTION_LINEAR => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .linear,
		},
		else => return error.Unsupported,
	}

	return internal;
}

fn bytesPerChannel(data_type: JxlDataType) ?usize {
	return switch (data_type) {
		.JXL_TYPE_UINT8 => 1,
		.JXL_TYPE_UINT16, .JXL_TYPE_FLOAT16 => 2,
		.JXL_TYPE_FLOAT => 4,
	};
}

/// Converts pixel-format alignment into a concrete row stride so callers can
/// size and write output buffers exactly like libjxl's image buffer API.
fn rowStrideBytes(width: usize, format: JxlPixelFormat) ?usize {
	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return null;
	const row_bytes = width * format.num_channels * bytes_per_channel;
	const row_align = if (format.@"align" <= 1) 1 else format.@"align";
	return common.roundUpTo(row_bytes, row_align);
}

/// Validates the narrow one-shot encoder surface: 8-bit grayscale/RGB with an
/// optional 8-bit alpha plus full-size uint8 sidecar extras, no preview/animation,
/// and identity orientation.
fn validateBasicInfoForSimpleEncode(info: *const JxlBasicInfo) !void {
	if (info.xsize == 0 or info.ysize == 0) return error.InvalidArgs;
	if (info.have_container != 0 or info.have_preview != 0 or info.have_animation != 0) return error.Unsupported;
	if (info.orientation != .JXL_ORIENT_IDENTITY) return error.Unsupported;
	if (info.bits_per_sample != 8 or info.exponent_bits_per_sample != 0) return error.Unsupported;
	if (!(info.num_color_channels == 1 or info.num_color_channels == 3)) return error.Unsupported;
	if (info.num_extra_channels == 0) {
		if (info.alpha_bits != 0 or info.alpha_exponent_bits != 0 or info.alpha_premultiplied != 0) return error.Unsupported;
		return;
	}
	if (info.alpha_bits == 0) {
		if (info.alpha_exponent_bits != 0 or info.alpha_premultiplied != 0) return error.Unsupported;
		return;
	}
	if (info.alpha_bits != 8 or info.alpha_exponent_bits != 0) return error.Unsupported;
	if (!(info.alpha_premultiplied == 0 or info.alpha_premultiplied == 1)) return error.Unsupported;
}

fn clearEncodedBytes(enc: *EncoderImpl) void {
	if (enc.encoded_bytes.len != 0) {
		std.heap.c_allocator.free(enc.encoded_bytes);
		enc.encoded_bytes = &.{};
	}
	enc.output_offset = 0;
}

/// Drops staged frame input and staged extra-channel buffers so the one-shot
/// encoder can restart cleanly without leaking memory between retries/reset.
fn clearPendingEncodeBuffers(enc: *EncoderImpl) void {
	clearEncodedBytes(enc);
	clearPendingFrameBuffers(enc);
	for (&enc.pending_extra_channels) |*pending| {
		pending.* = .{};
	}
}

/// Drops staged pixel buffers while preserving the already-declared extra
/// channel metadata so callers can set metadata before queueing the frame.
fn clearPendingFrameBuffers(enc: *EncoderImpl) void {
	if (enc.image_bytes.len != 0) {
		std.heap.c_allocator.free(enc.image_bytes);
		enc.image_bytes = &.{};
	}
	enc.image_format = .{
		.num_channels = 0,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	for (&enc.pending_extra_channels) |*pending| {
		if (pending.buffer.len != 0) {
			std.heap.c_allocator.free(pending.buffer);
			pending.buffer = &.{};
		}
		pending.row_stride = 0;
		pending.buffer_set = false;
	}
}

fn extraChannelTypeToInternal(extra_type: JxlExtraChannelType) ?image_metadata.ExtraChannel {
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

/// Keeps the public encoder slice intentionally narrow: full-size uint8 extra
/// channels only, with only the metadata shapes the current Zig codestream writer can serialize.
fn validateExtraChannelInfoForSimpleEncode(
	basic_info: *const JxlBasicInfo,
	index: usize,
	info: *const JxlExtraChannelInfo,
) !void {
	const extra_type = extraChannelTypeToInternal(info.type) orelse return error.Unsupported;
	if (basic_info.num_extra_channels == 0) return error.Unsupported;
	if (basic_info.alpha_bits != 0 and index == 0) return error.Unsupported;
	if (extra_type == .alpha) return error.Unsupported;
	if (info.bits_per_sample != 8 or info.exponent_bits_per_sample != 0) return error.Unsupported;
	if (info.dim_shift != 0) return error.Unsupported;
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

fn toInternalExtraChannelInfo(pending: *const EncoderPendingExtraChannel) !image_metadata.ExtraChannelInfo {
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

/// Finalizes the staged public-API input into the existing Zig one-shot
/// encoder by packing color and extra planes into a normalized interleaved buffer.
fn finalizeSimpleEncode(impl: *EncoderImpl) !void {
	if (impl.encoded_bytes.len != 0) return;
	if (impl.image_bytes.len == 0) return error.InvalidArgs;

	const num_color_channels = @as(usize, impl.basic_info.num_color_channels);
	const total_channels = num_color_channels + @as(usize, impl.basic_info.num_extra_channels);
	const packed_row_stride = @as(usize, impl.basic_info.xsize) * total_channels;
	const packed_len = packed_row_stride * impl.basic_info.ysize;
	const image_stride = rowStrideBytes(impl.basic_info.xsize, impl.image_format) orelse return error.GenericError;

	var extra_infos: [256]image_metadata.ExtraChannelInfo = undefined;
	var extra_info_slice: []const image_metadata.ExtraChannelInfo = &.{};
	if (impl.basic_info.num_extra_channels != 0) {
		if (impl.basic_info.alpha_bits != 0) {
			extra_infos[0] = .{
				.type = .alpha,
				.bit_depth = .{
					.floating_point_sample = impl.basic_info.alpha_exponent_bits != 0,
					.bits_per_sample = impl.basic_info.alpha_bits,
					.exponent_bits_per_sample = impl.basic_info.alpha_exponent_bits,
				},
				.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
			};
			for (1..impl.basic_info.num_extra_channels) |extra_index| {
				const pending = &impl.pending_extra_channels[extra_index];
				if (!pending.info_set or !pending.buffer_set) return error.InvalidArgs;
				extra_infos[extra_index] = try toInternalExtraChannelInfo(pending);
			}
		} else {
			for (0..impl.basic_info.num_extra_channels) |extra_index| {
				const pending = &impl.pending_extra_channels[extra_index];
				if (!pending.info_set or !pending.buffer_set) return error.InvalidArgs;
				extra_infos[extra_index] = try toInternalExtraChannelInfo(pending);
			}
		}
		extra_info_slice = extra_infos[0..impl.basic_info.num_extra_channels];
	}

	const packed_pixels = try std.heap.c_allocator.alloc(u8, packed_len);
	defer std.heap.c_allocator.free(packed_pixels);

	for (0..impl.basic_info.ysize) |y| {
		const src_row = impl.image_bytes[y * image_stride .. y * image_stride + image_stride];
		const dst_row = packed_pixels[y * packed_row_stride .. y * packed_row_stride + packed_row_stride];
		if (impl.basic_info.alpha_bits != 0) {
			for (0..impl.basic_info.xsize) |x| {
				const src_pixel = x * (num_color_channels + 1);
				const dst_pixel = x * total_channels;
				@memcpy(
					dst_row[dst_pixel .. dst_pixel + num_color_channels],
					src_row[src_pixel .. src_pixel + num_color_channels],
				);
				dst_row[dst_pixel + num_color_channels] = src_row[src_pixel + num_color_channels];
				for (1..impl.basic_info.num_extra_channels) |extra_index| {
					const pending = &impl.pending_extra_channels[extra_index];
					const extra_row = pending.buffer[y * pending.row_stride .. y * pending.row_stride + pending.row_stride];
					dst_row[dst_pixel + num_color_channels + extra_index] = extra_row[x];
				}
			}
			continue;
		}

		for (0..impl.basic_info.xsize) |x| {
			const color_src = x * num_color_channels;
			const pixel_dst = x * @as(usize, total_channels);
			@memcpy(
				dst_row[pixel_dst .. pixel_dst + num_color_channels],
				src_row[color_src .. color_src + num_color_channels],
			);
			for (0..impl.basic_info.num_extra_channels) |extra_index| {
				const pending = &impl.pending_extra_channels[extra_index];
				const extra_row = pending.buffer[y * pending.row_stride .. y * pending.row_stride + pending.row_stride];
				dst_row[pixel_dst + num_color_channels + extra_index] = extra_row[x];
			}
		}
	}

	impl.encoded_bytes = try enc_api.encodeSimpleInterleavedU8(std.heap.c_allocator, .{
		.width = impl.basic_info.xsize,
		.height = impl.basic_info.ysize,
		.num_channels = @intCast(total_channels),
		.num_extra_channels = impl.basic_info.num_extra_channels,
		.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
		.extra_channel_info = extra_info_slice,
		.row_stride = packed_row_stride,
		.pixels = packed_pixels,
	}, impl.internal_color_encoding);
	impl.output_offset = 0;
}

fn bitDepthMax(bits_per_sample: u32) u32 {
	if (bits_per_sample == 0) return 0;
	if (bits_per_sample >= 32) return std.math.maxInt(u32);
	return (@as(u32, 1) << @intCast(bits_per_sample)) - 1;
}

fn alphaChannelIndex(metadata: *const image_metadata.ImageMetadata) ?usize {
	for (0..metadata.num_extra_channels) |i| {
		if (metadata.extra_channel_info[i].type == .alpha) {
			return @as(usize, @intCast(i));
		}
	}
	return null;
}

fn storeU16(dst: []u8, endianness: JxlEndianness, value: u16) void {
	const actual = switch (endianness) {
		.JXL_NATIVE_ENDIAN => if (builtinEndian() == .little) JxlEndianness.JXL_LITTLE_ENDIAN else JxlEndianness.JXL_BIG_ENDIAN,
		else => endianness,
	};
	var raw: [2]u8 = undefined;
	switch (actual) {
		.JXL_LITTLE_ENDIAN => byte_order.storeLE16(value, &raw),
		.JXL_BIG_ENDIAN => byte_order.storeBE16(value, &raw),
		else => unreachable,
	}
	@memcpy(dst[0..2], &raw);
}

fn storeU32(dst: []u8, endianness: JxlEndianness, value: u32) void {
	const actual = switch (endianness) {
		.JXL_NATIVE_ENDIAN => if (builtinEndian() == .little) JxlEndianness.JXL_LITTLE_ENDIAN else JxlEndianness.JXL_BIG_ENDIAN,
		else => endianness,
	};
	var raw: [4]u8 = undefined;
	switch (actual) {
		.JXL_LITTLE_ENDIAN => byte_order.storeLE32(value, &raw),
		.JXL_BIG_ENDIAN => byte_order.storeBE32(value, &raw),
		else => unreachable,
	}
	@memcpy(dst[0..4], &raw);
}

fn builtinEndian() std.builtin.Endian {
	return @import("builtin").target.cpu.arch.endian();
}

fn clampU32(value: i32, max_value: u32) u32 {
	if (value <= 0) return 0;
	const unsigned: u32 = @intCast(value);
	return @min(unsigned, max_value);
}

fn normalizedFloat(value: i32, max_value: u32) f32 {
	if (max_value == 0) return 0.0;
	return @as(f32, @floatFromInt(clampU32(value, max_value))) / @as(f32, @floatFromInt(max_value));
}

fn scaleToU8(value: i32, max_value: u32) u8 {
	if (max_value == 0) return 0;
	const clamped = clampU32(value, max_value);
	if (max_value == 255) return @intCast(clamped);
	return @intCast((@as(u64, clamped) * 255 + max_value / 2) / max_value);
}

fn outputValue(img: *const Image, metadata: *const image_metadata.ImageMetadata, color_channels: usize, x: usize, y: usize, requested_channel: usize) i32 {
	const alpha_idx = alphaChannelIndex(metadata);

	if (color_channels == 1) {
		const gray = img.channels.items[0].rowConst(y)[x];
		return switch (requested_channel) {
			0 => gray,
			1, 3 => if (alpha_idx) |idx| img.channels.items[color_channels + idx].rowConst(y)[x] else @intCast(bitDepthMax(metadata.bit_depth.bits_per_sample)),
			2 => gray,
			else => 0,
		};
	}

	return switch (requested_channel) {
		0, 1, 2 => img.channels.items[requested_channel].rowConst(y)[x],
		3 => if (alpha_idx) |idx| img.channels.items[color_channels + idx].rowConst(y)[x] else @intCast(bitDepthMax(metadata.bit_depth.bits_per_sample)),
		else => 0,
	};
}

/// Writes the decoded planar modular image into the caller-owned interleaved
/// pixel buffer described by JxlPixelFormat, including row alignment handling.
fn writeImageToOutput(img: *const Image, metadata: *const image_metadata.ImageMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	const color_channels = metadata.color_encoding.channels();
	if (!(color_channels == 1 or color_channels == 3)) return error.Unsupported;

	if (color_channels == 3 and !(format.num_channels == 3 or format.num_channels == 4)) return error.Unsupported;
	if (color_channels == 1 and !(format.num_channels == 1 or format.num_channels == 2 or format.num_channels == 3 or format.num_channels == 4)) return error.Unsupported;

	const stride = rowStrideBytes(img.w, format) orelse return error.Unsupported;
	if (stride * img.h > buffer_size) return error.GenericError;

	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return error.Unsupported;
	const max_value = bitDepthMax(metadata.bit_depth.bits_per_sample);

	if (format.data_type == .JXL_TYPE_UINT8 and format.num_channels == 3) {
		if (color_channels == 3) {
			for (0..img.h) |y| {
				const dst = buffer[y * stride .. y * stride + img.w * 3];
				const row_r = img.channels.items[0].rowConst(y);
				const row_g = img.channels.items[1].rowConst(y);
				const row_b = img.channels.items[2].rowConst(y);
				for (0..img.w) |x| {
					dst[x * 3 + 0] = scaleToU8(row_r[x], max_value);
					dst[x * 3 + 1] = scaleToU8(row_g[x], max_value);
					dst[x * 3 + 2] = scaleToU8(row_b[x], max_value);
				}
			}
			return;
		}
		if (color_channels == 1) {
			for (0..img.h) |y| {
				const dst = buffer[y * stride .. y * stride + img.w * 3];
				const row_gray = img.channels.items[0].rowConst(y);
				for (0..img.w) |x| {
					const gray = scaleToU8(row_gray[x], max_value);
					dst[x * 3 + 0] = gray;
					dst[x * 3 + 1] = gray;
					dst[x * 3 + 2] = gray;
				}
			}
			return;
		}
	}

	if (format.data_type == .JXL_TYPE_UINT8 and format.num_channels == 1 and color_channels == 1) {
		for (0..img.h) |y| {
			const dst = buffer[y * stride .. y * stride + img.w];
			const row_gray = img.channels.items[0].rowConst(y);
			for (0..img.w) |x| {
				dst[x] = scaleToU8(row_gray[x], max_value);
			}
		}
		return;
	}

	for (0..img.h) |y| {
		const row = buffer[y * stride .. y * stride + stride];
		for (0..img.w) |x| {
			const pixel = row[x * format.num_channels * bytes_per_channel ..];
			for (0..format.num_channels) |c| {
				const value = outputValue(img, metadata, color_channels, x, y, c);
				switch (format.data_type) {
					.JXL_TYPE_UINT8 => {
						pixel[c] = scaleToU8(value, max_value);
					},
					.JXL_TYPE_UINT16 => {
						const scaled = if (max_value == 0) 0 else @as(u32, @intFromFloat(@round(normalizedFloat(value, max_value) * 65535.0)));
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, @intCast(scaled));
					},
					.JXL_TYPE_FLOAT => {
						const raw: u32 = @bitCast(normalizedFloat(value, max_value));
						storeU32(pixel[c * 4 .. c * 4 + 4], format.endianness, raw);
					},
					.JXL_TYPE_FLOAT16 => {
						const half: f16 = @floatCast(normalizedFloat(value, max_value));
						const raw: u16 = @bitCast(half);
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, raw);
					},
				}
			}
		}
	}
}

fn populateBasicInfo(metadata: *const image_metadata.CodecMetadata) JxlBasicInfo {
	var info = std.mem.zeroes(JxlBasicInfo);
	info.have_container = 0;
	info.xsize = @intCast(metadata.size.xsize());
	info.ysize = @intCast(metadata.size.ysize());
	info.bits_per_sample = metadata.m.bit_depth.bits_per_sample;
	info.exponent_bits_per_sample = metadata.m.bit_depth.exponent_bits_per_sample;
	info.intensity_target = metadata.m.tone_mapping.intensity_target;
	info.min_nits = metadata.m.tone_mapping.min_nits;
	info.relative_to_max_display = @intFromBool(metadata.m.tone_mapping.relative_to_max_display);
	info.linear_below = metadata.m.tone_mapping.linear_below;
	info.uses_original_profile = @intFromBool(!metadata.m.xyb_encoded);
	info.have_preview = @intFromBool(metadata.m.have_preview);
	info.have_animation = @intFromBool(metadata.m.have_animation);
	info.orientation = @enumFromInt(metadata.m.orientation);
	info.num_color_channels = @intCast(metadata.m.color_encoding.channels());
	info.num_extra_channels = metadata.m.num_extra_channels;
	info.preview = .{
		.xsize = @intCast(metadata.m.preview_size.xsize()),
		.ysize = @intCast(metadata.m.preview_size.ysize()),
	};
	info.animation = .{
		.tps_numerator = metadata.m.animation.tps_numerator,
		.tps_denominator = metadata.m.animation.tps_denominator,
		.num_loops = metadata.m.animation.num_loops,
		.have_timecodes = @intFromBool(metadata.m.animation.have_timecodes),
	};
	if (metadata.m.have_intrinsic_size) {
		info.intrinsic_xsize = @intCast(metadata.m.intrinsic_size.xsize());
		info.intrinsic_ysize = @intCast(metadata.m.intrinsic_size.ysize());
	}
	if (alphaChannelIndex(&metadata.m)) |alpha_idx| {
		const alpha = metadata.m.extra_channel_info[alpha_idx];
		info.alpha_bits = alpha.bit_depth.bits_per_sample;
		info.alpha_exponent_bits = alpha.bit_depth.exponent_bits_per_sample;
		info.alpha_premultiplied = @intFromBool(alpha.alpha_associated);
	}
	return info;
}

/// Parses the codestream headers once and caches the frame slice so the
/// compatibility-layer state machine can emit basic-info and full-image events
/// without duplicating decode logic.
fn ensureParsed(dec: *DecoderImpl) JxlDecoderStatus {
	if (dec.basic_info_available) return .JXL_DEC_SUCCESS;

	const input = dec.inputSlice();
	switch (JxlSignatureCheck(if (input.len == 0) null else input.ptr, input.len)) {
		.JXL_SIG_NOT_ENOUGH_BYTES => return if (dec.input_closed) .JXL_DEC_ERROR else .JXL_DEC_NEED_MORE_INPUT,
		.JXL_SIG_INVALID, .JXL_SIG_CONTAINER => return .JXL_DEC_ERROR,
		.JXL_SIG_CODESTREAM => {},
	}

	var br = BitReader.init(input[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = image_metadata.ImageMetadata.readFromBitStream(&br) catch |err| return statusFromError(err, dec.input_closed);
	const transform_data = image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded) catch |err| return statusFromError(err, dec.input_closed);
	br.jumpToByteBoundary() catch |err| return statusFromError(err, dec.input_closed);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.m = metadata;
	codec_meta.size = size;
	codec_meta.transform_data = transform_data;

	const frame_header_byte_offset = br.totalBitsConsumed() / 8;
	br.close() catch |err| return statusFromError(err, dec.input_closed);

	dec.codec_meta = codec_meta;
	dec.frame_data = input[2 + frame_header_byte_offset ..];
	dec.basic_info = populateBasicInfo(&codec_meta);
	dec.basic_info_available = true;
	return .JXL_DEC_SUCCESS;
}

fn ensureDecoded(dec: *DecoderImpl) JxlDecoderStatus {
	if (dec.decode_complete) return .JXL_DEC_SUCCESS;
	if (!dec.basic_info_available) {
		const parse_status = ensureParsed(dec);
		if (parse_status != .JXL_DEC_SUCCESS) return parse_status;
	}
	if (dec.output_buffer == null) return .JXL_DEC_NEED_IMAGE_OUT_BUFFER;

	var frame_dec = dec_frame.FrameDecoder.init(std.heap.c_allocator, &dec.codec_meta);
	defer frame_dec.deinit();
	frame_dec.decodeFrame(dec.frame_data) catch return .JXL_DEC_ERROR;

	writeImageToOutput(frame_dec.getDecodedImage(), &dec.codec_meta.m, dec.output_format, dec.output_buffer.?, dec.output_buffer_size) catch return .JXL_DEC_ERROR;
	dec.decode_complete = true;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderVersion() u32 {
	return decoderVersion();
}

pub export fn JxlSignatureCheck(buf: ?[*]const u8, len: usize) JxlSignature {
	if (len < 2) return .JXL_SIG_NOT_ENOUGH_BYTES;
	const data = buf orelse return .JXL_SIG_INVALID;
	if (data[0] == 0xFF and data[1] == 0x0A) return .JXL_SIG_CODESTREAM;
	if (len < container_signature.len) return .JXL_SIG_NOT_ENOUGH_BYTES;
	if (std.mem.eql(u8, data[0..container_signature.len], &container_signature)) return .JXL_SIG_CONTAINER;
	return .JXL_SIG_INVALID;
}

pub export fn JxlDecoderCreate(memory_manager: ?*const JxlMemoryManager) ?*JxlDecoder {
	const dec = allocDecoder(memory_manager) orelse return null;
	return @ptrCast(dec);
}

pub export fn JxlDecoderReset(dec_ptr: ?*JxlDecoder) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	const mm = impl.memory_manager;
	impl.* = .{};
	impl.memory_manager = mm;
}

pub export fn JxlDecoderDestroy(dec_ptr: ?*JxlDecoder) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	freeDecoder(impl);
}

pub export fn JxlDecoderSetParallelRunner(dec_ptr: ?*JxlDecoder, _: ?JxlParallelRunner, _: ?*anyopaque) JxlDecoderStatus {
	_ = dec_ptr orelse return .JXL_DEC_ERROR;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSizeHintBasicInfo(dec_ptr: ?*const JxlDecoder) usize {
	const dec = dec_ptr orelse return 0;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.basic_info_available) return 0;
	if (impl.input_size >= 64) return 0;
	return 64 - impl.input_size;
}

pub export fn JxlDecoderSubscribeEvents(dec_ptr: ?*JxlDecoder, events_wanted: c_int) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.started_processing) return .JXL_DEC_ERROR;
	impl.subscribed_events = events_wanted;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetKeepOrientation(dec_ptr: ?*JxlDecoder, skip_reorientation: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.started_processing) return .JXL_DEC_ERROR;
	impl.keep_orientation = skip_reorientation != 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetUnpremultiplyAlpha(dec_ptr: ?*JxlDecoder, unpremul_alpha: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.started_processing) return .JXL_DEC_ERROR;
	impl.unpremultiply_alpha = unpremul_alpha != 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetRenderSpotcolors(dec_ptr: ?*JxlDecoder, render_spotcolors: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.started_processing) return .JXL_DEC_ERROR;
	impl.render_spotcolors = render_spotcolors != 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetCoalescing(dec_ptr: ?*JxlDecoder, coalescing: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.started_processing) return .JXL_DEC_ERROR;
	impl.coalescing = coalescing != 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetInput(dec_ptr: ?*JxlDecoder, data: ?[*]const u8, size: usize) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.input_data != null and !impl.input_released) return .JXL_DEC_ERROR;
	if (impl.input_closed) return .JXL_DEC_ERROR;
	if (size != 0 and data == null) return .JXL_DEC_ERROR;
	impl.input_data = data;
	impl.input_size = size;
	impl.input_released = false;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderReleaseInput(dec_ptr: ?*JxlDecoder) usize {
	const dec = dec_ptr orelse return 0;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.input_data = null;
	impl.input_size = 0;
	impl.input_released = true;
	return 0;
}

pub export fn JxlDecoderCloseInput(dec_ptr: ?*JxlDecoder) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.input_closed = true;
}

pub export fn JxlDecoderGetBasicInfo(dec_ptr: ?*const JxlDecoder, info: ?*JxlBasicInfo) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;
	if (info) |dst| dst.* = impl.basic_info;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderImageOutBufferSize(dec_ptr: ?*const JxlDecoder, format: ?*const JxlPixelFormat, size: ?*usize) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	const pixel_format = format orelse return .JXL_DEC_ERROR;
	const out_size = size orelse return .JXL_DEC_ERROR;
	if (!impl.basic_info_available) return .JXL_DEC_ERROR;
	const stride = rowStrideBytes(impl.basic_info.xsize, pixel_format.*) orelse return .JXL_DEC_ERROR;
	out_size.* = stride * impl.basic_info.ysize;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderSetImageOutBuffer(dec_ptr: ?*JxlDecoder, format: ?*const JxlPixelFormat, buffer: ?*anyopaque, size: usize) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	const pixel_format = format orelse return .JXL_DEC_ERROR;
	if (buffer == null) return .JXL_DEC_ERROR;
	var needed: usize = 0;
	if (JxlDecoderImageOutBufferSize(dec_ptr, format, &needed) != .JXL_DEC_SUCCESS) return .JXL_DEC_ERROR;
	if (size < needed) return .JXL_DEC_ERROR;
	impl.output_format = pixel_format.*;
	impl.output_buffer = @ptrCast(buffer);
	impl.output_buffer_size = size;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderProcessInput(dec_ptr: ?*JxlDecoder) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.started_processing = true;

	if (impl.input_data == null and impl.input_size == 0) return .JXL_DEC_NEED_MORE_INPUT;

	const parse_status = ensureParsed(impl);
	if (parse_status != .JXL_DEC_SUCCESS) return parse_status;

	if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO)) != 0 and !impl.basic_info_emitted) {
		impl.basic_info_emitted = true;
		return .JXL_DEC_BASIC_INFO;
	}

	if (impl.output_buffer == null) return .JXL_DEC_NEED_IMAGE_OUT_BUFFER;

	const decode_status = ensureDecoded(impl);
	if (decode_status != .JXL_DEC_SUCCESS) return decode_status;

	if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE)) != 0 and !impl.full_image_emitted) {
		impl.full_image_emitted = true;
		return .JXL_DEC_FULL_IMAGE;
	}

	return .JXL_DEC_SUCCESS;
}

pub export fn JxlEncoderVersion() u32 {
	return encoderVersion();
}

pub export fn JxlEncoderCreate(memory_manager: ?*const JxlMemoryManager) ?*JxlEncoder {
	const enc = allocEncoder(memory_manager) orelse return null;
	return @ptrCast(enc);
}

pub export fn JxlEncoderReset(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const mm = impl.memory_manager;
	freeEncoderState(impl);
	impl.* = .{};
	impl.memory_manager = mm;
}

pub export fn JxlEncoderDestroy(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	freeEncoder(impl);
}

pub export fn JxlEncoderFrameSettingsCreate(enc_ptr: ?*JxlEncoder, source_ptr: ?*const JxlEncoderFrameSettings) ?*JxlEncoderFrameSettings {
	const enc = enc_ptr orelse return null;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	if (source_ptr) |source| {
		const source_impl: *const EncoderFrameSettingsImpl = @ptrCast(@alignCast(source));
		if (source_impl.owner != impl) return null;
	}

	const settings = std.heap.c_allocator.create(EncoderFrameSettingsImpl) catch return null;
	errdefer std.heap.c_allocator.destroy(settings);
	settings.* = .{ .owner = impl };
	impl.frame_settings.append(std.heap.c_allocator, settings) catch return null;
	return @ptrCast(settings);
}

pub export fn JxlEncoderInitBasicInfo(info: ?*JxlBasicInfo) void {
	const dst = info orelse return;
	dst.* = defaultBasicInfo();
}

pub export fn JxlEncoderInitExtraChannelInfo(extra_type: JxlExtraChannelType, info: ?*JxlExtraChannelInfo) void {
	const dst = info orelse return;
	dst.* = std.mem.zeroes(JxlExtraChannelInfo);
	dst.type = extra_type;
	dst.bits_per_sample = 8;
}

pub export fn JxlColorEncodingSetToSRGB(color_encoding: ?*JxlColorEncoding, is_gray: JXL_BOOL) void {
	const color = color_encoding orelse return;
	color.* = defaultJxlColorEncoding(is_gray != 0, false);
}

pub export fn JxlColorEncodingSetToLinearSRGB(color_encoding: ?*JxlColorEncoding, is_gray: JXL_BOOL) void {
	const color = color_encoding orelse return;
	color.* = defaultJxlColorEncoding(is_gray != 0, true);
}

pub export fn JxlEncoderSetBasicInfo(enc_ptr: ?*JxlEncoder, info: ?*const JxlBasicInfo) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const src = info orelse return .JXL_ENC_ERROR;
	if (impl.started_processing or impl.added_frame) return .JXL_ENC_ERROR;
	validateBasicInfoForSimpleEncode(src) catch return .JXL_ENC_ERROR;
	impl.basic_info = src.*;
	impl.basic_info_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetColorEncoding(enc_ptr: ?*JxlEncoder, color_ptr: ?*const JxlColorEncoding) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const color = color_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame) return .JXL_ENC_ERROR;
	const internal = toInternalColorEncoding(color, impl.basic_info.num_color_channels) catch return .JXL_ENC_ERROR;
	impl.color_encoding = color.*;
	impl.internal_color_encoding = internal;
	impl.color_encoding_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetExtraChannelInfo(
	enc_ptr: ?*JxlEncoder,
	index: usize,
	info_ptr: ?*const JxlExtraChannelInfo,
) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const info = info_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame) return .JXL_ENC_ERROR;
	if (index >= impl.basic_info.num_extra_channels) return .JXL_ENC_ERROR;
	validateExtraChannelInfoForSimpleEncode(&impl.basic_info, index, info) catch return .JXL_ENC_ERROR;

	const pending = &impl.pending_extra_channels[index];
	pending.info = info.*;
	pending.info_set = true;
	pending.info.name_length = @intCast(pending.name_len);
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetExtraChannelName(
	enc_ptr: ?*JxlEncoder,
	index: usize,
	name_ptr: ?[*]const u8,
	size: usize,
) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame) return .JXL_ENC_ERROR;
	if (index >= impl.basic_info.num_extra_channels or size > 1071) return .JXL_ENC_ERROR;
	const pending = &impl.pending_extra_channels[index];
	if (!pending.info_set) return .JXL_ENC_ERROR;
	if (size == 0) {
		pending.name_len = 0;
		pending.info.name_length = 0;
		return .JXL_ENC_SUCCESS;
	}
	const name = name_ptr orelse return .JXL_ENC_ERROR;
	@memcpy(pending.name_buf[0..size], name[0..size]);
	pending.name_len = size;
	pending.info.name_length = @intCast(size);
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderAddImageFrame(
	frame_settings_ptr: ?*const JxlEncoderFrameSettings,
	format_ptr: ?*const JxlPixelFormat,
	buffer: ?*const anyopaque,
	size: usize,
) JxlEncoderStatus {
	const frame_settings = frame_settings_ptr orelse return .JXL_ENC_ERROR;
	const settings_impl: *const EncoderFrameSettingsImpl = @ptrCast(@alignCast(frame_settings));
	const impl = settings_impl.owner;
	const format = format_ptr orelse return .JXL_ENC_ERROR;
	const data = buffer orelse return .JXL_ENC_ERROR;

	if (!impl.basic_info_set or !impl.color_encoding_set or impl.added_frame or impl.started_processing) return .JXL_ENC_ERROR;
	if (format.data_type != .JXL_TYPE_UINT8) return .JXL_ENC_ERROR;

	const expected_channels = if (impl.basic_info.alpha_bits != 0)
		impl.basic_info.num_color_channels + 1
	else
		impl.basic_info.num_color_channels;
	if (format.num_channels != expected_channels) return .JXL_ENC_ERROR;

	const stride = rowStrideBytes(impl.basic_info.xsize, format.*) orelse return .JXL_ENC_ERROR;
	const needed = stride * impl.basic_info.ysize;
	if (size < needed) return .JXL_ENC_ERROR;

	clearPendingFrameBuffers(impl);
	const pixels: [*]const u8 = @ptrCast(data);
	impl.image_bytes = std.heap.c_allocator.dupe(u8, pixels[0..needed]) catch return .JXL_ENC_ERROR;
	impl.image_format = format.*;
	impl.added_frame = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetExtraChannelBuffer(
	frame_settings_ptr: ?*const JxlEncoderFrameSettings,
	format_ptr: ?*const JxlPixelFormat,
	buffer: ?*const anyopaque,
	size: usize,
	index: u32,
) JxlEncoderStatus {
	const frame_settings = frame_settings_ptr orelse return .JXL_ENC_ERROR;
	const settings_impl: *const EncoderFrameSettingsImpl = @ptrCast(@alignCast(frame_settings));
	const impl = settings_impl.owner;
	const format = format_ptr orelse return .JXL_ENC_ERROR;
	const data = buffer orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or !impl.color_encoding_set or !impl.added_frame or impl.started_processing) return .JXL_ENC_ERROR;
	if (index >= impl.basic_info.num_extra_channels) return .JXL_ENC_ERROR;
	if (impl.basic_info.alpha_bits != 0 and index == 0) return .JXL_ENC_ERROR;

	const pending = &impl.pending_extra_channels[index];
	if (!pending.info_set) return .JXL_ENC_ERROR;
	if (format.data_type != .JXL_TYPE_UINT8) return .JXL_ENC_ERROR;

	var extra_format = format.*;
	extra_format.num_channels = 1;
	const stride = rowStrideBytes(impl.basic_info.xsize, extra_format) orelse return .JXL_ENC_ERROR;
	const needed = stride * impl.basic_info.ysize;
	if (size < needed) return .JXL_ENC_ERROR;

	if (pending.buffer.len != 0) {
		std.heap.c_allocator.free(pending.buffer);
		pending.buffer = &.{};
	}
	const bytes: [*]const u8 = @ptrCast(data);
	pending.buffer = std.heap.c_allocator.dupe(u8, bytes[0..needed]) catch return .JXL_ENC_ERROR;
	pending.row_stride = stride;
	pending.buffer_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderCloseInput(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	impl.input_closed = true;
}

pub export fn JxlEncoderProcessOutput(enc_ptr: ?*JxlEncoder, next_out_ptr: ?*[*]u8, avail_out_ptr: ?*usize) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const next_out = next_out_ptr orelse return .JXL_ENC_ERROR;
	const avail_out = avail_out_ptr orelse return .JXL_ENC_ERROR;
	impl.started_processing = true;

	if (!impl.input_closed or !impl.added_frame) return .JXL_ENC_ERROR;
	if (impl.encoded_bytes.len == 0) {
		finalizeSimpleEncode(impl) catch return .JXL_ENC_ERROR;
	}
	if (impl.output_offset >= impl.encoded_bytes.len) return .JXL_ENC_SUCCESS;
	if (avail_out.* == 0) return .JXL_ENC_NEED_MORE_OUTPUT;

	const remaining = impl.encoded_bytes.len - impl.output_offset;
	const to_copy = @min(remaining, avail_out.*);
	@memcpy(next_out.*[0..to_copy], impl.encoded_bytes[impl.output_offset .. impl.output_offset + to_copy]);
	impl.output_offset += to_copy;
	next_out.* += to_copy;
	avail_out.* -= to_copy;

	return if (impl.output_offset >= impl.encoded_bytes.len)
		.JXL_ENC_SUCCESS
	else
		.JXL_ENC_NEED_MORE_OUTPUT;
}

test "JxlSignatureCheck identifies codestream and container" {
	const codestream = [_]u8{ 0xFF, 0x0A };
	try std.testing.expectEqual(JxlSignature.JXL_SIG_CODESTREAM, JxlSignatureCheck(&codestream, codestream.len));
	try std.testing.expectEqual(JxlSignature.JXL_SIG_CONTAINER, JxlSignatureCheck(&container_signature, container_signature.len));
	try std.testing.expectEqual(JxlSignature.JXL_SIG_NOT_ENOUGH_BYTES, JxlSignatureCheck(&codestream, 1));
}

test "rowStrideBytes respects requested alignment" {
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT16,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 8,
	};
	try std.testing.expectEqual(@as(?usize, 16), rowStrideBytes(2, format));
}

test "writeImageToOutput writes RGB uint8 interleaved rows" {
	const allocator = std.testing.allocator;
	var img = try Image.create(allocator, 2, 1, 8, 3);
	defer img.deinit();

	img.channels.items[0].row(0)[0] = 1;
	img.channels.items[0].row(0)[1] = 4;
	img.channels.items[1].row(0)[0] = 2;
	img.channels.items[1].row(0)[1] = 5;
	img.channels.items[2].row(0)[0] = 3;
	img.channels.items[2].row(0)[1] = 6;

	var metadata = image_metadata.ImageMetadata{};
	metadata.bit_depth.bits_per_sample = 8;
	metadata.color_encoding.color_space = .rgb;

	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	var buffer: [6]u8 = undefined;
	try writeImageToOutput(&img, &metadata, format, buffer[0..].ptr, buffer.len);
	try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &buffer);
}

test "writeImageToOutput scales grayscale to uint8 rgb" {
	const allocator = std.testing.allocator;
	var img = try Image.create(allocator, 3, 1, 10, 1);
	defer img.deinit();

	img.channels.items[0].row(0)[0] = 0;
	img.channels.items[0].row(0)[1] = 512;
	img.channels.items[0].row(0)[2] = 1023;

	var metadata = image_metadata.ImageMetadata{};
	metadata.bit_depth.bits_per_sample = 10;
	metadata.color_encoding.color_space = .gray;

	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	var buffer: [9]u8 = undefined;
	try writeImageToOutput(&img, &metadata, format, buffer[0..].ptr, buffer.len);
	try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 128, 128, 128, 255, 255, 255 }, &buffer);
}

test "JxlEncoder encodes a selection-mask extra channel buffer" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var extra = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SELECTION_MASK, &extra);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &extra));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 0, "mask".ptr, 4));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgb_pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels, rgb_pixels.len),
	);

	const mask_pixels = [_]u8{
		0, 255,
		255, 0,
	};
	const mask_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &mask_format, &mask_pixels, mask_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .{};
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [32]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_count);
	try testing.expectEqual(image_metadata.ExtraChannel.selection_mask, metadata.extra_channel_info[0].type);
	try testing.expectEqualStrings("mask", metadata.extra_channel_info[0].name);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded.items[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 4), image.channels.items.len);
	try testing.expectEqualSlices(i32, &.{ 0, 255, 255, 0 }, image.channels.items[3].data);
}

test "JxlEncoder encodes multiple non-alpha extra channel buffers" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 2;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var selection_mask = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SELECTION_MASK, &selection_mask);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &selection_mask));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 0, "mask".ptr, 4));

	var thermal = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_THERMAL, &thermal);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 1, &thermal));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 1, "heat".ptr, 4));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgb_pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels, rgb_pixels.len),
	);

	const mask_pixels = [_]u8{
		0, 255,
		255, 0,
	};
	const heat_pixels = [_]u8{
		1, 2,
		3, 4,
	};
	const extra_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &extra_format, &mask_pixels, mask_pixels.len, 0),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &extra_format, &heat_pixels, heat_pixels.len, 1),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .{};
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [32]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(u32, 2), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.selection_mask, metadata.extra_channel_info[0].type);
	try testing.expectEqualStrings("mask", metadata.extra_channel_info[0].name);
	try testing.expectEqual(image_metadata.ExtraChannel.thermal, metadata.extra_channel_info[1].type);
	try testing.expectEqualStrings("heat", metadata.extra_channel_info[1].name);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded.items[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 5), image.channels.items.len);
	try testing.expectEqualSlices(i32, &.{ 0, 255, 255, 0 }, image.channels.items[3].data);
	try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, image.channels.items[4].data);
}

test "JxlEncoder encodes interleaved alpha plus a sidecar extra channel" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 2;
	info.alpha_bits = 8;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var selection_mask = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SELECTION_MASK, &selection_mask);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 1, &selection_mask));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 1, "mask".ptr, 4));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgba_pixels = [_]u8{
		0, 10, 20, 255, 30, 40, 50, 128,
		60, 70, 80, 64, 90, 100, 110, 0,
	};
	const rgba_format = JxlPixelFormat{
		.num_channels = 4,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgba_format, &rgba_pixels, rgba_pixels.len),
	);

	const mask_pixels = [_]u8{
		0, 255,
		255, 0,
	};
	const mask_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &mask_format, &mask_pixels, mask_pixels.len, 1),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .{};
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [32]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(u32, 2), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.alpha, metadata.extra_channel_info[0].type);
	try testing.expectEqual(image_metadata.ExtraChannel.selection_mask, metadata.extra_channel_info[1].type);
	try testing.expectEqualStrings("mask", metadata.extra_channel_info[1].name);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded.items[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 5), image.channels.items.len);
	try testing.expectEqualSlices(i32, &.{ 255, 128, 64, 0 }, image.channels.items[3].data);
	try testing.expectEqualSlices(i32, &.{ 0, 255, 255, 0 }, image.channels.items[4].data);
}

test "JxlEncoder encodes a spot-color extra channel buffer" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var spot = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SPOT_COLOR, &spot);
	spot.spot_color = .{ 0.25, 0.5, 0.75, 1.0 };
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &spot));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 0, "spot".ptr, 4));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgb_pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels, rgb_pixels.len),
	);

	const spot_pixels = [_]u8{
		10, 20,
		30, 40,
	};
	const spot_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &spot_format, &spot_pixels, spot_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .{};
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [32]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.spot_color, metadata.extra_channel_info[0].type);
	try testing.expectEqualStrings("spot", metadata.extra_channel_info[0].name);
	try testing.expectApproxEqAbs(@as(f32, 0.25), metadata.extra_channel_info[0].spot_color[0], 0.001);
	try testing.expectApproxEqAbs(@as(f32, 0.5), metadata.extra_channel_info[0].spot_color[1], 0.001);
	try testing.expectApproxEqAbs(@as(f32, 0.75), metadata.extra_channel_info[0].spot_color[2], 0.001);
	try testing.expectApproxEqAbs(@as(f32, 1.0), metadata.extra_channel_info[0].spot_color[3], 0.001);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded.items[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 4), image.channels.items.len);
	try testing.expectEqualSlices(i32, &.{ 10, 20, 30, 40 }, image.channels.items[3].data);
}
