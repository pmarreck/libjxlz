const std = @import("std");

const common = @import("lib/base/common.zig");
const byte_order = @import("lib/base/byte_order.zig");
const BitReader = @import("lib/base/bit_reader.zig").BitReader;
const JxlError = @import("lib/base/status.zig").JxlError;
const headers = @import("lib/codec/headers.zig");
const color_encoding_mod = @import("lib/codec/color_encoding.zig");
const icc_codec = @import("lib/codec/icc_codec.zig");
const icc_profiles = @import("lib/codec/icc_profiles.zig");
const icc_test_fixtures = @import("lib/codec/icc_test_fixtures.zig");
const image_metadata = @import("lib/codec/image_metadata.zig");
const container_mod = @import("lib/codec/container.zig");
const brotli = @import("lib/base/brotli.zig");
const frame_header_mod = @import("lib/codec/frame_header.zig");
const dec_frame = @import("lib/codec/dec_frame.zig");
const render_mod = @import("lib/codec/render.zig");
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

pub const JxlBlendMode = enum(c_int) {
	JXL_BLEND_REPLACE = 0,
	JXL_BLEND_ADD = 1,
	JXL_BLEND_BLEND = 2,
	JXL_BLEND_MULADD = 3,
	JXL_BLEND_MUL = 4,
};

pub const JxlBlendInfo = extern struct {
	blendmode: JxlBlendMode,
	source: u32,
	alpha: u32,
	clamp: JXL_BOOL,
};

pub const JxlLayerInfo = extern struct {
	have_crop: JXL_BOOL,
	crop_x0: i32,
	crop_y0: i32,
	xsize: u32,
	ysize: u32,
	blend_info: JxlBlendInfo,
	save_as_reference: u32,
};

pub const JxlFrameHeader = extern struct {
	duration: u32,
	timecode: u32,
	name_length: u32,
	is_last: JXL_BOOL,
	layer_info: JxlLayerInfo,
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
	JXL_DEC_BOX = 0x4000,
	JXL_DEC_BOX_COMPLETE = 0x10000,
};

pub const JxlBoxType = [4]u8;

pub const JxlColorProfileTarget = enum(c_int) {
	JXL_COLOR_PROFILE_TARGET_ORIGINAL = 0,
	JXL_COLOR_PROFILE_TARGET_DATA = 1,
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
	color_encoding_emitted: bool = false,
	basic_info: JxlBasicInfo = std.mem.zeroes(JxlBasicInfo),
	input_is_container: bool = false,
	owned_codestream: []u8 = &.{},
	owned_icc: []u8 = &.{},
	owned_boxes: []container_mod.OwnedBox = &.{},
	box_index: usize = 0,
	box_header_emitted: bool = false,
	box_bytes_emitted: usize = 0,
	box_complete_emitted: bool = false,
	decompress_boxes: bool = false,
	box_buffer: ?[*]u8 = null,
	box_buffer_size: usize = 0,
	box_buffer_written: usize = 0,
	codec_meta: image_metadata.CodecMetadata = .{},
	frame_data: []const u8 = &.{},
	frame_offset: usize = 0,
	frame_size: usize = 0,
	frame_parsed: bool = false,
	frame_emitted: bool = false,
	frame_decoded: bool = false,
	frame_name_len: usize = 0,
	frame_name_buf: [1071]u8 = [_]u8{0} ** 1071,
	frame_header: JxlFrameHeader = std.mem.zeroes(JxlFrameHeader),
	frames_to_skip: usize = 0,

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
	use_boxes: bool = false,
	boxes_closed: bool = false,
	added_frame: bool = false,
	frames_closed: bool = false,
	input_closed: bool = false,
	started_processing: bool = false,
	basic_info: JxlBasicInfo = std.mem.zeroes(JxlBasicInfo),
	color_encoding: JxlColorEncoding = undefined,
	encoded_bytes: []u8 = &.{},
	owned_icc: []u8 = &.{},
	output_offset: usize = 0,
	frame_settings: std.ArrayListUnmanaged(*EncoderFrameSettingsImpl) = .empty,
	queued_frames: std.ArrayListUnmanaged(EncoderQueuedFrame) = .empty,
	staged_boxes: std.ArrayListUnmanaged(EncoderPendingBox) = .empty,
	internal_color_encoding: ?color_encoding_mod.ColorEncoding = null,
	image_format: JxlPixelFormat = .{
		.num_channels = 0,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	},
	image_bytes: []u8 = &.{},
	pending_frame_header_set: bool = false,
	pending_frame_header: JxlFrameHeader = std.mem.zeroes(JxlFrameHeader),
	pending_extra_channels: [256]EncoderPendingExtraChannel = [_]EncoderPendingExtraChannel{.{}} ** 256,
};

const EncoderFrameSettingsImpl = struct {
	owner: *EncoderImpl,
	frame_header_set: bool = false,
	frame_header: JxlFrameHeader = std.mem.zeroes(JxlFrameHeader),
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

const EncoderPendingBox = struct {
	box_type: [4]u8,
	contents: []u8 = &.{},

	fn deinit(self: *EncoderPendingBox) void {
		if (self.contents.len != 0) std.heap.c_allocator.free(self.contents);
		self.contents = &.{};
	}
};

const EncoderQueuedPlaneBuffer = struct {
	buffer: []u8 = &.{},
	row_stride: usize = 0,
	buffer_set: bool = false,
};

const EncoderQueuedFrame = struct {
	image_format: JxlPixelFormat = .{
		.num_channels = 0,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	},
	image_bytes: []u8 = &.{},
	frame_header_set: bool = false,
	frame_header: JxlFrameHeader = std.mem.zeroes(JxlFrameHeader),
	extra_buffers: [256]EncoderQueuedPlaneBuffer = [_]EncoderQueuedPlaneBuffer{.{}} ** 256,

	fn deinit(self: *EncoderQueuedFrame) void {
		if (self.image_bytes.len != 0) {
			std.heap.c_allocator.free(self.image_bytes);
		}
		for (&self.extra_buffers) |*plane| {
			if (plane.buffer.len != 0) {
				std.heap.c_allocator.free(plane.buffer);
			}
		}
		self.* = .{};
	}
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
	if (dec.owned_codestream.len != 0) {
		std.heap.c_allocator.free(dec.owned_codestream);
		dec.owned_codestream = &.{};
	}
	if (dec.owned_icc.len != 0) {
		std.heap.c_allocator.free(dec.owned_icc);
		dec.owned_icc = &.{};
	}
	if (dec.owned_boxes.len != 0) {
		for (dec.owned_boxes) |*box| box.deinit(std.heap.c_allocator);
		std.heap.c_allocator.free(dec.owned_boxes);
		dec.owned_boxes = &.{};
	}
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

/// Validates the optional C memory-manager pair so public buffer-returning APIs
/// can share the same ownership rules as the encoder/decoder constructors.
fn validateMemoryManager(mm: ?*const JxlMemoryManager) bool {
	if (mm) |manager| {
		if ((manager.alloc == null) != (manager.free == null)) return false;
	}
	return true;
}

/// Copies Zig-owned bytes into caller-owned storage using the optional C memory
/// manager, bridging pure-Zig codec results to stable FFI ownership semantics.
fn exportOwnedBytes(
	mm: ?*const JxlMemoryManager,
	bytes: []const u8,
	out_ptr: *?[*]u8,
	out_size: *usize,
) bool {
	if (!validateMemoryManager(mm)) return false;

	if (bytes.len == 0) {
		out_ptr.* = null;
		out_size.* = 0;
		return true;
	}

	if (mm) |manager| {
		if (manager.alloc != null) {
			const raw = manager.alloc.?(manager.@"opaque", bytes.len) orelse return false;
			const dst: [*]u8 = @ptrCast(raw);
			@memcpy(dst[0..bytes.len], bytes);
			out_ptr.* = dst;
			out_size.* = bytes.len;
			return true;
		}
	}

	const owned = std.heap.c_allocator.alloc(u8, bytes.len) catch return false;
	@memcpy(owned, bytes);
	out_ptr.* = owned.ptr;
	out_size.* = owned.len;
	return true;
}

fn freeEncoderState(enc: *EncoderImpl) void {
	clearPendingEncodeBuffers(enc);
	if (enc.owned_icc.len != 0) {
		std.heap.c_allocator.free(enc.owned_icc);
		enc.owned_icc = &.{};
	}
	for (enc.queued_frames.items) |*frame| {
		frame.deinit();
	}
	enc.queued_frames.deinit(std.heap.c_allocator);
	enc.queued_frames = .empty;
	for (enc.staged_boxes.items) |*box| {
		box.deinit();
	}
	enc.staged_boxes.deinit(std.heap.c_allocator);
	enc.staged_boxes = .empty;
	for (enc.frame_settings.items) |settings| {
		std.heap.c_allocator.destroy(settings);
	}
	enc.frame_settings.deinit(std.heap.c_allocator);
	enc.frame_settings = .empty;
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

fn customXYToF64Pair(xy: color_encoding_mod.Customxy) [2]f64 {
	return .{
		@as(f64, @floatFromInt(xy.x)) / 1000000.0,
		@as(f64, @floatFromInt(xy.y)) / 1000000.0,
	};
}

fn customXYFromF64Pair(pair: [2]f64) !color_encoding_mod.Customxy {
	for (pair) |coord| {
		if (!std.math.isFinite(coord)) return error.Unsupported;
	}

	const x = @as(i32, @intFromFloat(@round(pair[0] * 1000000.0)));
	const y = @as(i32, @intFromFloat(@round(pair[1] * 1000000.0)));
	if (x < -2097152 or x > 2097151 or y < -2097152 or y > 2097151) {
		return error.Unsupported;
	}
	return .{ .x = x, .y = y };
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

const IccEmbeddingShape = struct {
	main_color_channels: u32,
	requires_black_extra: bool = false,
};

/// Classifies the narrow embedded-ICC shapes we can faithfully map onto the
/// current JXL surface by inspecting ICC header signatures instead of pulling
/// in a full CMS.
fn classifyIccEmbeddingShape(icc: []const u8) !IccEmbeddingShape {
	if (icc.len < 128 or icc.len > std.math.maxInt(u32)) return error.InvalidArgs;
	const declared_size = byte_order.loadBE32(@ptrCast(icc[0..4]));
	if (declared_size != icc.len) return error.InvalidArgs;
	if (!std.mem.eql(u8, icc[36..40], "acsp")) return error.InvalidArgs;
	const color_space = icc[16..20];
	if (
		std.mem.eql(u8, color_space, "GRAY") or
		std.mem.eql(u8, color_space, "MCH1") or
		std.mem.eql(u8, color_space, "1CLR")
	) {
		return .{ .main_color_channels = 1 };
	}
	if (
		std.mem.eql(u8, color_space, "RGB ") or
		std.mem.eql(u8, color_space, "XYZ ") or
		std.mem.eql(u8, color_space, "Lab ") or
		std.mem.eql(u8, color_space, "Luv ") or
		std.mem.eql(u8, color_space, "YCbr") or
		std.mem.eql(u8, color_space, "Yxy ") or
		std.mem.eql(u8, color_space, "HSV ") or
		std.mem.eql(u8, color_space, "HLS ") or
		std.mem.eql(u8, color_space, "CMY ") or
		std.mem.eql(u8, color_space, "MCH3") or
		std.mem.eql(u8, color_space, "3CLR")
	) {
		return .{ .main_color_channels = 3 };
	}
	if (std.mem.eql(u8, color_space, "CMYK")) {
		return .{
			.main_color_channels = 3,
			.requires_black_extra = true,
		};
	}
	return error.Unsupported;
}

/// Ensures the first CMYK slice only accepts profiles when the public encoder
/// has already staged a real black sidecar channel, matching how the core
/// currently models non-alpha extras.
fn hasStagedBlackExtraChannel(enc: *const EncoderImpl) bool {
	for (enc.pending_extra_channels[0..enc.basic_info.num_extra_channels]) |pending| {
		if (!pending.info_set) continue;
		if (pending.info.type == .JXL_CHANNEL_BLACK) return true;
	}
	return false;
}

/// Builds the narrow internal color-encoding shell for embedded ICC streams:
/// color space still matters for channel count, while the rest is deferred to
/// the exact attached ICC bytes.
fn internalIccColorEncoding(num_color_channels: u32) color_encoding_mod.ColorEncoding {
	return .{
		.want_icc = true,
		.color_space = if (num_color_channels == 1) .gray else .rgb,
	};
}

fn defaultBasicInfo() JxlBasicInfo {
	var info = std.mem.zeroes(JxlBasicInfo);
	info.bits_per_sample = 8;
	info.intensity_target = 255.0;
	info.min_nits = 0.0;
	info.relative_to_max_display = 0;
	info.linear_below = 0.0;
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

fn fromInternalColorSpace(color_space: color_encoding_mod.ColorSpace) JxlColorSpace {
	return switch (color_space) {
		.rgb => .JXL_COLOR_SPACE_RGB,
		.gray => .JXL_COLOR_SPACE_GRAY,
		.xyb => .JXL_COLOR_SPACE_XYB,
		.unknown => .JXL_COLOR_SPACE_UNKNOWN,
	};
}

fn fromInternalWhitePoint(white_point: color_encoding_mod.WhitePoint) JxlWhitePoint {
	return switch (white_point) {
		.d65 => .JXL_WHITE_POINT_D65,
		.custom => .JXL_WHITE_POINT_CUSTOM,
		.e => .JXL_WHITE_POINT_E,
		.dci => .JXL_WHITE_POINT_DCI,
	};
}

fn fromInternalPrimaries(primaries: color_encoding_mod.Primaries) JxlPrimaries {
	return switch (primaries) {
		.srgb => .JXL_PRIMARIES_SRGB,
		.custom => .JXL_PRIMARIES_CUSTOM,
		.bt2100 => .JXL_PRIMARIES_2100,
		.p3 => .JXL_PRIMARIES_P3,
	};
}

fn fromInternalTransferFunction(tf: *const color_encoding_mod.CustomTransferFunction, gamma_out: *f64) JxlTransferFunction {
	if (tf.have_gamma) {
		gamma_out.* = @as(f64, @floatFromInt(tf.gamma)) / 10000000.0;
		return .JXL_TRANSFER_FUNCTION_GAMMA;
	}
	gamma_out.* = 0.0;
	return switch (tf.transfer_function) {
		.bt709 => .JXL_TRANSFER_FUNCTION_709,
		.unknown => .JXL_TRANSFER_FUNCTION_UNKNOWN,
		.linear => .JXL_TRANSFER_FUNCTION_LINEAR,
		.srgb => .JXL_TRANSFER_FUNCTION_SRGB,
		.pq => .JXL_TRANSFER_FUNCTION_PQ,
		.dci => .JXL_TRANSFER_FUNCTION_DCI,
		.hlg => .JXL_TRANSFER_FUNCTION_HLG,
	};
}

fn fromInternalRenderingIntent(intent: color_encoding_mod.RenderingIntent) JxlRenderingIntent {
	return switch (intent) {
		.perceptual => .JXL_RENDERING_INTENT_PERCEPTUAL,
		.relative => .JXL_RENDERING_INTENT_RELATIVE,
		.saturation => .JXL_RENDERING_INTENT_SATURATION,
		.absolute => .JXL_RENDERING_INTENT_ABSOLUTE,
	};
}

/// Maps the parsed structured JPEG XL color profile back onto the public C API
/// struct so decoder clients can inspect nominal color space without ICC.
fn populateColorEncoding(dst: *JxlColorEncoding, color: *const color_encoding_mod.ColorEncoding) void {
	dst.* = std.mem.zeroes(JxlColorEncoding);
	dst.color_space = fromInternalColorSpace(color.color_space);
	dst.white_point = fromInternalWhitePoint(color.white_point);
	dst.primaries = fromInternalPrimaries(color.primaries);
	dst.white_point_xy = if (color.white_point == .custom) customXYToF64Pair(color.white) else defaultWhitePointXY();
	dst.primaries_red_xy = if (color.primaries == .custom) customXYToF64Pair(color.red) else defaultPrimariesRedXY();
	dst.primaries_green_xy = if (color.primaries == .custom) customXYToF64Pair(color.green) else defaultPrimariesGreenXY();
	dst.primaries_blue_xy = if (color.primaries == .custom) customXYToF64Pair(color.blue) else defaultPrimariesBlueXY();
	dst.transfer_function = fromInternalTransferFunction(&color.tf, &dst.gamma);
	dst.rendering_intent = fromInternalRenderingIntent(color.rendering_intent);
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
			if (color.primaries != .JXL_PRIMARIES_SRGB) return error.Unsupported;
		},
		.JXL_COLOR_SPACE_RGB => {
			if (num_channels != 3) return error.Unsupported;
			internal.color_space = .rgb;
			internal.primaries = switch (color.primaries) {
				.JXL_PRIMARIES_SRGB => .srgb,
				.JXL_PRIMARIES_CUSTOM => .custom,
				.JXL_PRIMARIES_2100 => .bt2100,
				.JXL_PRIMARIES_P3 => .p3,
			};
			if (internal.primaries == .custom) {
				internal.red = try customXYFromF64Pair(color.primaries_red_xy);
				internal.green = try customXYFromF64Pair(color.primaries_green_xy);
				internal.blue = try customXYFromF64Pair(color.primaries_blue_xy);
			}
		},
		else => return error.Unsupported,
	}

	internal.white_point = switch (color.white_point) {
		.JXL_WHITE_POINT_D65 => .d65,
		.JXL_WHITE_POINT_CUSTOM => .custom,
		.JXL_WHITE_POINT_E => .e,
		.JXL_WHITE_POINT_DCI => .dci,
	};
	if (internal.white_point == .custom) {
		internal.white = try customXYFromF64Pair(color.white_point_xy);
	}

	switch (color.transfer_function) {
		.JXL_TRANSFER_FUNCTION_GAMMA => {
			if (!(color.gamma > 0.0 and color.gamma <= 1.0)) return error.Unsupported;
			internal.tf = .{
				.have_gamma = true,
				.gamma = @intFromFloat(@round(color.gamma * 10000000.0)),
			};
		},
		.JXL_TRANSFER_FUNCTION_709 => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .bt709,
		},
		.JXL_TRANSFER_FUNCTION_SRGB => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .srgb,
		},
		.JXL_TRANSFER_FUNCTION_LINEAR => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .linear,
		},
		.JXL_TRANSFER_FUNCTION_PQ => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .pq,
		},
		.JXL_TRANSFER_FUNCTION_DCI => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .dci,
		},
		.JXL_TRANSFER_FUNCTION_HLG => internal.tf = .{
			.have_gamma = false,
			.transfer_function = .hlg,
		},
		else => return error.Unsupported,
	}

	return internal;
}

