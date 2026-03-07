const std = @import("std");

const common = @import("lib/base/common.zig");
const byte_order = @import("lib/base/byte_order.zig");
const BitReader = @import("lib/base/bit_reader.zig").BitReader;
const JxlError = @import("lib/base/status.zig").JxlError;
const headers = @import("lib/codec/headers.zig");
const image_metadata = @import("lib/codec/image_metadata.zig");
const frame_header_mod = @import("lib/codec/frame_header.zig");
const dec_frame = @import("lib/codec/dec_frame.zig");
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

fn decoderVersion() u32 {
	return 1000;
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