test "toInternalColorEncoding accepts p3 hlg rgb" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_P3;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_HLG;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.Primaries.p3, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.hlg, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts bt2100 pq rgb" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_2100;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_PQ;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.Primaries.bt2100, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.pq, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts p3 dci white point" {
	var color = defaultJxlColorEncoding(false, false);
	color.white_point = .JXL_WHITE_POINT_DCI;
	color.primaries = .JXL_PRIMARIES_P3;
	color.transfer_function = .JXL_TRANSFER_FUNCTION_DCI;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.WhitePoint.dci, internal.white_point);
	try std.testing.expectEqual(color_encoding_mod.Primaries.p3, internal.primaries);
	try std.testing.expect(!internal.tf.have_gamma);
	try std.testing.expectEqual(color_encoding_mod.TransferFunction.dci, internal.tf.transfer_function);
}

test "toInternalColorEncoding accepts explicit gamma" {
	var color = defaultJxlColorEncoding(false, false);
	color.transfer_function = .JXL_TRANSFER_FUNCTION_GAMMA;
	color.gamma = 1.0 / 2.2;

	const internal = try toInternalColorEncoding(&color, 3);
	try std.testing.expectEqual(color_encoding_mod.ColorSpace.rgb, internal.color_space);
	try std.testing.expectEqual(color_encoding_mod.WhitePoint.d65, internal.white_point);
	try std.testing.expectEqual(color_encoding_mod.Primaries.srgb, internal.primaries);
	try std.testing.expect(internal.tf.have_gamma);
	try std.testing.expectEqual(@as(u32, 4545455), internal.tf.gamma);
}

test "toInternalColorEncoding accepts custom white point" {
	var color = defaultJxlColorEncoding(false, false);
	color.white_point = .JXL_WHITE_POINT_CUSTOM;
	color.white_point_xy = .{ 0.321, 0.345 };

	const internal = try toInternalColorEncoding(&color, 3);

	try std.testing.expectEqual(color_encoding_mod.WhitePoint.custom, internal.white_point);
	try std.testing.expectEqual(@as(i32, 321000), internal.white.x);
	try std.testing.expectEqual(@as(i32, 345000), internal.white.y);
}

test "toInternalColorEncoding accepts custom primaries" {
	var color = defaultJxlColorEncoding(false, false);
	color.primaries = .JXL_PRIMARIES_CUSTOM;
	color.primaries_red_xy = .{ 0.68, 0.32 };
	color.primaries_green_xy = .{ 0.265, 0.69 };
	color.primaries_blue_xy = .{ 0.15, 0.045 };

	const internal = try toInternalColorEncoding(&color, 3);

	try std.testing.expectEqual(color_encoding_mod.Primaries.custom, internal.primaries);
	try std.testing.expectEqual(@as(i32, 680000), internal.red.x);
	try std.testing.expectEqual(@as(i32, 320000), internal.red.y);
	try std.testing.expectEqual(@as(i32, 265000), internal.green.x);
	try std.testing.expectEqual(@as(i32, 690000), internal.green.y);
	try std.testing.expectEqual(@as(i32, 150000), internal.blue.x);
	try std.testing.expectEqual(@as(i32, 45000), internal.blue.y);
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
/// optional 8-bit alpha plus full-size/subsampled uint8 sidecar extras, no container,
/// plus simple orientation/intrinsic-size, tone-mapping, and animation metadata.
fn validateBasicInfoForSimpleEncode(info: *const JxlBasicInfo) !void {
	if (info.xsize == 0 or info.ysize == 0) return error.InvalidArgs;
	if (!(info.have_container == 0 or info.have_container == 1)) return error.InvalidArgs;
	if (!(info.have_animation == 0 or info.have_animation == 1)) return error.InvalidArgs;
	if (!(info.have_preview == 0 or info.have_preview == 1)) return error.InvalidArgs;
	if (@intFromEnum(info.orientation) < 1 or @intFromEnum(info.orientation) > 8) return error.InvalidArgs;
	if ((info.preview.xsize == 0) != (info.preview.ysize == 0)) return error.InvalidArgs;
	if ((info.have_preview != 0) != (info.preview.xsize != 0)) return error.InvalidArgs;
	if ((info.intrinsic_xsize == 0) != (info.intrinsic_ysize == 0)) return error.InvalidArgs;
	if (info.bits_per_sample != 8 or info.exponent_bits_per_sample != 0) return error.Unsupported;
	if (!(info.intensity_target > 0.0)) return error.InvalidArgs;
	if (info.min_nits < 0.0 or info.min_nits > info.intensity_target) return error.InvalidArgs;
	if (!(info.relative_to_max_display == 0 or info.relative_to_max_display == 1)) return error.InvalidArgs;
	if (info.linear_below < 0.0) return error.InvalidArgs;
	if (info.relative_to_max_display != 0 and info.linear_below > 1.0) return error.InvalidArgs;
	if (info.have_animation != 0) {
		if (info.animation.tps_numerator == 0 or info.animation.tps_denominator == 0) return error.InvalidArgs;
		if (!(info.animation.have_timecodes == 0 or info.animation.have_timecodes == 1)) return error.InvalidArgs;
	} else {
		if (info.animation.have_timecodes != 0) return error.InvalidArgs;
	}
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

fn validateFrameHeaderForSimpleEncode(basic_info: *const JxlBasicInfo, frame_header: *const JxlFrameHeader) !void {
	const zero_blend = std.mem.zeroes(JxlBlendInfo);
	const zero_layer = std.mem.zeroes(JxlLayerInfo);

	if (frame_header.name_length != 0) return error.Unsupported;
	if (frame_header.is_last != 0) return error.Unsupported;
	if (frame_header.layer_info.have_crop != 0) return error.Unsupported;
	if (frame_header.layer_info.crop_x0 != 0 or frame_header.layer_info.crop_y0 != 0) return error.Unsupported;
	if (frame_header.layer_info.xsize != 0 or frame_header.layer_info.ysize != 0) return error.Unsupported;
	if (!std.meta.eql(frame_header.layer_info.blend_info, zero_blend)) return error.Unsupported;
	if (frame_header.layer_info.save_as_reference != 0) return error.Unsupported;
	if (!std.meta.eql(frame_header.layer_info, zero_layer)) return error.Unsupported;

	if (basic_info.have_animation == 0) {
		if (frame_header.duration != 0 or frame_header.timecode != 0) return error.Unsupported;
		return;
	}

	if (basic_info.animation.have_timecodes == 0 and frame_header.timecode != 0) return error.InvalidArgs;
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
	enc.pending_frame_header_set = false;
	enc.pending_frame_header = std.mem.zeroes(JxlFrameHeader);
	for (&enc.pending_extra_channels) |*pending| {
		if (pending.buffer.len != 0) {
			std.heap.c_allocator.free(pending.buffer);
			pending.buffer = &.{};
		}
		pending.row_stride = 0;
		pending.buffer_set = false;
	}
}

/// Finalizes the currently staged frame into the encoder's frame queue. The
/// first multi-frame slice intentionally only accepts main-image data here;
/// staged sidecar extras remain a later widening step.
fn queuePendingFrame(enc: *EncoderImpl) !void {
	if (enc.image_bytes.len == 0) return;

	var queued = EncoderQueuedFrame{
		.image_format = enc.image_format,
		.image_bytes = try std.heap.c_allocator.dupe(u8, enc.image_bytes),
		.frame_header_set = enc.pending_frame_header_set,
		.frame_header = enc.pending_frame_header,
	};
	errdefer queued.deinit();

	for (&enc.pending_extra_channels, &queued.extra_buffers) |*pending, *plane| {
		if (!pending.buffer_set) continue;
		plane.buffer = try std.heap.c_allocator.dupe(u8, pending.buffer);
		plane.row_stride = pending.row_stride;
		plane.buffer_set = true;
	}

	try enc.queued_frames.append(std.heap.c_allocator, queued);
	clearPendingFrameBuffers(enc);
	enc.added_frame = enc.queued_frames.items.len != 0;
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

fn extraChannelTypeFromInternal(extra_type: image_metadata.ExtraChannel) JxlExtraChannelType {
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

fn populateExtraChannelInfo(info: *JxlExtraChannelInfo, extra: *const image_metadata.ExtraChannelInfo) void {
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

fn subsampledSize(size: u32, shift: u32) usize {
	return common.divCeil(@as(usize, size), @as(usize, 1) << @intCast(shift));
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

const PreparedSimplePackedInput = struct {
	color_row_stride: usize,
	color_pixels: []u8,
	alpha_row_stride: usize,
	alpha_pixels: []u8,
	extra_planes: []enc_api.SimpleExtraPlaneU8,

	fn deinit(self: *PreparedSimplePackedInput, allocator: std.mem.Allocator) void {
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

/// Converts staged public-API image and sidecar buffers into the packed plane
/// layout the Zig encoder core expects, preserving alpha-first extra ordering.
fn prepareSimplePackedInput(allocator: std.mem.Allocator, impl: *const EncoderImpl) !PreparedSimplePackedInput {
	const width: usize = @intCast(impl.basic_info.xsize);
	const height: usize = @intCast(impl.basic_info.ysize);
	const num_color_channels: usize = @intCast(impl.basic_info.num_color_channels);
	const has_alpha = impl.basic_info.alpha_bits != 0;
	const has_staged_alpha = has_alpha and impl.pending_extra_channels[0].buffer_set;
	const has_interleaved_alpha = has_alpha and impl.image_format.num_channels == num_color_channels + 1;
	const staged_alpha_dim_shift: u32 = if (has_alpha and impl.pending_extra_channels[0].info_set) impl.pending_extra_channels[0].info.dim_shift else 0;
	const image_stride = rowStrideBytes(width, impl.image_format) orelse return error.GenericError;
	const color_row_stride = width * num_color_channels;
	const color_pixels = try allocator.alloc(u8, color_row_stride * height);
	errdefer allocator.free(color_pixels);

	const alpha_width = subsampledSize(impl.basic_info.xsize, staged_alpha_dim_shift);
	const alpha_height = subsampledSize(impl.basic_info.ysize, staged_alpha_dim_shift);
	const alpha_row_stride = if (has_interleaved_alpha) width else alpha_width;
	var alpha_pixels: []u8 = &.{};
	if (has_alpha) {
		if (has_staged_alpha == has_interleaved_alpha) return error.InvalidArgs;
		alpha_pixels = try allocator.alloc(u8, alpha_row_stride * if (has_interleaved_alpha) height else alpha_height);
	}
	errdefer if (alpha_pixels.len != 0) allocator.free(alpha_pixels);

	const sidecar_start: usize = if (has_alpha) 1 else 0;
	const sidecar_count: usize = @intCast(impl.basic_info.num_extra_channels - sidecar_start);
	const extra_planes = try allocator.alloc(enc_api.SimpleExtraPlaneU8, sidecar_count);
	errdefer allocator.free(extra_planes);

	for (0..sidecar_count) |i| {
		const extra_index = sidecar_start + i;
		const pending = &impl.pending_extra_channels[extra_index];
		if (!pending.info_set or !pending.buffer_set) return error.InvalidArgs;
		extra_planes[i] = .{
			.info = try toInternalExtraChannelInfo(pending),
			.row_stride = pending.row_stride,
			.pixels = pending.buffer,
		};
	}

	for (0..height) |y| {
		const src_row_start = y * image_stride;
		const src_row = impl.image_bytes[src_row_start .. src_row_start + image_stride];
		const color_row_start = y * color_row_stride;
		const color_row = color_pixels[color_row_start .. color_row_start + color_row_stride];
		if (has_alpha and has_interleaved_alpha) {
			const alpha_row_start = y * alpha_row_stride;
			const alpha_row = alpha_pixels[alpha_row_start .. alpha_row_start + alpha_row_stride];
			for (0..width) |x| {
				const src_pixel = x * (num_color_channels + 1);
				const dst_pixel = x * num_color_channels;
				@memcpy(
					color_row[dst_pixel .. dst_pixel + num_color_channels],
					src_row[src_pixel .. src_pixel + num_color_channels],
				);
				alpha_row[x] = src_row[src_pixel + num_color_channels];
			}
		} else {
			@memcpy(color_row, src_row[0..color_row_stride]);
		}
	}
	if (has_alpha and has_staged_alpha) {
		const staged_alpha = &impl.pending_extra_channels[0];
		for (0..alpha_height) |y| {
			const alpha_row_start = y * alpha_row_stride;
			const alpha_row = alpha_pixels[alpha_row_start .. alpha_row_start + alpha_row_stride];
			const alpha_src_start = y * staged_alpha.row_stride;
			@memcpy(alpha_row, staged_alpha.buffer[alpha_src_start .. alpha_src_start + alpha_row_stride]);
		}
	}

	return .{
		.color_row_stride = color_row_stride,
		.color_pixels = color_pixels,
		.alpha_row_stride = alpha_row_stride,
		.alpha_pixels = alpha_pixels,
		.extra_planes = extra_planes,
	};
}

/// Rebuilds the packed per-frame view from one queued frame plus the global
/// declared extra-channel metadata, preserving the existing single-frame
/// sidecar-extra behavior after frames are moved into the queue.
fn prepareQueuedPackedInput(
	allocator: std.mem.Allocator,
	impl: *const EncoderImpl,
	frame: *const EncoderQueuedFrame,
) !PreparedSimplePackedInput {
	const width: usize = @intCast(impl.basic_info.xsize);
	const height: usize = @intCast(impl.basic_info.ysize);
	const num_color_channels: usize = @intCast(impl.basic_info.num_color_channels);
	const has_alpha = impl.basic_info.alpha_bits != 0;
	const has_staged_alpha = has_alpha and frame.extra_buffers[0].buffer_set;
	const has_interleaved_alpha = has_alpha and frame.image_format.num_channels == num_color_channels + 1;
	const staged_alpha_dim_shift: u32 = if (has_alpha and impl.pending_extra_channels[0].info_set) impl.pending_extra_channels[0].info.dim_shift else 0;
	const image_stride = rowStrideBytes(width, frame.image_format) orelse return error.GenericError;
	const color_row_stride = width * num_color_channels;
	const color_pixels = try allocator.alloc(u8, color_row_stride * height);
	errdefer allocator.free(color_pixels);

	const alpha_width = subsampledSize(impl.basic_info.xsize, staged_alpha_dim_shift);
	const alpha_height = subsampledSize(impl.basic_info.ysize, staged_alpha_dim_shift);
	const alpha_row_stride = if (has_interleaved_alpha) width else alpha_width;
	var alpha_pixels: []u8 = &.{};
	if (has_alpha) {
		if (has_staged_alpha == has_interleaved_alpha) return error.InvalidArgs;
		alpha_pixels = try allocator.alloc(u8, alpha_row_stride * if (has_interleaved_alpha) height else alpha_height);
	}
	errdefer if (alpha_pixels.len != 0) allocator.free(alpha_pixels);

	const sidecar_start: usize = if (has_alpha) 1 else 0;
	const sidecar_count: usize = @intCast(impl.basic_info.num_extra_channels - sidecar_start);
	const extra_planes = try allocator.alloc(enc_api.SimpleExtraPlaneU8, sidecar_count);
	errdefer allocator.free(extra_planes);

	for (0..sidecar_count) |i| {
		const extra_index = sidecar_start + i;
		const pending = &impl.pending_extra_channels[extra_index];
		const plane = &frame.extra_buffers[extra_index];
		if (!pending.info_set or !plane.buffer_set) return error.InvalidArgs;
		extra_planes[i] = .{
			.info = try toInternalExtraChannelInfo(pending),
			.row_stride = plane.row_stride,
			.pixels = plane.buffer,
		};
	}

	for (0..height) |y| {
		const src_row_start = y * image_stride;
		const src_row = frame.image_bytes[src_row_start .. src_row_start + image_stride];
		const color_row_start = y * color_row_stride;
		const color_row = color_pixels[color_row_start .. color_row_start + color_row_stride];
		if (has_alpha and has_interleaved_alpha) {
			const alpha_row_start = y * alpha_row_stride;
			const alpha_row = alpha_pixels[alpha_row_start .. alpha_row_start + alpha_row_stride];
			for (0..width) |x| {
				const src_pixel = x * (num_color_channels + 1);
				const dst_pixel = x * num_color_channels;
				@memcpy(
					color_row[dst_pixel .. dst_pixel + num_color_channels],
					src_row[src_pixel .. src_pixel + num_color_channels],
				);
				alpha_row[x] = src_row[src_pixel + num_color_channels];
			}
		} else {
			@memcpy(color_row, src_row[0..color_row_stride]);
		}
	}
	if (has_alpha and has_staged_alpha) {
		for (0..alpha_height) |y| {
			const alpha_row_start = y * alpha_row_stride;
			const alpha_row = alpha_pixels[alpha_row_start .. alpha_row_start + alpha_row_stride];
			const alpha_src_start = y * frame.extra_buffers[0].row_stride;
			@memcpy(alpha_row, frame.extra_buffers[0].buffer[alpha_src_start .. alpha_src_start + alpha_row_stride]);
		}
	}

	return .{
		.color_row_stride = color_row_stride,
		.color_pixels = color_pixels,
		.alpha_row_stride = alpha_row_stride,
		.alpha_pixels = alpha_pixels,
		.extra_planes = extra_planes,
	};
}

/// Finalizes the staged public-API input into the existing Zig one-shot
/// encoder by packing color and extra planes into a normalized interleaved buffer.
fn finalizeSimpleEncode(impl: *EncoderImpl) !void {
	if (impl.encoded_bytes.len != 0) return;
	if (impl.queued_frames.items.len == 0) return error.InvalidArgs;

	if (impl.queued_frames.items.len == 1) {
		if (impl.image_bytes.len != 0) return error.InvalidArgs;

		var prepared = try prepareQueuedPackedInput(std.heap.c_allocator, impl, &impl.queued_frames.items[0]);
		defer prepared.deinit(std.heap.c_allocator);

		impl.encoded_bytes = try enc_api.encodeSimplePackedU8(std.heap.c_allocator, .{
			.width = impl.basic_info.xsize,
			.height = impl.basic_info.ysize,
			.num_color_channels = impl.basic_info.num_color_channels,
			.embedded_icc = impl.owned_icc,
			.color_row_stride = prepared.color_row_stride,
			.color_pixels = prepared.color_pixels,
			.alpha_row_stride = prepared.alpha_row_stride,
			.alpha_pixels = prepared.alpha_pixels,
			.use_container = impl.basic_info.have_container != 0 and impl.staged_boxes.items.len == 0,
			.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
			.alpha_info = if (impl.basic_info.alpha_bits != 0 and impl.pending_extra_channels[0].info_set)
				try toInternalExtraChannelInfo(&impl.pending_extra_channels[0])
			else if (impl.basic_info.alpha_bits != 0)
				image_metadata.ExtraChannelInfo{
					.type = .alpha,
					.bit_depth = .{},
					.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
				}
			else
				null,
			.orientation = @intCast(@intFromEnum(impl.basic_info.orientation)),
			.preview_width = impl.basic_info.preview.xsize,
			.preview_height = impl.basic_info.preview.ysize,
			.intrinsic_width = impl.basic_info.intrinsic_xsize,
			.intrinsic_height = impl.basic_info.intrinsic_ysize,
			.have_animation = impl.basic_info.have_animation != 0,
			.animation = .{
				.tps_numerator = impl.basic_info.animation.tps_numerator,
				.tps_denominator = impl.basic_info.animation.tps_denominator,
				.num_loops = impl.basic_info.animation.num_loops,
				.have_timecodes = impl.basic_info.animation.have_timecodes != 0,
			},
			.frame_duration = if (impl.queued_frames.items[0].frame_header_set) impl.queued_frames.items[0].frame_header.duration else 0,
			.frame_timecode = if (impl.queued_frames.items[0].frame_header_set) impl.queued_frames.items[0].frame_header.timecode else 0,
			.tone_mapping = .{
				.intensity_target = impl.basic_info.intensity_target,
				.min_nits = impl.basic_info.min_nits,
				.relative_to_max_display = impl.basic_info.relative_to_max_display != 0,
				.linear_below = impl.basic_info.linear_below,
			},
			.extra_planes = prepared.extra_planes,
		}, impl.internal_color_encoding);
		try wrapPendingBoxes(impl);
		impl.output_offset = 0;
		return;
	}

	const prepared_frames = try std.heap.c_allocator.alloc(PreparedSimplePackedInput, impl.queued_frames.items.len);
	defer {
		for (prepared_frames) |*prepared| prepared.deinit(std.heap.c_allocator);
		std.heap.c_allocator.free(prepared_frames);
	}
	for (prepared_frames) |*prepared| {
		prepared.* = .{
			.color_row_stride = 0,
			.color_pixels = &.{},
			.alpha_row_stride = 0,
			.alpha_pixels = &.{},
			.extra_planes = &.{},
		};
	}
	const animation_frames = try std.heap.c_allocator.alloc(enc_api.SimplePackedU8AnimationFrame, impl.queued_frames.items.len);
	defer std.heap.c_allocator.free(animation_frames);

	for (impl.queued_frames.items, 0..) |*queued_frame, i| {
		prepared_frames[i] = try prepareQueuedPackedInput(std.heap.c_allocator, impl, queued_frame);
		animation_frames[i] = .{
			.color_row_stride = prepared_frames[i].color_row_stride,
			.color_pixels = prepared_frames[i].color_pixels,
			.alpha_row_stride = prepared_frames[i].alpha_row_stride,
			.alpha_pixels = prepared_frames[i].alpha_pixels,
			.extra_planes = prepared_frames[i].extra_planes,
			.frame_duration = if (queued_frame.frame_header_set) queued_frame.frame_header.duration else 0,
			.frame_timecode = if (queued_frame.frame_header_set) queued_frame.frame_header.timecode else 0,
		};
	}

	impl.encoded_bytes = try enc_api.encodeSimplePackedU8Animation(std.heap.c_allocator, .{
		.width = impl.basic_info.xsize,
		.height = impl.basic_info.ysize,
		.num_color_channels = impl.basic_info.num_color_channels,
		.embedded_icc = impl.owned_icc,
		.use_container = impl.basic_info.have_container != 0 and impl.staged_boxes.items.len == 0,
		.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
		.alpha_info = if (impl.basic_info.alpha_bits != 0 and impl.pending_extra_channels[0].info_set)
			try toInternalExtraChannelInfo(&impl.pending_extra_channels[0])
		else if (impl.basic_info.alpha_bits != 0)
			image_metadata.ExtraChannelInfo{
				.type = .alpha,
				.bit_depth = .{},
				.alpha_associated = impl.basic_info.alpha_premultiplied != 0,
			}
		else
			null,
		.orientation = @intCast(@intFromEnum(impl.basic_info.orientation)),
		.preview_width = impl.basic_info.preview.xsize,
		.preview_height = impl.basic_info.preview.ysize,
		.intrinsic_width = impl.basic_info.intrinsic_xsize,
		.intrinsic_height = impl.basic_info.intrinsic_ysize,
		.animation = .{
			.tps_numerator = impl.basic_info.animation.tps_numerator,
			.tps_denominator = impl.basic_info.animation.tps_denominator,
			.num_loops = impl.basic_info.animation.num_loops,
			.have_timecodes = impl.basic_info.animation.have_timecodes != 0,
		},
		.tone_mapping = .{
			.intensity_target = impl.basic_info.intensity_target,
			.min_nits = impl.basic_info.min_nits,
			.relative_to_max_display = impl.basic_info.relative_to_max_display != 0,
			.linear_below = impl.basic_info.linear_below,
		},
		.frames = animation_frames,
	}, impl.internal_color_encoding);
	try wrapPendingBoxes(impl);
	impl.output_offset = 0;
}

fn wrapPendingBoxes(impl: *EncoderImpl) !void {
	if (impl.staged_boxes.items.len == 0) return;
	const codestream = impl.encoded_bytes;
	const boxes = try std.heap.c_allocator.alloc(container_mod.Box, impl.staged_boxes.items.len);
	defer std.heap.c_allocator.free(boxes);
	for (impl.staged_boxes.items, 0..) |box, i| {
		boxes[i] = .{ .box_type = box.box_type, .contents = box.contents };
	}
	impl.encoded_bytes = try container_mod.wrapCodestreamWithBoxes(std.heap.c_allocator, codestream, boxes);
	std.heap.c_allocator.free(codestream);
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

fn clampFloatSample(value: f32, max_value: u32) f32 {
	if (max_value == 0 or !std.math.isFinite(value)) return 0.0;
	return std.math.clamp(value, 0.0, @as(f32, @floatFromInt(max_value)));
}

fn normalizedFloatSample(value: f32, max_value: u32) f32 {
	if (max_value == 0) return 0.0;
	return clampFloatSample(value, max_value) / @as(f32, @floatFromInt(max_value));
}

fn scaleFloatToU8(value: f32, max_value: u32) u8 {
	if (max_value == 0) return 0;
	const scaled = @round(normalizedFloatSample(value, max_value) * 255.0);
	return @intFromFloat(scaled);
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

fn renderedOutputValue(rendered: *const render_mod.FloatImage, alpha_img: ?*const Image, metadata: *const image_metadata.ImageMetadata, x: usize, y: usize, requested_channel: usize) f32 {
	if (requested_channel < 3) return rendered.rowConst(y, requested_channel)[x];
	if (alpha_img) |img| {
		const max_value = bitDepthMax(metadata.bit_depth.bits_per_sample);
		if (alphaChannelIndex(metadata)) |idx| {
			return @floatFromInt(img.channels.items[3 + idx].rowConst(y)[x]);
		}
		return @floatFromInt(max_value);
	}
	return @floatFromInt(bitDepthMax(metadata.bit_depth.bits_per_sample));
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

/// Writes a post-render float RGB image into the public C API output buffer.
/// This expects output-domain sample values; XYB-to-output color conversion is a separate stage.
fn writeRenderedImageToOutput(rendered: *const render_mod.FloatImage, alpha_img: ?*const Image, metadata: *const image_metadata.ImageMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	if (metadata.color_encoding.channels() != 3) return error.Unsupported;
	if (rendered.channels < 3) return error.Unsupported;
	if (!(format.num_channels == 3 or format.num_channels == 4)) return error.Unsupported;

	const stride = rowStrideBytes(rendered.xsize, format) orelse return error.Unsupported;
	if (stride * rendered.ysize > buffer_size) return error.GenericError;

	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return error.Unsupported;
	const max_value = bitDepthMax(metadata.bit_depth.bits_per_sample);
	const num_channels: usize = @intCast(format.num_channels);

	if (format.data_type == .JXL_TYPE_UINT8 and format.num_channels == 3) {
		for (0..rendered.ysize) |y| {
			const dst = buffer[y * stride .. y * stride + rendered.xsize * 3];
			const row_r = rendered.rowConst(y, 0);
			const row_g = rendered.rowConst(y, 1);
			const row_b = rendered.rowConst(y, 2);
			for (0..rendered.xsize) |x| {
				dst[x * 3 + 0] = scaleFloatToU8(row_r[x], max_value);
				dst[x * 3 + 1] = scaleFloatToU8(row_g[x], max_value);
				dst[x * 3 + 2] = scaleFloatToU8(row_b[x], max_value);
			}
		}
		return;
	}

	for (0..rendered.ysize) |y| {
		const row = buffer[y * stride .. y * stride + stride];
		for (0..rendered.xsize) |x| {
			const pixel = row[x * num_channels * bytes_per_channel ..];
			for (0..num_channels) |c| {
				const value = renderedOutputValue(rendered, alpha_img, metadata, x, y, c);
				switch (format.data_type) {
					.JXL_TYPE_UINT8 => {
						pixel[c] = scaleFloatToU8(value, max_value);
					},
					.JXL_TYPE_UINT16 => {
						const scaled: u32 = @intFromFloat(@round(normalizedFloatSample(value, max_value) * 65535.0));
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, @intCast(scaled));
					},
					.JXL_TYPE_FLOAT => {
						const raw: u32 = @bitCast(normalizedFloatSample(value, max_value));
						storeU32(pixel[c * 4 .. c * 4 + 4], format.endianness, raw);
					},
					.JXL_TYPE_FLOAT16 => {
						const half: f16 = @floatCast(normalizedFloatSample(value, max_value));
						const raw: u16 = @bitCast(half);
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, raw);
					},
				}
			}
		}
	}
}

fn writeFrameDecoderOutput(frame_dec: *dec_frame.FrameDecoder, metadata: *const image_metadata.ImageMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	if (frame_dec.rendered_image) |*rendered| {
		if (metadata.xyb_encoded or frame_dec.frame_header.color_transform == .xyb) return error.Unsupported;
		return writeRenderedImageToOutput(rendered, frame_dec.getDecodedImage(), metadata, format, buffer, buffer_size);
	}
	return writeImageToOutput(frame_dec.getDecodedImage(), metadata, format, buffer, buffer_size);
}

fn populateBasicInfo(metadata: *const image_metadata.CodecMetadata, have_container: bool) JxlBasicInfo {
	var info = std.mem.zeroes(JxlBasicInfo);
	info.have_container = @intFromBool(have_container);
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

fn populateBlendInfo(dst: *JxlBlendInfo, src: *const frame_header_mod.BlendingInfo) void {
	dst.* = .{
		.blendmode = switch (src.mode) {
			.replace => .JXL_BLEND_REPLACE,
			.add => .JXL_BLEND_ADD,
			.blend => .JXL_BLEND_BLEND,
			.alpha_weighted_add => .JXL_BLEND_MULADD,
			.mul => .JXL_BLEND_MUL,
		},
		.source = src.source,
		.alpha = src.alpha_channel,
		.clamp = @intFromBool(src.clamp),
	};
}

fn populateFrameHeader(
	dst: *JxlFrameHeader,
	src: *const frame_header_mod.FrameHeader,
) void {
	dst.* = std.mem.zeroes(JxlFrameHeader);
	dst.duration = src.animation_frame.duration;
	dst.timecode = src.animation_frame.timecode;
	dst.name_length = src.name_len;
	dst.is_last = @intFromBool(src.is_last);
	dst.layer_info.have_crop = @intFromBool(src.custom_size_or_origin);
	dst.layer_info.crop_x0 = src.frame_origin.x0;
	dst.layer_info.crop_y0 = src.frame_origin.y0;
	dst.layer_info.xsize = if (src.custom_size_or_origin) src.frame_size.xsize else 0;
	dst.layer_info.ysize = if (src.custom_size_or_origin) src.frame_size.ysize else 0;
	dst.layer_info.save_as_reference = src.save_as_reference;
	populateBlendInfo(&dst.layer_info.blend_info, &src.blending_info);
}

/// Parses the current frame header without decoding pixels so the public C API
/// can emit `JXL_DEC_FRAME` and expose timing/name metadata one displayed frame at a time.
fn ensureCurrentFrameParsed(dec: *DecoderImpl) JxlDecoderStatus {
	if (dec.decode_complete or dec.frame_parsed) return .JXL_DEC_SUCCESS;
	if (!dec.basic_info_available) {
		const parse_status = ensureParsed(dec);
		if (parse_status != .JXL_DEC_SUCCESS) return parse_status;
	}
	if (dec.frame_offset >= dec.frame_data.len) {
		dec.decode_complete = true;
		return .JXL_DEC_SUCCESS;
	}

	var frame_dec = dec_frame.FrameDecoder.init(std.heap.c_allocator, &dec.codec_meta);
	defer frame_dec.deinit();
	var header_br = BitReader.init(dec.frame_data[dec.frame_offset..]);
	frame_dec.initFrame(&header_br) catch |err| return statusFromError(err, dec.input_closed);
	header_br.close() catch |err| return statusFromError(err, dec.input_closed);

	dec.frame_size = dec_frame.frameByteCount(std.heap.c_allocator, &dec.codec_meta, dec.frame_data[dec.frame_offset..]) catch |err| return statusFromError(err, dec.input_closed);
	populateFrameHeader(&dec.frame_header, &frame_dec.frame_header);
	dec.frame_name_len = @intCast(frame_dec.frame_header.name_len);
	if (dec.frame_name_len != 0) {
		@memcpy(dec.frame_name_buf[0..dec.frame_name_len], frame_dec.frame_header.getName());
	}
	dec.frame_parsed = true;
	return .JXL_DEC_SUCCESS;
}

fn advanceCurrentFrame(dec: *DecoderImpl) void {
	if (!dec.frame_parsed) return;
	dec.frame_offset += dec.frame_size;
	dec.frame_size = 0;
	dec.frame_parsed = false;
	dec.frame_emitted = false;
	dec.frame_decoded = false;
	dec.full_image_emitted = false;
	dec.frame_name_len = 0;
	dec.frame_header = std.mem.zeroes(JxlFrameHeader);
	if (dec.frame_offset >= dec.frame_data.len) {
		dec.decode_complete = true;
	}
}

fn resetBoxIteration(dec: *DecoderImpl) void {
	dec.box_index = 0;
	dec.box_header_emitted = false;
	dec.box_bytes_emitted = 0;
	dec.box_complete_emitted = false;
	dec.box_buffer = null;
	dec.box_buffer_size = 0;
	dec.box_buffer_written = 0;
}

fn currentBox(dec: *const DecoderImpl) ?*const container_mod.OwnedBox {
	if (dec.box_index >= dec.owned_boxes.len) return null;
	return &dec.owned_boxes[dec.box_index];
}

fn currentBoxMut(dec: *DecoderImpl) ?*container_mod.OwnedBox {
	if (dec.box_index >= dec.owned_boxes.len) return null;
	return &dec.owned_boxes[dec.box_index];
}

fn ensureCurrentBoxPrepared(dec: *DecoderImpl) JxlDecoderStatus {
	if (!dec.decompress_boxes) return .JXL_DEC_SUCCESS;
	const box = currentBoxMut(dec) orelse return .JXL_DEC_SUCCESS;
	box.ensureDecompressed(std.heap.c_allocator) catch |err| return statusFromError(err, dec.input_closed);
	return .JXL_DEC_SUCCESS;
}

fn advanceCurrentBox(dec: *DecoderImpl) void {
	dec.box_index += 1;
	dec.box_header_emitted = false;
	dec.box_bytes_emitted = 0;
	dec.box_complete_emitted = false;
	dec.box_buffer = null;
	dec.box_buffer_size = 0;
	dec.box_buffer_written = 0;
}

fn resetFrameIteration(dec: *DecoderImpl) void {
	dec.frame_offset = 0;
	dec.frame_size = 0;
	dec.frame_parsed = false;
	dec.frame_emitted = false;
	dec.frame_decoded = false;
	dec.input_is_container = false;
	dec.output_buffer = null;
	dec.output_buffer_size = 0;
	dec.frame_name_len = 0;
	dec.frame_header = std.mem.zeroes(JxlFrameHeader);
	dec.full_image_emitted = false;
	dec.decode_complete = false;
	resetBoxIteration(dec);
}

/// Parses the codestream headers once and caches the frame slice so the
/// compatibility-layer state machine can emit basic-info and full-image events
/// without duplicating decode logic.
fn ensureParsed(dec: *DecoderImpl) JxlDecoderStatus {
	if (dec.basic_info_available) return .JXL_DEC_SUCCESS;

	const input = dec.inputSlice();
	const codestream = switch (JxlSignatureCheck(if (input.len == 0) null else input.ptr, input.len)) {
		.JXL_SIG_NOT_ENOUGH_BYTES => return if (dec.input_closed) .JXL_DEC_ERROR else .JXL_DEC_NEED_MORE_INPUT,
		.JXL_SIG_INVALID => return .JXL_DEC_ERROR,
		.JXL_SIG_CONTAINER => blk: {
			dec.input_is_container = true;
			if (dec.owned_codestream.len != 0) {
				std.heap.c_allocator.free(dec.owned_codestream);
				dec.owned_codestream = &.{};
			}
			if (dec.owned_icc.len != 0) {
				std.heap.c_allocator.free(dec.owned_icc);
				dec.owned_icc = &.{};
			}
			if (dec.owned_boxes.len != 0) {
				for (dec.owned_boxes) |*box| box.deinit(std.heap.c_allocator);
				std.heap.c_allocator.free(dec.owned_boxes);
				dec.owned_boxes = &.{};
			}
			const parsed = container_mod.extractCodestreamAndBoxes(std.heap.c_allocator, input) catch |err| return statusFromError(err, dec.input_closed);
			dec.owned_codestream = parsed.codestream;
			dec.owned_boxes = parsed.boxes;
			break :blk dec.owned_codestream;
		},
		.JXL_SIG_CODESTREAM => blk: {
			dec.input_is_container = false;
			break :blk input;
		},
	};

	var br = BitReader.init(codestream[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = image_metadata.ImageMetadata.readFromBitStream(&br) catch |err| return statusFromError(err, dec.input_closed);
	const transform_data = image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded) catch |err| return statusFromError(err, dec.input_closed);
	const embedded_icc = if (metadata.color_encoding.want_icc) blk: {
		if (dec.owned_icc.len != 0) {
			std.heap.c_allocator.free(dec.owned_icc);
			dec.owned_icc = &.{};
		}
		dec.owned_icc = icc_codec.decompressICCFromBitReader(std.heap.c_allocator, &br) catch |err| return switch (err) {
			error.NotEnoughBytes => if (dec.input_closed) .JXL_DEC_ERROR else .JXL_DEC_NEED_MORE_INPUT,
			else => .JXL_DEC_ERROR,
		};
		break :blk dec.owned_icc;
	} else &[_]u8{};
	br.jumpToByteBoundary() catch |err| return statusFromError(err, dec.input_closed);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.m = metadata;
	codec_meta.size = size;
	codec_meta.transform_data = transform_data;
	codec_meta.embedded_icc = embedded_icc;

	const frame_header_byte_offset = br.totalBitsConsumed() / 8;
	br.close() catch |err| return statusFromError(err, dec.input_closed);

	dec.codec_meta = codec_meta;
	dec.frame_data = codestream[2 + frame_header_byte_offset ..];
	dec.basic_info = populateBasicInfo(&codec_meta, dec.input_is_container);
	dec.basic_info_available = true;
	return .JXL_DEC_SUCCESS;
}

fn ensureDecoded(dec: *DecoderImpl) JxlDecoderStatus {
	if (dec.decode_complete) return .JXL_DEC_SUCCESS;
	const frame_status = ensureCurrentFrameParsed(dec);
	if (frame_status != .JXL_DEC_SUCCESS) return frame_status;
	if (!dec.frame_parsed) return .JXL_DEC_SUCCESS;
	if (dec.frame_decoded) return .JXL_DEC_SUCCESS;
	if (dec.output_buffer == null) return .JXL_DEC_NEED_IMAGE_OUT_BUFFER;

	var frame_dec = dec_frame.FrameDecoder.init(std.heap.c_allocator, &dec.codec_meta);
	defer frame_dec.deinit();
	frame_dec.decodeFrame(dec.frame_data[dec.frame_offset .. dec.frame_offset + dec.frame_size]) catch return .JXL_DEC_ERROR;

	writeFrameDecoderOutput(&frame_dec, &dec.codec_meta.m, dec.output_format, dec.output_buffer.?, dec.output_buffer_size) catch return .JXL_DEC_ERROR;
	dec.frame_decoded = true;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderVersion() u32 {
	return decoderVersion();
}

pub export fn JxlICCProfileEncode(
	memory_manager: ?*const JxlMemoryManager,
	icc_ptr: ?[*]const u8,
	icc_size: usize,
	compressed_icc_ptr: ?*?[*]u8,
	compressed_icc_size: ?*usize,
) JXL_BOOL {
	const compressed_out = compressed_icc_ptr orelse return 0;
	const size_out = compressed_icc_size orelse return 0;
	compressed_out.* = null;
	size_out.* = 0;
	if (!validateMemoryManager(memory_manager)) return 0;

	const icc_many = icc_ptr orelse return 0;
	const icc = icc_many[0..icc_size];
	const compressed = icc_codec.compressICC(std.heap.c_allocator, icc) catch return 0;
	defer std.heap.c_allocator.free(compressed);

	return if (exportOwnedBytes(memory_manager, compressed, compressed_out, size_out)) 1 else 0;
}

pub export fn JxlICCProfileDecode(
	memory_manager: ?*const JxlMemoryManager,
	compressed_icc_ptr: ?[*]const u8,
	compressed_icc_size: usize,
	icc_ptr: ?*?[*]u8,
	icc_size: ?*usize,
) JXL_BOOL {
	const icc_out = icc_ptr orelse return 0;
	const size_out = icc_size orelse return 0;
	icc_out.* = null;
	size_out.* = 0;
	if (!validateMemoryManager(memory_manager)) return 0;

	const compressed_many = compressed_icc_ptr orelse return 0;
	const compressed_icc = compressed_many[0..compressed_icc_size];
	const icc = icc_codec.decompressICC(std.heap.c_allocator, compressed_icc) catch return 0;
	defer std.heap.c_allocator.free(icc);

	return if (exportOwnedBytes(memory_manager, icc, icc_out, size_out)) 1 else 0;
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
	if (impl.owned_codestream.len != 0) std.heap.c_allocator.free(impl.owned_codestream);
	if (impl.owned_icc.len != 0) std.heap.c_allocator.free(impl.owned_icc);
	if (impl.owned_boxes.len != 0) {
		for (impl.owned_boxes) |*box| box.deinit(std.heap.c_allocator);
		std.heap.c_allocator.free(impl.owned_boxes);
	}
	impl.* = .{};
	impl.memory_manager = mm;
}

pub export fn JxlDecoderDestroy(dec_ptr: ?*JxlDecoder) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	freeDecoder(impl);
}

pub export fn JxlDecoderRewind(dec_ptr: ?*JxlDecoder) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.input_data = null;
	impl.input_size = 0;
	impl.input_closed = false;
	impl.input_released = false;
	impl.started_processing = false;
	impl.basic_info_emitted = false;
	impl.color_encoding_emitted = false;
	resetFrameIteration(impl);
}

pub export fn JxlDecoderSkipFrames(dec_ptr: ?*JxlDecoder, amount: usize) void {
	const dec = dec_ptr orelse return;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.frames_to_skip +|= amount;
}

pub export fn JxlDecoderSkipCurrentFrame(dec_ptr: ?*JxlDecoder) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.frame_parsed or impl.full_image_emitted or impl.decode_complete) return .JXL_DEC_ERROR;
	advanceCurrentFrame(impl);
	return .JXL_DEC_SUCCESS;
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

pub export fn JxlDecoderSetBoxBuffer(dec_ptr: ?*JxlDecoder, data: ?[*]u8, size: usize) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.box_buffer != null) return .JXL_DEC_ERROR;
	if (size != 0 and data == null) return .JXL_DEC_ERROR;
	impl.box_buffer = data;
	impl.box_buffer_size = size;
	impl.box_buffer_written = 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderReleaseBoxBuffer(dec_ptr: ?*JxlDecoder) usize {
	const dec = dec_ptr orelse return 0;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	if (impl.box_buffer == null) return 0;
	const remaining = impl.box_buffer_size - impl.box_buffer_written;
	impl.box_buffer = null;
	impl.box_buffer_size = 0;
	impl.box_buffer_written = 0;
	return remaining;
}

pub export fn JxlDecoderSetDecompressBoxes(dec_ptr: ?*JxlDecoder, decompress: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	impl.decompress_boxes = decompress != 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetBoxType(dec_ptr: ?*JxlDecoder, type_ptr: ?[*]u8, decompressed: JXL_BOOL) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *DecoderImpl = @ptrCast(@alignCast(dec));
	const box_type = type_ptr orelse return .JXL_DEC_ERROR;
	const box = currentBox(impl) orelse return .JXL_DEC_ERROR;
	const effective = box.effectiveBoxType(decompressed != 0) catch return .JXL_DEC_ERROR;
	@memcpy(box_type[0..4], &effective);
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetBoxSizeRaw(dec_ptr: ?*const JxlDecoder, size_ptr: ?*u64) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	const size = size_ptr orelse return .JXL_DEC_ERROR;
	const box = currentBox(impl) orelse return .JXL_DEC_ERROR;
	size.* = box.raw_size;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetBoxSizeContents(dec_ptr: ?*const JxlDecoder, size_ptr: ?*u64) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	const size = size_ptr orelse return .JXL_DEC_ERROR;
	const box = currentBox(impl) orelse return .JXL_DEC_ERROR;
	size.* = box.contents.len;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetBasicInfo(dec_ptr: ?*const JxlDecoder, info: ?*JxlBasicInfo) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;
	if (info) |dst| dst.* = impl.basic_info;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetExtraChannelInfo(
	dec_ptr: ?*const JxlDecoder,
	index: usize,
	info_ptr: ?*JxlExtraChannelInfo,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	const info = info_ptr orelse return .JXL_DEC_ERROR;
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;
	if (index >= impl.codec_meta.m.num_extra_channels) return .JXL_DEC_ERROR;
	populateExtraChannelInfo(info, &impl.codec_meta.m.extra_channel_info[index]);
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetExtraChannelName(
	dec_ptr: ?*const JxlDecoder,
	index: usize,
	name_ptr: ?[*]u8,
	size: usize,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;
	if (index >= impl.codec_meta.m.num_extra_channels) return .JXL_DEC_ERROR;

	const extra = &impl.codec_meta.m.extra_channel_info[index];
	if (size < extra.name.len + 1) return .JXL_DEC_ERROR;
	const name = name_ptr orelse return .JXL_DEC_ERROR;
	@memcpy(name[0..extra.name.len], extra.name);
	name[extra.name.len] = 0;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetColorAsEncodedProfile(
	dec_ptr: ?*const JxlDecoder,
	target: JxlColorProfileTarget,
	color_ptr: ?*JxlColorEncoding,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;

	switch (target) {
		.JXL_COLOR_PROFILE_TARGET_ORIGINAL, .JXL_COLOR_PROFILE_TARGET_DATA => {},
	}

	const color = &impl.codec_meta.m.color_encoding;
	if (color.want_icc) return .JXL_DEC_ERROR;
	if (color_ptr) |dst| populateColorEncoding(dst, color);
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetICCProfileSize(
	dec_ptr: ?*const JxlDecoder,
	target: JxlColorProfileTarget,
	size_ptr: ?*usize,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;

	switch (target) {
		.JXL_COLOR_PROFILE_TARGET_ORIGINAL, .JXL_COLOR_PROFILE_TARGET_DATA => {},
	}

	const profile = if (impl.codec_meta.m.color_encoding.want_icc)
		impl.codec_meta.embedded_icc
	else
		icc_profiles.originalProfile(&impl.codec_meta.m.color_encoding) orelse return .JXL_DEC_ERROR;
	if (size_ptr) |dst| dst.* = profile.len;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetColorAsICCProfile(
	dec_ptr: ?*const JxlDecoder,
	target: JxlColorProfileTarget,
	icc_profile: ?[*]u8,
	size: usize,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.basic_info_available) return .JXL_DEC_NEED_MORE_INPUT;

	switch (target) {
		.JXL_COLOR_PROFILE_TARGET_ORIGINAL, .JXL_COLOR_PROFILE_TARGET_DATA => {},
	}

	const profile = if (impl.codec_meta.m.color_encoding.want_icc)
		impl.codec_meta.embedded_icc
	else
		icc_profiles.originalProfile(&impl.codec_meta.m.color_encoding) orelse return .JXL_DEC_ERROR;
	if (size < profile.len) return .JXL_DEC_ERROR;
	const dst = icc_profile orelse return .JXL_DEC_ERROR;
	@memcpy(dst[0..profile.len], profile);
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetFrameHeader(dec_ptr: ?*const JxlDecoder, header_ptr: ?*JxlFrameHeader) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.frame_parsed) return .JXL_DEC_NEED_MORE_INPUT;
	if (header_ptr) |dst| dst.* = impl.frame_header;
	return .JXL_DEC_SUCCESS;
}

pub export fn JxlDecoderGetFrameName(
	dec_ptr: ?*const JxlDecoder,
	name_ptr: ?[*]u8,
	size: usize,
) JxlDecoderStatus {
	const dec = dec_ptr orelse return .JXL_DEC_ERROR;
	const impl: *const DecoderImpl = @ptrCast(@alignCast(dec));
	if (!impl.frame_parsed) return .JXL_DEC_NEED_MORE_INPUT;
	if (size < impl.frame_name_len + 1) return .JXL_DEC_ERROR;
	const name = name_ptr orelse return .JXL_DEC_ERROR;
	if (impl.frame_name_len != 0) {
		@memcpy(name[0..impl.frame_name_len], impl.frame_name_buf[0..impl.frame_name_len]);
	}
	name[impl.frame_name_len] = 0;
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

	while (true) {
		const parse_status = ensureParsed(impl);
		if (parse_status != .JXL_DEC_SUCCESS) return parse_status;

		if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_BOX)) != 0) {
			if (currentBox(impl) != null) {
				const box_status = ensureCurrentBoxPrepared(impl);
				if (box_status != .JXL_DEC_SUCCESS) return box_status;
				if (!impl.box_header_emitted) {
					impl.box_header_emitted = true;
					return .JXL_DEC_BOX;
				}
				const box = currentBox(impl).?;
				const contents = box.effectiveContents(impl.decompress_boxes);
				if (impl.box_bytes_emitted < contents.len) {
					if (impl.box_buffer == null) {
						advanceCurrentBox(impl);
						continue;
					}
					const remaining = contents.len - impl.box_bytes_emitted;
					const to_copy = @min(remaining, impl.box_buffer_size);
					@memcpy(
						impl.box_buffer.?[0..to_copy],
						contents[impl.box_bytes_emitted .. impl.box_bytes_emitted + to_copy],
					);
					impl.box_bytes_emitted += to_copy;
					impl.box_buffer_written = to_copy;
					if (impl.box_bytes_emitted < contents.len) return .JXL_DEC_BOX_NEED_MORE_OUTPUT;
				}
				if (
					impl.box_buffer != null and
					(impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_BOX_COMPLETE)) != 0 and
					!impl.box_complete_emitted
				) {
					impl.box_complete_emitted = true;
					return .JXL_DEC_BOX_COMPLETE;
				}
				advanceCurrentBox(impl);
				continue;
			}
		}

		if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO)) != 0 and !impl.basic_info_emitted) {
			impl.basic_info_emitted = true;
			return .JXL_DEC_BASIC_INFO;
		}

		if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_COLOR_ENCODING)) != 0 and !impl.color_encoding_emitted) {
			impl.color_encoding_emitted = true;
			return .JXL_DEC_COLOR_ENCODING;
		}

		const frame_status = ensureCurrentFrameParsed(impl);
		if (frame_status != .JXL_DEC_SUCCESS) return frame_status;
		if (!impl.frame_parsed) return .JXL_DEC_SUCCESS;
		if (impl.frames_to_skip != 0) {
			impl.frames_to_skip -= 1;
			advanceCurrentFrame(impl);
			continue;
		}

		if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME)) != 0 and !impl.frame_emitted) {
			impl.frame_emitted = true;
			return .JXL_DEC_FRAME;
		}

		if (impl.output_buffer == null) {
			if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE)) == 0) {
				advanceCurrentFrame(impl);
				continue;
			}
			return .JXL_DEC_NEED_IMAGE_OUT_BUFFER;
		}

		const decode_status = ensureDecoded(impl);
		if (decode_status != .JXL_DEC_SUCCESS) return decode_status;

		if ((impl.subscribed_events & @intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE)) != 0 and !impl.full_image_emitted) {
			impl.full_image_emitted = true;
			return .JXL_DEC_FULL_IMAGE;
		}

		advanceCurrentFrame(impl);
	}
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
	var initial = EncoderFrameSettingsImpl{ .owner = impl };
	if (source_ptr) |source| {
		const source_impl: *const EncoderFrameSettingsImpl = @ptrCast(@alignCast(source));
		if (source_impl.owner != impl) return null;
		initial.frame_header_set = source_impl.frame_header_set;
		initial.frame_header = source_impl.frame_header;
	}

	const settings = std.heap.c_allocator.create(EncoderFrameSettingsImpl) catch return null;
	errdefer std.heap.c_allocator.destroy(settings);
	settings.* = initial;
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
	if (impl.started_processing or impl.added_frame or impl.frames_closed) return .JXL_ENC_ERROR;
	validateBasicInfoForSimpleEncode(src) catch return .JXL_ENC_ERROR;
	impl.basic_info = src.*;
	impl.basic_info_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetColorEncoding(enc_ptr: ?*JxlEncoder, color_ptr: ?*const JxlColorEncoding) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const color = color_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame or impl.frames_closed) return .JXL_ENC_ERROR;
	const internal = toInternalColorEncoding(color, impl.basic_info.num_color_channels) catch return .JXL_ENC_ERROR;
	impl.color_encoding = color.*;
	impl.internal_color_encoding = internal;
	impl.color_encoding_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderSetICCProfile(
	enc_ptr: ?*JxlEncoder,
	icc_profile_ptr: ?[*]const u8,
	size: usize,
) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const icc_profile = icc_profile_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or impl.color_encoding_set or impl.started_processing or impl.added_frame or impl.frames_closed) return .JXL_ENC_ERROR;
	if (size == 0 or size >= (1 << 28)) return .JXL_ENC_ERROR;

	const icc = icc_profile[0..size];
	const shape = classifyIccEmbeddingShape(icc) catch return .JXL_ENC_ERROR;
	if (shape.main_color_channels != impl.basic_info.num_color_channels) return .JXL_ENC_ERROR;
	if (shape.requires_black_extra and !hasStagedBlackExtraChannel(impl)) return .JXL_ENC_ERROR;

	if (impl.owned_icc.len != 0) {
		std.heap.c_allocator.free(impl.owned_icc);
		impl.owned_icc = &.{};
	}
	impl.owned_icc = std.heap.c_allocator.dupe(u8, icc) catch return .JXL_ENC_ERROR;
	impl.internal_color_encoding = internalIccColorEncoding(shape.main_color_channels);
	impl.color_encoding = defaultJxlColorEncoding(shape.main_color_channels == 1, false);
	impl.color_encoding_set = true;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderUseBoxes(enc_ptr: ?*JxlEncoder) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame or impl.use_boxes) return .JXL_ENC_ERROR;
	impl.use_boxes = true;
	impl.boxes_closed = false;
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderAddBox(
	enc_ptr: ?*JxlEncoder,
	box_type_ptr: ?[*]const u8,
	contents_ptr: ?[*]const u8,
	size: usize,
	compress_box: JXL_BOOL,
) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const box_type = box_type_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.use_boxes or impl.boxes_closed or impl.started_processing) return .JXL_ENC_ERROR;

	var box_name: [4]u8 = undefined;
	@memcpy(&box_name, box_type[0..4]);
	if (std.mem.eql(u8, &box_name, "JXL ") or std.mem.eql(u8, &box_name, "ftyp") or
		std.mem.eql(u8, &box_name, "jxlc") or std.mem.eql(u8, &box_name, "jxlp") or
		std.mem.eql(u8, &box_name, "jxll") or std.mem.eql(u8, &box_name, "jbrd") or
		std.mem.eql(u8, &box_name, "brob"))
	{
		return .JXL_ENC_ERROR;
	}

	const contents = if (size == 0)
		&[_]u8{}
	else blk: {
		const ptr = contents_ptr orelse return .JXL_ENC_ERROR;
		break :blk ptr[0..size];
	};

	var stored_box_type = box_name;
	const owned = if (compress_box != 0) blk: {
		const compressed = brotli.compress(std.heap.c_allocator, contents) catch return .JXL_ENC_ERROR;
		defer std.heap.c_allocator.free(compressed);
		const payload = std.heap.c_allocator.alloc(u8, compressed.len + 4) catch return .JXL_ENC_ERROR;
		@memcpy(payload[0..4], &box_name);
		@memcpy(payload[4..], compressed);
		stored_box_type = .{ 'b', 'r', 'o', 'b' };
		break :blk payload;
	} else std.heap.c_allocator.dupe(u8, contents) catch return .JXL_ENC_ERROR;
	impl.staged_boxes.append(std.heap.c_allocator, .{
		.box_type = stored_box_type,
		.contents = owned,
	}) catch {
		std.heap.c_allocator.free(owned);
		return .JXL_ENC_ERROR;
	};
	return .JXL_ENC_SUCCESS;
}

pub export fn JxlEncoderCloseBoxes(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	if (!impl.use_boxes or impl.started_processing) return;
	impl.boxes_closed = true;
}

pub export fn JxlEncoderSetExtraChannelInfo(
	enc_ptr: ?*JxlEncoder,
	index: usize,
	info_ptr: ?*const JxlExtraChannelInfo,
) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const info = info_ptr orelse return .JXL_ENC_ERROR;
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame or impl.frames_closed) return .JXL_ENC_ERROR;
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
	if (!impl.basic_info_set or impl.started_processing or impl.added_frame or impl.frames_closed) return .JXL_ENC_ERROR;
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

pub export fn JxlEncoderSetFrameHeader(
	frame_settings_ptr: ?*JxlEncoderFrameSettings,
	frame_header_ptr: ?*const JxlFrameHeader,
) JxlEncoderStatus {
	const frame_settings = frame_settings_ptr orelse return .JXL_ENC_ERROR;
	const settings_impl: *EncoderFrameSettingsImpl = @ptrCast(@alignCast(frame_settings));
	const frame_header = frame_header_ptr orelse return .JXL_ENC_ERROR;
	if (settings_impl.owner.started_processing or settings_impl.owner.frames_closed) return .JXL_ENC_ERROR;
	settings_impl.frame_header = frame_header.*;
	settings_impl.frame_header_set = true;
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

	if (!impl.basic_info_set or !impl.color_encoding_set or impl.frames_closed or impl.started_processing) return .JXL_ENC_ERROR;
	if (format.data_type != .JXL_TYPE_UINT8) return .JXL_ENC_ERROR;

	const min_channels = impl.basic_info.num_color_channels;
	const max_channels = min_channels + @as(u32, @intFromBool(impl.basic_info.alpha_bits != 0));
	if (format.num_channels < min_channels or format.num_channels > max_channels) return .JXL_ENC_ERROR;
	if (
		impl.basic_info.alpha_bits != 0 and
		format.num_channels == max_channels and
		impl.pending_extra_channels[0].info_set and
		impl.pending_extra_channels[0].info.dim_shift != 0
	) return .JXL_ENC_ERROR;
	if (settings_impl.frame_header_set) {
		validateFrameHeaderForSimpleEncode(&impl.basic_info, &settings_impl.frame_header) catch return .JXL_ENC_ERROR;
	}

	const stride = rowStrideBytes(impl.basic_info.xsize, format.*) orelse return .JXL_ENC_ERROR;
	const needed = stride * impl.basic_info.ysize;
	if (size < needed) return .JXL_ENC_ERROR;

	queuePendingFrame(impl) catch return .JXL_ENC_ERROR;
	const pixels: [*]const u8 = @ptrCast(data);
	impl.image_bytes = std.heap.c_allocator.dupe(u8, pixels[0..needed]) catch return .JXL_ENC_ERROR;
	impl.image_format = format.*;
	impl.pending_frame_header_set = settings_impl.frame_header_set;
	impl.pending_frame_header = settings_impl.frame_header;
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
	if (!impl.basic_info_set or !impl.color_encoding_set or impl.image_bytes.len == 0 or impl.started_processing or impl.frames_closed) return .JXL_ENC_ERROR;
	if (index >= impl.basic_info.num_extra_channels) return .JXL_ENC_ERROR;

	const pending = &impl.pending_extra_channels[index];
	const is_staged_alpha = impl.basic_info.alpha_bits != 0 and index == 0;
	if (!is_staged_alpha and !pending.info_set) return .JXL_ENC_ERROR;
	if (format.data_type != .JXL_TYPE_UINT8) return .JXL_ENC_ERROR;

	var extra_format = format.*;
	extra_format.num_channels = 1;
	const dim_shift = if (is_staged_alpha and !pending.info_set) 0 else pending.info.dim_shift;
	const plane_width: u32 = @intCast(subsampledSize(impl.basic_info.xsize, dim_shift));
	const plane_height: usize = subsampledSize(impl.basic_info.ysize, dim_shift);
	const stride = rowStrideBytes(plane_width, extra_format) orelse return .JXL_ENC_ERROR;
	const needed = stride * plane_height;
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

pub export fn JxlEncoderCloseFrames(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	if (impl.started_processing) return;
	queuePendingFrame(impl) catch return;
	impl.frames_closed = true;
}

pub export fn JxlEncoderCloseInput(enc_ptr: ?*JxlEncoder) void {
	const enc = enc_ptr orelse return;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	queuePendingFrame(impl) catch return;
	if (impl.use_boxes) impl.boxes_closed = true;
	impl.frames_closed = true;
	impl.input_closed = true;
}

pub export fn JxlEncoderProcessOutput(enc_ptr: ?*JxlEncoder, next_out_ptr: ?*[*]u8, avail_out_ptr: ?*usize) JxlEncoderStatus {
	const enc = enc_ptr orelse return .JXL_ENC_ERROR;
	const impl: *EncoderImpl = @ptrCast(@alignCast(enc));
	const next_out = next_out_ptr orelse return .JXL_ENC_ERROR;
	const avail_out = avail_out_ptr orelse return .JXL_ENC_ERROR;
	impl.started_processing = true;

	if (!(impl.input_closed or impl.frames_closed) or !impl.added_frame) return .JXL_ENC_ERROR;
	if (impl.use_boxes and !impl.boxes_closed) return .JXL_ENC_ERROR;
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

test "JxlEncoderProcessOutput rejects unclosed metadata boxes" {
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = std.mem.zeroes(JxlBasicInfo);
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 1;
	try std.testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color: JxlColorEncoding = undefined;
	JxlColorEncodingSetToSRGB(&color, 1);
	try std.testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));
	try std.testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderUseBoxes(enc));
	try std.testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddBox(enc, "xml ", "<x/>", 4, 0),
	);

	const pixels = [_]u8{0x7F};
	const format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	try std.testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));

	var output: [256]u8 = undefined;
	var next_out: [*]u8 = &output;
	var avail_out: usize = output.len;
	try std.testing.expectEqual(JxlEncoderStatus.JXL_ENC_ERROR, JxlEncoderProcessOutput(enc, &next_out, &avail_out));
}

test "JxlEncoderSetICCProfile round-trips exact builtin sRGB ICC bytes" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, icc_profiles.srgb_builtin_profile[0..].ptr, icc_profiles.srgb_builtin_profile.len),
	);

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_COLOR_ENCODING),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var saw_color = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_COLOR_ENCODING => {
				saw_color = true;
				try testing.expectEqual(
					JxlDecoderStatus.JXL_DEC_ERROR,
					JxlDecoderGetColorAsEncodedProfile(dec, .JXL_COLOR_PROFILE_TARGET_ORIGINAL, null),
				);

				var original_size: usize = 0;
				try testing.expectEqual(
					JxlDecoderStatus.JXL_DEC_SUCCESS,
					JxlDecoderGetICCProfileSize(dec, .JXL_COLOR_PROFILE_TARGET_ORIGINAL, &original_size),
				);
				try testing.expectEqual(icc_profiles.srgb_builtin_profile.len, original_size);

				var data_size: usize = 0;
				try testing.expectEqual(
					JxlDecoderStatus.JXL_DEC_SUCCESS,
					JxlDecoderGetICCProfileSize(dec, .JXL_COLOR_PROFILE_TARGET_DATA, &data_size),
				);
				try testing.expectEqual(icc_profiles.srgb_builtin_profile.len, data_size);

				const original = try testing.allocator.alloc(u8, original_size);
				defer testing.allocator.free(original);
				try testing.expectEqual(
					JxlDecoderStatus.JXL_DEC_SUCCESS,
					JxlDecoderGetColorAsICCProfile(dec, .JXL_COLOR_PROFILE_TARGET_ORIGINAL, original.ptr, original.len),
				);
				try testing.expectEqualSlices(u8, icc_profiles.srgb_builtin_profile[0..], original);

				const data = try testing.allocator.alloc(u8, data_size);
				defer testing.allocator.free(data);
				try testing.expectEqual(
					JxlDecoderStatus.JXL_DEC_SUCCESS,
					JxlDecoderGetColorAsICCProfile(dec, .JXL_COLOR_PROFILE_TARGET_DATA, data.ptr, data.len),
				);
				try testing.expectEqualSlices(u8, icc_profiles.srgb_builtin_profile[0..], data);
			},
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expect(saw_color);
}

test "embedded ICC codestream reaches full-image decode" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, icc_profiles.srgb_builtin_profile[0..].ptr, icc_profiles.srgb_builtin_profile.len),
	);

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output = std.mem.zeroes([12]u8);
	var saw_need_out = false;
	var saw_full = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				saw_need_out = true;
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => saw_full = true,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expect(saw_need_out);
	try testing.expect(saw_full);
	try testing.expectEqualSlices(u8, &pixels, &output);
}

test "synthetic embedded RGB ICC codestream reaches full-image decode" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	const synthetic_icc = makeSyntheticIccHeader(.{ 'R', 'G', 'B', ' ' });
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, synthetic_icc[0..].ptr, synthetic_icc.len),
	);

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output = std.mem.zeroes([12]u8);
	var saw_need_out = false;
	var saw_full = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				saw_need_out = true;
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => saw_full = true,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expect(saw_need_out);
	try testing.expect(saw_full);
	try testing.expectEqualSlices(u8, &pixels, &output);
}

test "builtin embedded ICC codestream reaches full-image decode with original-profile flag" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, icc_profiles.srgb_builtin_profile[0..].ptr, icc_profiles.srgb_builtin_profile.len),
	);

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output = std.mem.zeroes([12]u8);
	var saw_need_out = false;
	var saw_full = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				saw_need_out = true;
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => saw_full = true,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expect(saw_need_out);
	try testing.expect(saw_full);
	try testing.expectEqualSlices(u8, &pixels, &output);
}

test "synthetic embedded RGB ICC codestream frame header parses after metadata and ICC" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	const synthetic_icc = makeSyntheticIccHeader(.{ 'R', 'G', 'B', ' ' });
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, synthetic_icc[0..].ptr, synthetic_icc.len),
	);

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
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
	const embedded_icc = try icc_codec.decompressICCFromBitReader(testing.allocator, &br);
	defer testing.allocator.free(embedded_icc);
	try br.jumpToByteBoundary();
	const frame_header_byte_offset = br.totalBitsConsumed() / 8;
	try br.close();

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;
	codec_meta.embedded_icc = embedded_icc;

	const frame_bytes = encoded.items[2 + frame_header_byte_offset ..];
	_ = try dec_frame.frameByteCount(testing.allocator, &codec_meta, frame_bytes);
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	var header_br = BitReader.init(frame_bytes);
	try frame_dec.initFrame(&header_br);
	try header_br.close();
}

test "JxlEncoderSetICCProfile rejects ICC with mismatched declared size" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var bad_icc = icc_profiles.srgb_builtin_profile;
	bad_icc[0] = 0;
	bad_icc[1] = 0;
	bad_icc[2] = 0x01;
	bad_icc[3] = 0x00;

	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_ERROR,
		JxlEncoderSetICCProfile(enc, bad_icc[0..].ptr, bad_icc.len),
	);
}

test "JxlEncoderSetICCProfile rejects undersized ICC header" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	const short_icc = [_]u8{
		0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 'm', 'n', 't', 'r',
		'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ',
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 'a', 'c', 's', 'p',
	};

	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_ERROR,
		JxlEncoderSetICCProfile(enc, short_icc[0..].ptr, short_icc.len),
	);
}

test "JxlEncoderSetICCProfile accepts CMYK ICC with black extra channel" {
	const testing = std.testing;
	const cmyk_icc = try icc_codec.decompressICC(
		testing.allocator,
		icc_test_fixtures.cmyk_test_icc_compressed[0..],
	);
	defer testing.allocator.free(cmyk_icc);
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var black: JxlExtraChannelInfo = undefined;
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_BLACK, &black);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &black));

	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, cmyk_icc.ptr, cmyk_icc.len),
	);
}

test "JxlEncoderSetICCProfile rejects CMYK ICC without a staged black extra channel" {
	const testing = std.testing;
	const cmyk_icc = try icc_codec.decompressICC(
		testing.allocator,
		icc_test_fixtures.cmyk_test_icc_compressed[0..],
	);
	defer testing.allocator.free(cmyk_icc);
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var mask: JxlExtraChannelInfo = undefined;
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SELECTION_MASK, &mask);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &mask));

	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_ERROR,
		JxlEncoderSetICCProfile(enc, cmyk_icc.ptr, cmyk_icc.len),
	);
}

/// Builds a minimal header-only ICC payload for API tests that only exercise
/// public header classification, keeping channel-shape coverage hermetic.
fn makeSyntheticIccHeader(data_color_space: [4]u8) [128]u8 {
	var icc = std.mem.zeroes([128]u8);
	icc[0] = 0x00;
	icc[1] = 0x00;
	icc[2] = 0x00;
	icc[3] = 0x80;
	icc[12] = 'm';
	icc[13] = 'n';
	icc[14] = 't';
	icc[15] = 'r';
	@memcpy(icc[16..20], &data_color_space);
	icc[20] = 'X';
	icc[21] = 'Y';
	icc[22] = 'Z';
	icc[23] = ' ';
	icc[36] = 'a';
	icc[37] = 'c';
	icc[38] = 's';
	icc[39] = 'p';
	return icc;
}

test "JxlEncoderSetICCProfile accepts Lab ICC with three color channels" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	const lab_icc = makeSyntheticIccHeader(.{ 'L', 'a', 'b', ' ' });
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, lab_icc[0..].ptr, lab_icc.len),
	);
}

test "JxlEncoderSetICCProfile accepts XYZ ICC with three color channels" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	const xyz_icc = makeSyntheticIccHeader(.{ 'X', 'Y', 'Z', ' ' });
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetICCProfile(enc, xyz_icc[0..].ptr, xyz_icc.len),
	);
}

test "JxlEncoderSetICCProfile rejects generic four-channel ICC without a CMYK mapping" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.uses_original_profile = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var black: JxlExtraChannelInfo = undefined;
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_BLACK, &black);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &black));

	const four_channel_icc = makeSyntheticIccHeader(.{ '4', 'C', 'L', 'R' });
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_ERROR,
		JxlEncoderSetICCProfile(enc, four_channel_icc[0..].ptr, four_channel_icc.len),
	);
}

test "JxlICCProfileEncode and JxlICCProfileDecode round-trip builtin sRGB ICC bytes" {
	const testing = std.testing;

	var compressed_ptr: ?[*]u8 = null;
	var compressed_size: usize = 0;
	try testing.expectEqual(
		@as(JXL_BOOL, 1),
		JxlICCProfileEncode(null, icc_profiles.srgb_builtin_profile[0..].ptr, icc_profiles.srgb_builtin_profile.len, @ptrCast(&compressed_ptr), &compressed_size),
	);
	defer std.heap.c_allocator.free(compressed_ptr.?[0..compressed_size]);
	try testing.expect(compressed_size != 0);

	var decoded_ptr: ?[*]u8 = null;
	var decoded_size: usize = 0;
	try testing.expectEqual(
		@as(JXL_BOOL, 1),
		JxlICCProfileDecode(null, compressed_ptr.?, compressed_size, @ptrCast(&decoded_ptr), &decoded_size),
	);
	defer std.heap.c_allocator.free(decoded_ptr.?[0..decoded_size]);

	try testing.expectEqual(icc_profiles.srgb_builtin_profile.len, decoded_size);
	try testing.expectEqualSlices(u8, icc_profiles.srgb_builtin_profile[0..], decoded_ptr.?[0..decoded_size]);
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

test "writeRenderedImageToOutput scales float RGB rows to uint8 output" {
	const allocator = std.testing.allocator;
	var rendered = try render_mod.FloatImage.init(allocator, 2, 1, 3);
	defer rendered.deinit();
	rendered.row(0, 0)[0] = 0.0;
	rendered.row(0, 1)[0] = 512.0;
	rendered.row(0, 2)[0] = 1023.0;
	rendered.row(0, 0)[1] = 1023.0;
	rendered.row(0, 1)[1] = -10.0;
	rendered.row(0, 2)[1] = 2048.0;

	var metadata = image_metadata.ImageMetadata{};
	metadata.bit_depth.bits_per_sample = 10;
	metadata.color_encoding.color_space = .rgb;

	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	var buffer: [6]u8 = undefined;
	try writeRenderedImageToOutput(&rendered, null, &metadata, format, buffer[0..].ptr, buffer.len);
	try std.testing.expectEqualSlices(u8, &.{ 0, 128, 255, 255, 0, 255 }, &buffer);
}

test "writeFrameDecoderOutput prefers non-XYB rendered image over modular fallback" {
	const allocator = std.testing.allocator;
	var metadata = image_metadata.CodecMetadata{};
	metadata.m.xyb_encoded = false;
	metadata.m.bit_depth.bits_per_sample = 8;
	metadata.m.color_encoding.color_space = .rgb;
	var frame_dec = dec_frame.FrameDecoder.init(allocator, &metadata);
	defer frame_dec.deinit();
	frame_dec.frame_header.color_transform = .none;
	frame_dec.modular_decoder.full_image.deinit();
	frame_dec.modular_decoder.full_image = try Image.create(allocator, 1, 1, 8, 3);
	frame_dec.modular_decoder.full_image.channels.items[0].row(0)[0] = 10;
	frame_dec.modular_decoder.full_image.channels.items[1].row(0)[0] = 20;
	frame_dec.modular_decoder.full_image.channels.items[2].row(0)[0] = 30;
	frame_dec.rendered_image = try render_mod.FloatImage.init(allocator, 1, 1, 3);
	frame_dec.rendered_image.?.row(0, 0)[0] = 1.0;
	frame_dec.rendered_image.?.row(0, 1)[0] = 2.0;
	frame_dec.rendered_image.?.row(0, 2)[0] = 3.0;

	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	var buffer: [3]u8 = undefined;
	try writeFrameDecoderOutput(&frame_dec, &metadata.m, format, buffer[0..].ptr, buffer.len);
	try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &buffer);
}

test "writeFrameDecoderOutput keeps XYB rendered image unsupported until color conversion lands" {
	const allocator = std.testing.allocator;
	var metadata = image_metadata.CodecMetadata{};
	metadata.m.xyb_encoded = true;
	metadata.m.bit_depth.bits_per_sample = 8;
	metadata.m.color_encoding.color_space = .rgb;
	var frame_dec = dec_frame.FrameDecoder.init(allocator, &metadata);
	defer frame_dec.deinit();
	frame_dec.frame_header.color_transform = .xyb;
	frame_dec.modular_decoder.full_image.deinit();
	frame_dec.modular_decoder.full_image = try Image.create(allocator, 1, 1, 8, 3);
	frame_dec.rendered_image = try render_mod.FloatImage.init(allocator, 1, 1, 3);

	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	var buffer: [3]u8 = undefined;
	try std.testing.expectError(error.Unsupported, writeFrameDecoderOutput(&frame_dec, &metadata.m, format, buffer[0..].ptr, buffer.len));
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

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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

test "prepareSimplePackedInput splits RGBA plus sidecar extra into encoder planes" {
	const testing = std.testing;

	var impl = EncoderImpl{};
	defer clearPendingEncodeBuffers(&impl);

	impl.basic_info = std.mem.zeroes(JxlBasicInfo);
	impl.basic_info.xsize = 2;
	impl.basic_info.ysize = 2;
	impl.basic_info.bits_per_sample = 8;
	impl.basic_info.num_color_channels = 3;
	impl.basic_info.num_extra_channels = 2;
	impl.basic_info.alpha_bits = 8;
	impl.image_format = .{
		.num_channels = 4,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	const rgba_pixels = [_]u8{
		0, 10, 20, 255, 30, 40, 50, 128,
		60, 70, 80, 64, 90, 100, 110, 0,
	};
	impl.image_bytes = try std.heap.c_allocator.dupe(u8, &rgba_pixels);

	impl.pending_extra_channels[1].info = std.mem.zeroes(JxlExtraChannelInfo);
	impl.pending_extra_channels[1].info.type = .JXL_CHANNEL_SELECTION_MASK;
	impl.pending_extra_channels[1].info.bits_per_sample = 8;
	impl.pending_extra_channels[1].info_set = true;
	impl.pending_extra_channels[1].name_len = 4;
	@memcpy(impl.pending_extra_channels[1].name_buf[0..4], "mask");
	impl.pending_extra_channels[1].buffer = try std.heap.c_allocator.dupe(u8, &[_]u8{ 0, 255, 255, 0 });
	impl.pending_extra_channels[1].row_stride = 2;
	impl.pending_extra_channels[1].buffer_set = true;

	var prepared = try prepareSimplePackedInput(std.heap.c_allocator, &impl);
	defer prepared.deinit(std.heap.c_allocator);

	try testing.expectEqual(@as(usize, 6), prepared.color_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	}, prepared.color_pixels);
	try testing.expectEqual(@as(usize, 2), prepared.alpha_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{ 255, 128, 64, 0 }, prepared.alpha_pixels);
	try testing.expectEqual(@as(usize, 1), prepared.extra_planes.len);
	try testing.expectEqual(image_metadata.ExtraChannel.selection_mask, prepared.extra_planes[0].info.type);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 255, 0 }, prepared.extra_planes[0].pixels);
}

test "prepareSimplePackedInput splits RGB plus staged alpha into encoder planes" {
	const testing = std.testing;

	var impl = EncoderImpl{};
	defer clearPendingEncodeBuffers(&impl);

	impl.basic_info = std.mem.zeroes(JxlBasicInfo);
	impl.basic_info.xsize = 2;
	impl.basic_info.ysize = 2;
	impl.basic_info.bits_per_sample = 8;
	impl.basic_info.num_color_channels = 3;
	impl.basic_info.num_extra_channels = 1;
	impl.basic_info.alpha_bits = 8;
	impl.image_format = .{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	impl.image_bytes = try std.heap.c_allocator.dupe(u8, &[_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	});
	impl.pending_extra_channels[0].buffer = try std.heap.c_allocator.dupe(u8, &[_]u8{ 255, 128, 64, 0 });
	impl.pending_extra_channels[0].row_stride = 2;
	impl.pending_extra_channels[0].buffer_set = true;

	var prepared = try prepareSimplePackedInput(std.heap.c_allocator, &impl);
	defer prepared.deinit(std.heap.c_allocator);

	try testing.expectEqual(@as(usize, 6), prepared.color_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	}, prepared.color_pixels);
	try testing.expectEqual(@as(usize, 2), prepared.alpha_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{ 255, 128, 64, 0 }, prepared.alpha_pixels);
	try testing.expectEqual(@as(usize, 0), prepared.extra_planes.len);
}

test "prepareSimplePackedInput keeps staged subsampled alpha dimensions" {
	const testing = std.testing;

	var impl = EncoderImpl{};
	defer clearPendingEncodeBuffers(&impl);

	impl.basic_info = std.mem.zeroes(JxlBasicInfo);
	impl.basic_info.xsize = 4;
	impl.basic_info.ysize = 2;
	impl.basic_info.bits_per_sample = 8;
	impl.basic_info.num_color_channels = 3;
	impl.basic_info.num_extra_channels = 1;
	impl.basic_info.alpha_bits = 8;
	impl.image_format = .{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	impl.image_bytes = try std.heap.c_allocator.dupe(u8, &[_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	});
	impl.pending_extra_channels[0].info = std.mem.zeroes(JxlExtraChannelInfo);
	impl.pending_extra_channels[0].info.type = .JXL_CHANNEL_ALPHA;
	impl.pending_extra_channels[0].info.bits_per_sample = 8;
	impl.pending_extra_channels[0].info.dim_shift = 1;
	impl.pending_extra_channels[0].info_set = true;
	impl.pending_extra_channels[0].buffer = try std.heap.c_allocator.dupe(u8, &[_]u8{ 200, 50 });
	impl.pending_extra_channels[0].row_stride = 2;
	impl.pending_extra_channels[0].buffer_set = true;

	var prepared = try prepareSimplePackedInput(std.heap.c_allocator, &impl);
	defer prepared.deinit(std.heap.c_allocator);

	try testing.expectEqual(@as(usize, 12), prepared.color_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	}, prepared.color_pixels);
	try testing.expectEqual(@as(usize, 2), prepared.alpha_row_stride);
	try testing.expectEqualSlices(u8, &[_]u8{ 200, 50 }, prepared.alpha_pixels);
	try testing.expectEqual(@as(usize, 0), prepared.extra_planes.len);
}

test "JxlEncoder encodes a staged alpha buffer" {
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
	info.alpha_bits = 8;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

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

	const alpha_pixels = [_]u8{
		255, 128,
		64, 0,
	};
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels, alpha_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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
	try testing.expectEqual(image_metadata.ExtraChannel.alpha, metadata.extra_channel_info[0].type);

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
	try testing.expectEqualSlices(i32, &.{ 255, 128, 64, 0 }, image.channels.items[3].data);
}

test "JxlEncoder encodes a staged alpha buffer with explicit alpha metadata" {
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
	info.alpha_bits = 8;
	info.alpha_premultiplied = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var alpha = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_ALPHA, &alpha);
	alpha.alpha_premultiplied = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &alpha));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelName(enc, 0, "alpha-plane".ptr, "alpha-plane".len),
	);

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

	const alpha_pixels = [_]u8{
		255, 128,
		64, 0,
	};
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels, alpha_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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
	_ = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);

	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.alpha, metadata.extra_channel_info[0].type);
	try testing.expect(metadata.extra_channel_info[0].alpha_associated);
	try testing.expectEqualStrings("alpha-plane", metadata.extra_channel_info[0].name);
}

test "JxlEncoder encodes a staged subsampled alpha buffer" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 4;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.alpha_bits = 8;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var alpha = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_ALPHA, &alpha);
	alpha.dim_shift = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &alpha));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgb_pixels = [_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
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

	const alpha_pixels = [_]u8{ 200, 50 };
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels, alpha_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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
	_ = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);

	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.alpha, metadata.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_info[0].dim_shift);
}

test "JxlEncoder rejects alpha metadata that disagrees with basic info" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.alpha_bits = 8;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var alpha = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_ALPHA, &alpha);
	alpha.alpha_premultiplied = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_ERROR, JxlEncoderSetExtraChannelInfo(enc, 0, &alpha));
}

test "JxlEncoder rejects ambiguous interleaved and staged alpha" {
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
	info.alpha_bits = 8;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

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

	const alpha_pixels = [_]u8{
		255, 128,
		64, 0,
	};
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels, alpha_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var chunk: [32]u8 = undefined;
	var next_out = chunk[0..].ptr;
	var avail_out: usize = chunk.len;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_ERROR, JxlEncoderProcessOutput(enc, &next_out, &avail_out));
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

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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

test "JxlEncoder encodes a cfa extra channel buffer" {
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

	var cfa = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_CFA, &cfa);
	cfa.cfa_channel = 2;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &cfa));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 0, "cfa".ptr, 3));

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

	const cfa_pixels = [_]u8{
		1, 2,
		3, 4,
	};
	const cfa_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &cfa_format, &cfa_pixels, cfa_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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
	try testing.expectEqual(image_metadata.ExtraChannel.cfa, metadata.extra_channel_info[0].type);
	try testing.expectEqualStrings("cfa", metadata.extra_channel_info[0].name);
	try testing.expectEqual(@as(u32, 2), metadata.extra_channel_info[0].cfa_channel);

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
	try testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, image.channels.items[3].data);
}

test "JxlEncoder encodes a subsampled depth extra channel buffer" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 4;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var depth = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_DEPTH, &depth);
	depth.dim_shift = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &depth));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelName(enc, 0, "depth-half".ptr, 10));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;

	const rgb_pixels = [_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
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

	const depth_pixels = [_]u8{ 100, 25 };
	const depth_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &depth_format, &depth_pixels, depth_pixels.len, 0),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [23]u8 = undefined;
		var next_out: [*]u8 = &chunk;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		if (produced != 0) {
			try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		}
		switch (status) {
			.JXL_ENC_SUCCESS => break,
			.JXL_ENC_NEED_MORE_OUTPUT => continue,
			else => return error.UnexpectedEncoderStatus,
		}
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(usize, 4), size.xsize());
	try testing.expectEqual(@as(usize, 2), size.ysize());
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.depth, metadata.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_info[0].dim_shift);
	try testing.expectEqualStrings("depth-half", metadata.extra_channel_info[0].name);

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
	try testing.expectEqual(@as(usize, 2), image.channels.items[3].w);
	try testing.expectEqual(@as(usize, 1), image.channels.items[3].h);
	try testing.expectEqualSlices(i32, &.{ 100, 25 }, image.channels.items[3].data);
}

test "JxlEncoder encodes animation metadata and frame timing" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 24;
	info.animation.tps_denominator = 1001;
	info.animation.num_loops = 3;
	info.animation.have_timecodes = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	frame_header.duration = 7;
	frame_header.timecode = 0x01020304;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));

	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len),
	);

	JxlEncoderCloseInput(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [23]u8 = undefined;
		var next_out: [*]u8 = &chunk;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		if (produced != 0) {
			try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		}
		switch (status) {
			.JXL_ENC_SUCCESS => break,
			.JXL_ENC_NEED_MORE_OUTPUT => continue,
			else => return error.UnexpectedEncoderStatus,
		}
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(usize, 2), size.xsize());
	try testing.expectEqual(@as(usize, 2), size.ysize());
	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 24), metadata.animation.tps_numerator);
	try testing.expectEqual(@as(u32, 1001), metadata.animation.tps_denominator);
	try testing.expectEqual(@as(u32, 3), metadata.animation.num_loops);
	try testing.expect(metadata.animation.have_timecodes);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
	defer frame_dec.deinit();
	var frame_br = BitReader.init(encoded.items[2 + frame_offset ..]);
	try frame_dec.initFrame(&frame_br);
	try testing.expectEqual(@as(u32, 7), frame_dec.frame_header.animation_frame.duration);
	try testing.expectEqual(@as(u32, 0x01020304), frame_dec.frame_header.animation_frame.timecode);
}

test "JxlEncoder encodes two animation frames" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	info.animation.have_timecodes = 1;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);

	const pixels0 = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const pixels1 = [_]u8{
		5, 15, 25, 35, 45, 55,
		65, 75, 85, 95, 105, 115,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 3;
	frame_header.timecode = 0x01020304;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &format, &pixels0, pixels0.len),
	);

	frame_header.duration = 5;
	frame_header.timecode = 0x05060708;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &format, &pixels1, pixels1.len),
	);

	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [23]u8 = undefined;
		var next_out: [*]u8 = &chunk;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		if (produced != 0) {
			try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		}
		switch (status) {
			.JXL_ENC_SUCCESS => break,
			.JXL_ENC_NEED_MORE_OUTPUT => continue,
			else => return error.UnexpectedEncoderStatus,
		}
	}

	var br = BitReader.init(encoded.items[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 30), metadata.animation.tps_numerator);
	try testing.expectEqual(@as(u32, 1), metadata.animation.num_loops);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	const expected_frames = [_][]const u8{ &pixels0, &pixels1 };
	const expected_durations = [_]u32{ 3, 5 };
	const expected_timecodes = [_]u32{ 0x01020304, 0x05060708 };
	for (expected_frames, expected_durations, expected_timecodes, 0..) |expected_pixels, duration, timecode, i| {
		const frame_bytes = try dec_frame.frameByteCount(testing.allocator, &codec_meta, encoded.items[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded.items[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(timecode, frame_dec.frame_header.animation_frame.timecode);
		try testing.expectEqual(i + 1 == expected_frames.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, 3), image.channels.items.len);
		for (0..image.h) |y| {
			for (0..image.w) |x| {
				const pixel_base = (y * image.w + x) * 3;
				for (0..3) |c| {
					try testing.expectEqual(@as(i32, expected_pixels[pixel_base + c]), image.channels.items[c].row(y)[x]);
				}
			}
		}

		frame_offset += frame_bytes;
	}
	try testing.expectEqual(encoded.items.len, frame_offset);
}

test "JxlEncoder encodes two animation frames with staged alpha" {
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
	info.alpha_bits = 8;
	info.have_animation = 1;
	info.animation.tps_numerator = 100;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 0;
	info.animation.have_timecodes = 0;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);

	const rgb_pixels0 = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const rgb_pixels1 = [_]u8{
		5, 15, 25, 35, 45, 55,
		65, 75, 85, 95, 105, 115,
	};
	const alpha_pixels0 = [_]u8{
		255, 128,
		64, 0,
	};
	const alpha_pixels1 = [_]u8{
		0, 64,
		128, 255,
	};
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 30;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels0, rgb_pixels0.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels0, alpha_pixels0.len, 0),
	);

	frame_header.duration = 10;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels1, rgb_pixels1.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels1, alpha_pixels1.len, 0),
	);

	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
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

	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.alpha, metadata.extra_channel_info[0].type);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	const expected_rgba = [_][]const u8{
		&[_]u8{
			0, 10, 20, 255, 30, 40, 50, 128,
			60, 70, 80, 64, 90, 100, 110, 0,
		},
		&[_]u8{
			5, 15, 25, 0, 35, 45, 55, 64,
			65, 75, 85, 128, 95, 105, 115, 255,
		},
	};
	const expected_durations = [_]u32{ 30, 10 };
	for (expected_rgba, expected_durations, 0..) |expected_pixels, duration, i| {
		const frame_bytes = try dec_frame.frameByteCount(testing.allocator, &codec_meta, encoded.items[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded.items[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(i + 1 == expected_rgba.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, 4), image.channels.items.len);
		for (0..image.h) |y| {
			for (0..image.w) |x| {
				const pixel_base = (y * image.w + x) * 4;
				for (0..4) |c| {
					try testing.expectEqual(@as(i32, expected_pixels[pixel_base + c]), image.channels.items[c].row(y)[x]);
				}
			}
		}

		frame_offset += frame_bytes;
	}
	try testing.expectEqual(encoded.items.len, frame_offset);
}

test "JxlEncoder encodes two animation frames with staged subsampled alpha" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 4;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.alpha_bits = 8;
	info.have_animation = 1;
	info.animation.tps_numerator = 100;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 0;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var alpha = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_ALPHA, &alpha);
	alpha.dim_shift = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &alpha));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);

	const rgb_pixels0 = [_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	};
	const rgb_pixels1 = [_]u8{
		14, 18, 22, 16, 20, 24, 18, 22, 26, 20, 24, 28,
		13, 16, 19, 15, 18, 21, 17, 20, 23, 19, 22, 25,
	};
	const alpha_pixels0 = [_]u8{ 200, 50 };
	const alpha_pixels1 = [_]u8{ 25, 175 };
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const alpha_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 20;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels0, rgb_pixels0.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels0, alpha_pixels0.len, 0),
	);

	frame_header.duration = 40;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels1, rgb_pixels1.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, &alpha_pixels1, alpha_pixels1.len, 0),
	);

	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [48]u8 = undefined;
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

	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_info[0].dim_shift);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	const expected_alpha = [_][]const i32{
		&.{ 200, 50 },
		&.{ 25, 175 },
	};
	const expected_durations = [_]u32{ 20, 40 };
	for (expected_alpha, expected_durations, 0..) |expected_row_alpha, duration, i| {
		const frame_bytes = try dec_frame.frameByteCount(testing.allocator, &codec_meta, encoded.items[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded.items[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(i + 1 == expected_alpha.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, 4), image.channels.items.len);
		try testing.expectEqual(@as(usize, 1), image.channels.items[3].h);
		try testing.expectEqualSlices(i32, expected_row_alpha, image.channels.items[3].row(0));

		frame_offset += frame_bytes;
	}
	try testing.expectEqual(encoded.items.len, frame_offset);
}

test "JxlEncoder encodes two animation frames with a staged selection mask" {
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
	info.have_animation = 1;
	info.animation.tps_numerator = 100;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 0;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var extra = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_SELECTION_MASK, &extra);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &extra));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);

	const rgb_pixels0 = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const rgb_pixels1 = [_]u8{
		5, 15, 25, 35, 45, 55,
		65, 75, 85, 95, 105, 115,
	};
	const mask_pixels0 = [_]u8{
		255, 0,
		64, 32,
	};
	const mask_pixels1 = [_]u8{
		0, 255,
		32, 64,
	};
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const mask_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 12;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels0, rgb_pixels0.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &mask_format, &mask_pixels0, mask_pixels0.len, 0),
	);

	frame_header.duration = 24;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels1, rgb_pixels1.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &mask_format, &mask_pixels1, mask_pixels1.len, 0),
	);

	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [48]u8 = undefined;
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

	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.selection_mask, metadata.extra_channel_info[0].type);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	const expected_masks = [_][]const i32{
		&.{ 255, 0, 64, 32 },
		&.{ 0, 255, 32, 64 },
	};
	const expected_durations = [_]u32{ 12, 24 };
	for (expected_masks, expected_durations, 0..) |expected_mask, duration, i| {
		const frame_bytes = try dec_frame.frameByteCount(testing.allocator, &codec_meta, encoded.items[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded.items[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(i + 1 == expected_masks.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, 4), image.channels.items.len);
		try testing.expectEqualSlices(i32, expected_mask, image.channels.items[3].data);

		frame_offset += frame_bytes;
	}
	try testing.expectEqual(encoded.items.len, frame_offset);
}

test "JxlEncoder encodes two animation frames with a staged subsampled depth channel" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 4;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.have_animation = 1;
	info.animation.tps_numerator = 100;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 0;

	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	var extra = std.mem.zeroes(JxlExtraChannelInfo);
	JxlEncoderInitExtraChannelInfo(.JXL_CHANNEL_DEPTH, &extra);
	extra.dim_shift = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetExtraChannelInfo(enc, 0, &extra));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);

	const rgb_pixels0 = [_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	};
	const rgb_pixels1 = [_]u8{
		14, 18, 22, 16, 20, 24, 18, 22, 26, 20, 24, 28,
		13, 16, 19, 15, 18, 21, 17, 20, 23, 19, 22, 25,
	};
	const depth_pixels0 = [_]u8{ 10, 20 };
	const depth_pixels1 = [_]u8{ 30, 40 };
	const rgb_format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const depth_format = JxlPixelFormat{
		.num_channels = 1,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 15;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels0, rgb_pixels0.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &depth_format, &depth_pixels0, depth_pixels0.len, 0),
	);

	frame_header.duration = 35;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderAddImageFrame(settings, &rgb_format, &rgb_pixels1, rgb_pixels1.len),
	);
	try testing.expectEqual(
		JxlEncoderStatus.JXL_ENC_SUCCESS,
		JxlEncoderSetExtraChannelBuffer(settings, &depth_format, &depth_pixels1, depth_pixels1.len, 0),
	);

	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [48]u8 = undefined;
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

	try testing.expect(metadata.have_animation);
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.depth, metadata.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_info[0].dim_shift);

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	const expected_depth = [_][]const i32{
		&.{ 10, 20 },
		&.{ 30, 40 },
	};
	const expected_durations = [_]u32{ 15, 35 };
	for (expected_depth, expected_durations, 0..) |expected_plane, duration, i| {
		const frame_bytes = try dec_frame.frameByteCount(testing.allocator, &codec_meta, encoded.items[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &codec_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded.items[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(i + 1 == expected_depth.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, 4), image.channels.items.len);
		try testing.expectEqual(@as(usize, 1), image.channels.items[3].h);
		try testing.expectEqualSlices(i32, expected_plane, image.channels.items[3].row(0));

		frame_offset += frame_bytes;
	}
	try testing.expectEqual(encoded.items.len, frame_offset);
}

test "JxlDecoder emits frame headers for animated codestreams" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	info.animation.have_timecodes = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	const pixels0 = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const pixels1 = [_]u8{
		5, 15, 25, 35, 45, 55,
		65, 75, 85, 95, 105, 115,
	};
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};

	frame_header.duration = 3;
	frame_header.timecode = 0x01020304;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels0, pixels0.len));

	frame_header.duration = 5;
	frame_header.timecode = 0x05060708;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels1, pixels1.len));
	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [23]u8 = undefined;
		var next_out: [*]u8 = &chunk;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		if (produced != 0) {
			try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		}
		switch (status) {
			.JXL_ENC_SUCCESS => break,
			.JXL_ENC_NEED_MORE_OUTPUT => continue,
			else => return error.UnexpectedEncoderStatus,
		}
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var basic_info = std.mem.zeroes(JxlBasicInfo);
	var output: [12]u8 = undefined;
	var output_set = false;
	var durations: [2]u32 = .{ 0, 0 };
	var timecodes: [2]u32 = .{ 0, 0 };
	var last_flags: [2]JXL_BOOL = .{ 0, 0 };
	var frame_count: usize = 0;
	var full_count: usize = 0;

	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetBasicInfo(dec, &basic_info));
				try testing.expect(basic_info.have_animation != 0);
			},
			.JXL_DEC_FRAME => {
				var out_header = std.mem.zeroes(JxlFrameHeader);
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetFrameHeader(dec, &out_header));
				try testing.expect(frame_count < durations.len);
				durations[frame_count] = out_header.duration;
				timecodes[frame_count] = out_header.timecode;
				last_flags[frame_count] = out_header.is_last;
				frame_count += 1;
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				if (!output_set) {
					try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
					output_set = true;
				}
			},
			.JXL_DEC_FULL_IMAGE => full_count += 1,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expectEqual(@as(usize, 2), frame_count);
	try testing.expectEqual(@as(usize, 2), full_count);
	try testing.expectEqualSlices(u32, &.{ 3, 5 }, &durations);
	try testing.expectEqualSlices(u32, &.{ 0x01020304, 0x05060708 }, &timecodes);
	try testing.expectEqualSlices(JXL_BOOL, &.{ 0, 1 }, &last_flags);
}

test "JxlDecoderSkipFrames skips the requested displayed frames" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	info.animation.have_timecodes = 0;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const pixels0 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
	const pixels1 = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };
	const pixels2 = [_]u8{ 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };

	frame_header.duration = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels0, pixels0.len));
	frame_header.duration = 2;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels1, pixels1.len));
	frame_header.duration = 3;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels2, pixels2.len));
	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output: [12]u8 = undefined;
	var basic_seen = false;
	var frame_durations: [2]u32 = .{ 0, 0 };
	var frame_count: usize = 0;
	var full_count: usize = 0;

	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {
				basic_seen = true;
				JxlDecoderSkipFrames(dec, 1);
			},
			.JXL_DEC_FRAME => {
				var out_header = std.mem.zeroes(JxlFrameHeader);
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetFrameHeader(dec, &out_header));
				frame_durations[frame_count] = out_header.duration;
				frame_count += 1;
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => full_count += 1,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expect(basic_seen);
	try testing.expectEqual(@as(usize, 2), frame_count);
	try testing.expectEqual(@as(usize, 2), full_count);
	try testing.expectEqualSlices(u32, &.{ 2, 3 }, &frame_durations);
}

test "JxlDecoderSkipCurrentFrame advances to the next frame" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const pixels0 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
	const pixels1 = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };

	frame_header.duration = 7;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels0, pixels0.len));
	frame_header.duration = 9;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels1, pixels1.len));
	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output: [12]u8 = undefined;
	var frame_durations: [1]u32 = .{0};
	var frame_count: usize = 0;
	var full_count: usize = 0;

	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_FRAME => {
				var out_header = std.mem.zeroes(JxlFrameHeader);
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetFrameHeader(dec, &out_header));
				if (frame_count == 0) {
					try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSkipCurrentFrame(dec));
				} else {
					frame_durations[frame_count - 1] = out_header.duration;
				}
				frame_count += 1;
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => full_count += 1,
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}

	try testing.expectEqual(@as(usize, 2), frame_count);
	try testing.expectEqual(@as(usize, 1), full_count);
	try testing.expectEqualSlices(u32, &.{9}, &frame_durations);
}

test "JxlDecoderRewind replays animation from the beginning" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const pixels0 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
	const pixels1 = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };

	frame_header.duration = 4;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels0, pixels0.len));
	frame_header.duration = 8;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels1, pixels1.len));
	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output: [12]u8 = undefined;
	var first_pass: [2]u32 = .{ 0, 0 };
	var second_pass: [2]u32 = .{ 0, 0 };
	var frame_count: usize = 0;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_FRAME => {
				var out_header = std.mem.zeroes(JxlFrameHeader);
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetFrameHeader(dec, &out_header));
				first_pass[frame_count] = out_header.duration;
				frame_count += 1;
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => {},
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}
	try testing.expectEqual(@as(usize, 2), frame_count);

	JxlDecoderRewind(dec);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);
	frame_count = 0;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO => {},
			.JXL_DEC_FRAME => {
				var out_header = std.mem.zeroes(JxlFrameHeader);
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderGetFrameHeader(dec, &out_header));
				second_pass[frame_count] = out_header.duration;
				frame_count += 1;
			},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output, output.len));
			},
			.JXL_DEC_FULL_IMAGE => {},
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}
	try testing.expectEqual(@as(usize, 2), frame_count);
	try testing.expectEqualSlices(u32, &first_pass, &second_pass);
}

test "JxlDecoderRewind requests a fresh output buffer before replaying frames" {
	const testing = std.testing;
	const enc = JxlEncoderCreate(null) orelse return error.OutOfMemory;
	defer JxlEncoderDestroy(enc);

	var info: JxlBasicInfo = undefined;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.have_animation = 1;
	info.animation.tps_numerator = 30;
	info.animation.tps_denominator = 1;
	info.animation.num_loops = 1;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetBasicInfo(enc, &info));

	var color = std.mem.zeroes(JxlColorEncoding);
	JxlColorEncodingSetToSRGB(&color, 0);
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetColorEncoding(enc, &color));

	const settings = JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
	var frame_header = std.mem.zeroes(JxlFrameHeader);
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT8,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 0,
	};
	const pixels = [_]u8{
		255, 0, 0,
		0, 255, 0,
		0, 0, 255,
		255, 255, 0,
	};

	frame_header.duration = 4;
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderSetFrameHeader(settings, &frame_header));
	try testing.expectEqual(JxlEncoderStatus.JXL_ENC_SUCCESS, JxlEncoderAddImageFrame(settings, &format, &pixels, pixels.len));
	JxlEncoderCloseFrames(enc);

	var encoded: std.ArrayListUnmanaged(u8) = .empty;
	defer encoded.deinit(testing.allocator);
	while (true) {
		var chunk: [64]u8 = undefined;
		var next_out = chunk[0..].ptr;
		var avail_out: usize = chunk.len;
		const status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		const produced = chunk.len - avail_out;
		try encoded.appendSlice(testing.allocator, chunk[0..produced]);
		if (status == .JXL_ENC_SUCCESS) break;
		try testing.expectEqual(JxlEncoderStatus.JXL_ENC_NEED_MORE_OUTPUT, status);
	}

	const dec = JxlDecoderCreate(null) orelse return error.OutOfMemory;
	defer JxlDecoderDestroy(dec);
	try testing.expectEqual(
		JxlDecoderStatus.JXL_DEC_SUCCESS,
		JxlDecoderSubscribeEvents(
			dec,
			@intFromEnum(JxlDecoderStatus.JXL_DEC_BASIC_INFO) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FRAME) |
				@intFromEnum(JxlDecoderStatus.JXL_DEC_FULL_IMAGE),
		),
	);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	var output_a: [12]u8 = undefined;
	var output_b: [12]u8 = undefined;
	var saw_need_buffer = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO, .JXL_DEC_FRAME => {},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				saw_need_buffer = true;
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output_a, output_a.len));
			},
			.JXL_DEC_FULL_IMAGE => {},
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}
	try testing.expect(saw_need_buffer);

	JxlDecoderRewind(dec);
	try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetInput(dec, encoded.items.ptr, encoded.items.len));
	JxlDecoderCloseInput(dec);

	saw_need_buffer = false;
	while (true) {
		switch (JxlDecoderProcessInput(dec)) {
			.JXL_DEC_BASIC_INFO, .JXL_DEC_FRAME => {},
			.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
				saw_need_buffer = true;
				try testing.expectEqual(JxlDecoderStatus.JXL_DEC_SUCCESS, JxlDecoderSetImageOutBuffer(dec, &format, &output_b, output_b.len));
			},
			.JXL_DEC_FULL_IMAGE => {},
			.JXL_DEC_SUCCESS => break,
			else => return error.UnexpectedDecoderStatus,
		}
	}
	try testing.expect(saw_need_buffer);
	try testing.expectEqualSlices(u8, &output_a, &output_b);
}
