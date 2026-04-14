const std = @import("std");
const common = @import("../base/common.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const headers = @import("headers.zig");
const color_encoding_mod = @import("color_encoding.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const toc = @import("toc.zig");
const enc_frame = @import("enc_frame.zig");
const enc_codestream = @import("enc_codestream.zig");
const dec_frame = @import("dec_frame.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");
const modular_image = @import("../modular/modular_image.zig");

pub const SimpleInterleavedU8Image = struct {
	width: u32,
	height: u32,
	num_channels: u32,
	num_extra_channels: u32 = 0,
	alpha_associated: bool = false,
	orientation: u32 = 1,
	intrinsic_width: u32 = 0,
	intrinsic_height: u32 = 0,
	have_animation: bool = false,
	animation: headers.AnimationHeader = .{},
	frame_duration: u32 = 0,
	frame_timecode: u32 = 0,
	tone_mapping: image_metadata.ToneMapping = .{},
	extra_channel_info: []const image_metadata.ExtraChannelInfo = &.{},
	row_stride: usize,
	pixels: []const u8,
};

pub const SimpleExtraPlaneU8 = struct {
	info: image_metadata.ExtraChannelInfo,
	row_stride: usize,
	pixels: []const u8,
};

pub const SimplePackedU8Image = struct {
	width: u32,
	height: u32,
	num_color_channels: u32,
	color_row_stride: usize,
	color_pixels: []const u8,
	alpha_row_stride: usize = 0,
	alpha_pixels: []const u8 = &.{},
	alpha_associated: bool = false,
	alpha_info: ?image_metadata.ExtraChannelInfo = null,
	orientation: u32 = 1,
	intrinsic_width: u32 = 0,
	intrinsic_height: u32 = 0,
	have_animation: bool = false,
	animation: headers.AnimationHeader = .{},
	frame_duration: u32 = 0,
	frame_timecode: u32 = 0,
	tone_mapping: image_metadata.ToneMapping = .{},
	extra_planes: []const SimpleExtraPlaneU8 = &.{},
};

pub const SimplePackedU8AnimationFrame = struct {
	color_row_stride: usize,
	color_pixels: []const u8,
	alpha_row_stride: usize = 0,
	alpha_pixels: []const u8 = &.{},
	extra_planes: []const SimpleExtraPlaneU8 = &.{},
	frame_duration: u32 = 0,
	frame_timecode: u32 = 0,
};

pub const SimplePackedU8Animation = struct {
	width: u32,
	height: u32,
	num_color_channels: u32,
	alpha_associated: bool = false,
	alpha_info: ?image_metadata.ExtraChannelInfo = null,
	orientation: u32 = 1,
	intrinsic_width: u32 = 0,
	intrinsic_height: u32 = 0,
	animation: headers.AnimationHeader,
	tone_mapping: image_metadata.ToneMapping = .{},
	frames: []const SimplePackedU8AnimationFrame,
};

fn validateToneMapping(tone_mapping: image_metadata.ToneMapping) !void {
	if (!(tone_mapping.intensity_target > 0.0)) return error.InvalidArgs;
	if (tone_mapping.min_nits < 0.0 or tone_mapping.min_nits > tone_mapping.intensity_target) return error.InvalidArgs;
	if (tone_mapping.linear_below < 0.0) return error.InvalidArgs;
	if (tone_mapping.relative_to_max_display and tone_mapping.linear_below > 1.0) return error.InvalidArgs;
}

fn validateOrientationAndIntrinsic(orientation: u32, intrinsic_width: u32, intrinsic_height: u32) !void {
	if (orientation < 1 or orientation > 8) return error.InvalidArgs;
	if ((intrinsic_width == 0) != (intrinsic_height == 0)) return error.InvalidArgs;
}

fn validateAnimation(
	have_animation: bool,
	animation: headers.AnimationHeader,
	frame_duration: u32,
	frame_timecode: u32,
) !void {
	if (!have_animation) {
		if (frame_duration != 0 or frame_timecode != 0) return error.InvalidArgs;
		return;
	}
	if (animation.tps_numerator == 0 or animation.tps_denominator == 0) return error.InvalidArgs;
	if (!animation.have_timecodes and frame_timecode != 0) return error.InvalidArgs;
}

fn graySrgbColorEncoding() color_encoding_mod.ColorEncoding {
	return .{
		.color_space = .gray,
		.white_point = .d65,
		.primaries = .srgb,
		.tf = .{ .have_gamma = false, .transfer_function = .srgb },
		.rendering_intent = .relative,
	};
}

fn validateSimpleImage(image: SimpleInterleavedU8Image) !void {
	if (image.width == 0 or image.height == 0) return error.InvalidArgs;
	if (image.num_channels < image.num_extra_channels) return error.InvalidArgs;
	const num_color_channels = image.num_channels - image.num_extra_channels;
	if (!(num_color_channels == 1 or num_color_channels == 3)) return error.Unsupported;
	if (image.num_extra_channels == 0 and image.alpha_associated) return error.Unsupported;
	if (image.extra_channel_info.len != 0 and image.extra_channel_info.len != image.num_extra_channels) return error.InvalidArgs;
	try validateOrientationAndIntrinsic(image.orientation, image.intrinsic_width, image.intrinsic_height);
	try validateAnimation(image.have_animation, image.animation, image.frame_duration, image.frame_timecode);
	try validateToneMapping(image.tone_mapping);

	const min_row_stride = @as(usize, image.width) * image.num_channels;
	if (image.row_stride < min_row_stride) return error.InvalidArgs;
	const needed = image.row_stride * @as(usize, image.height);
	if (image.pixels.len < needed) return error.InvalidArgs;
}

fn subsampledSize(size: u32, shift: u32) usize {
	return common.divCeil(@as(usize, size), @as(usize, 1) << @intCast(shift));
}

fn validateSimplePackedImage(image: SimplePackedU8Image) !void {
	if (image.width == 0 or image.height == 0) return error.InvalidArgs;
	if (!(image.num_color_channels == 1 or image.num_color_channels == 3)) return error.Unsupported;
	if (image.alpha_pixels.len == 0 and image.alpha_associated) return error.Unsupported;
	if (image.alpha_pixels.len == 0 and image.alpha_info != null) return error.InvalidArgs;
	try validateOrientationAndIntrinsic(image.orientation, image.intrinsic_width, image.intrinsic_height);
	try validateAnimation(image.have_animation, image.animation, image.frame_duration, image.frame_timecode);
	try validateToneMapping(image.tone_mapping);

	const min_color_row_stride = @as(usize, image.width) * image.num_color_channels;
	if (image.color_row_stride < min_color_row_stride) return error.InvalidArgs;
	if (image.color_pixels.len < image.color_row_stride * @as(usize, image.height)) return error.InvalidArgs;

	if (image.alpha_pixels.len != 0) {
		const alpha_dim_shift = if (image.alpha_info) |alpha_info| alpha_info.dim_shift else 0;
		const alpha_width = subsampledSize(image.width, alpha_dim_shift);
		const alpha_height = subsampledSize(image.height, alpha_dim_shift);
		if (image.alpha_row_stride < alpha_width) return error.InvalidArgs;
		if (image.alpha_pixels.len < image.alpha_row_stride * alpha_height) return error.InvalidArgs;
		if (image.alpha_info) |alpha_info| {
			if (alpha_info.type != .alpha) return error.InvalidArgs;
			if (alpha_info.bit_depth.floating_point_sample) return error.Unsupported;
			if (alpha_info.bit_depth.bits_per_sample != 8 or alpha_info.bit_depth.exponent_bits_per_sample != 0) return error.Unsupported;
			if (alpha_info.dim_shift > 3) return error.Unsupported;
			if (alpha_info.alpha_associated != image.alpha_associated) return error.InvalidArgs;
		}
	}

	for (image.extra_planes) |extra| {
		if (extra.info.type == .alpha) return error.InvalidArgs;
		const plane_width = subsampledSize(image.width, extra.info.dim_shift);
		const plane_height = subsampledSize(image.height, extra.info.dim_shift);
		if (extra.row_stride < plane_width) return error.InvalidArgs;
		if (extra.pixels.len < extra.row_stride * plane_height) return error.InvalidArgs;
	}
}

fn validateSimplePackedAnimation(image: SimplePackedU8Animation) !void {
	if (image.frames.len == 0) return error.InvalidArgs;
	try validateOrientationAndIntrinsic(image.orientation, image.intrinsic_width, image.intrinsic_height);
	try validateAnimation(true, image.animation, 0, 0);
	try validateToneMapping(image.tone_mapping);

	const extra_info = image.frames[0].extra_planes;
	for (image.frames) |frame| {
		if (frame.extra_planes.len != extra_info.len) return error.InvalidArgs;
		for (frame.extra_planes, extra_info) |extra, reference| {
			if (!std.meta.eql(extra.info, reference.info)) return error.InvalidArgs;
		}
		try validateSimplePackedImage(.{
			.width = image.width,
			.height = image.height,
			.num_color_channels = image.num_color_channels,
			.color_row_stride = frame.color_row_stride,
			.color_pixels = frame.color_pixels,
			.alpha_row_stride = frame.alpha_row_stride,
			.alpha_pixels = frame.alpha_pixels,
			.alpha_associated = image.alpha_associated,
			.alpha_info = image.alpha_info,
			.orientation = image.orientation,
			.intrinsic_width = image.intrinsic_width,
			.intrinsic_height = image.intrinsic_height,
			.have_animation = true,
			.animation = image.animation,
			.frame_duration = frame.frame_duration,
			.frame_timecode = frame.frame_timecode,
			.tone_mapping = image.tone_mapping,
			.extra_planes = frame.extra_planes,
		});
	}
}

fn buildCodecMetadata(
	width: u32,
	height: u32,
	num_extra_channels: u32,
	alpha_associated: bool,
	orientation: u32,
	intrinsic_width: u32,
	intrinsic_height: u32,
	have_animation: bool,
	animation: headers.AnimationHeader,
	tone_mapping: image_metadata.ToneMapping,
	extra_channel_info: []const image_metadata.ExtraChannelInfo,
	color_encoding: color_encoding_mod.ColorEncoding,
) image_metadata.CodecMetadata {
	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = .{
		.small = false,
		.ysize_raw = height,
		.ratio = 0,
		.xsize_raw = width,
	};
	codec_meta.m = .{
		.bit_depth = .{},
		.modular_16_bit_buffer_sufficient = true,
		.xyb_encoded = false,
		.orientation = orientation,
		.tone_mapping = tone_mapping,
		.color_encoding = color_encoding,
	};
	if (intrinsic_width != 0) {
		codec_meta.m.have_intrinsic_size = true;
		codec_meta.m.intrinsic_size = .{
			.small = false,
			.ysize_raw = intrinsic_height,
			.ratio = 0,
			.xsize_raw = intrinsic_width,
		};
	}
	if (have_animation) {
		codec_meta.m.have_animation = true;
		codec_meta.m.animation = animation;
	}
	if (num_extra_channels != 0) {
		codec_meta.m.num_extra_channels = num_extra_channels;
		codec_meta.m.extra_channel_count = num_extra_channels;
		if (extra_channel_info.len != 0) {
			for (extra_channel_info, 0..) |extra, i| {
				codec_meta.m.extra_channel_info[i] = extra;
			}
		} else if (num_extra_channels == 1) {
			codec_meta.m.extra_channel_info[0] = .{
				.type = .alpha,
				.bit_depth = .{},
				.alpha_associated = alpha_associated,
			};
		}
	}
	codec_meta.transform_data = .{};
	return codec_meta;
}

fn buildSimpleFrameHeader(
	extra_channel_info: []const image_metadata.ExtraChannelInfo,
	frame_duration: u32,
	frame_timecode: u32,
) frame_header_mod.FrameHeader {
	var frame_header: frame_header_mod.FrameHeader = .{
		.encoding = .modular,
		.color_transform = .none,
		.loop_filter = .{},
	};
	frame_header.animation_frame.duration = frame_duration;
	frame_header.animation_frame.timecode = frame_timecode;
	for (extra_channel_info, 0..) |extra, i| {
		frame_header.extra_channel_upsampling[i] = @as(u32, 1) << @intCast(extra.dim_shift);
	}
	return frame_header;
}

fn buildSourceImage(allocator: std.mem.Allocator, image: SimpleInterleavedU8Image) !modular_image.Image {
	var source = try modular_image.Image.create(
		allocator,
		image.width,
		image.height,
		8,
		image.num_channels,
	);
	errdefer source.deinit();

	for (0..source.h) |y| {
		const row = image.pixels[y * image.row_stride .. y * image.row_stride + image.row_stride];
		for (0..source.w) |x| {
			const pixel_base = x * image.num_channels;
			for (0..source.channels.items.len) |c| {
				source.channels.items[c].row(y)[x] = row[pixel_base + c];
			}
		}
	}

	return source;
}

fn buildPackedSourceImage(allocator: std.mem.Allocator, image: SimplePackedU8Image) !modular_image.Image {
	var source = try modular_image.Image.create(allocator, image.width, image.height, 8, 0);
	errdefer source.deinit();

	for (0..image.num_color_channels) |_| {
		try source.channels.append(allocator, try modular_image.Channel.create(allocator, image.width, image.height, 0, 0));
	}
	if (image.alpha_pixels.len != 0) {
		const alpha_dim_shift = if (image.alpha_info) |alpha_info| alpha_info.dim_shift else 0;
		const alpha_width = subsampledSize(image.width, alpha_dim_shift);
		const alpha_height = subsampledSize(image.height, alpha_dim_shift);
		try source.channels.append(
			allocator,
			try modular_image.Channel.create(
				allocator,
				alpha_width,
				alpha_height,
				@intCast(alpha_dim_shift),
				@intCast(alpha_dim_shift),
			),
		);
	}
	for (image.extra_planes) |extra| {
		const plane_width = subsampledSize(image.width, extra.info.dim_shift);
		const plane_height = subsampledSize(image.height, extra.info.dim_shift);
		try source.channels.append(
			allocator,
			try modular_image.Channel.create(
				allocator,
				plane_width,
				plane_height,
				@intCast(extra.info.dim_shift),
				@intCast(extra.info.dim_shift),
			),
		);
	}

	for (0..source.h) |y| {
		const row = image.color_pixels[y * image.color_row_stride .. y * image.color_row_stride + image.color_row_stride];
		for (0..source.w) |x| {
			const pixel_base = x * @as(usize, image.num_color_channels);
			for (0..image.num_color_channels) |c| {
				source.channels.items[c].row(y)[x] = row[pixel_base + c];
			}
		}
	}

	if (image.alpha_pixels.len != 0) {
		const alpha_channel: usize = @intCast(image.num_color_channels);
		for (0..source.channels.items[alpha_channel].h) |y| {
			const row = image.alpha_pixels[y * image.alpha_row_stride .. y * image.alpha_row_stride + image.alpha_row_stride];
			for (0..source.channels.items[alpha_channel].w) |x| {
				source.channels.items[alpha_channel].row(y)[x] = row[x];
			}
		}
	}

	var extra_channel_index: usize = @intCast(image.num_color_channels + @as(u32, @intFromBool(image.alpha_pixels.len != 0)));
	for (image.extra_planes) |extra| {
		const channel = &source.channels.items[extra_channel_index];
		for (0..channel.h) |y| {
			const row = extra.pixels[y * extra.row_stride .. y * extra.row_stride + extra.row_stride];
			for (0..channel.w) |x| {
				channel.row(y)[x] = row[x];
			}
		}
		extra_channel_index += 1;
	}

	return source;
}

fn encodePreparedFrameData(
	allocator: std.mem.Allocator,
	codec_meta: image_metadata.CodecMetadata,
	frame_header: frame_header_mod.FrameHeader,
	source: *modular_image.Image,
) ![]u8 {
	const frame_dim = frame_header.toFrameDimensions(&codec_meta, false);

	var hist_cache = enc_encoding.FlatHistogramInfoCache.init(allocator);
	defer hist_cache.deinit();

	const num_sections = toc.numTocEntries(
		frame_dim.num_groups,
		frame_dim.num_dc_groups,
		frame_header.passes.num_passes,
	);
	const ac_global_index = 1 + frame_dim.num_dc_groups;

	const section_writers = try allocator.alloc(BitWriter, num_sections);
	defer allocator.free(section_writers);
	for (section_writers) |*section_writer| {
		section_writer.* = BitWriter.init(allocator);
	}
	defer for (section_writers) |*section_writer| {
		section_writer.deinit();
	};

	try section_writers[0].write(1, 1);
	try section_writers[0].write(1, 0);
	if (num_sections == 1) {
		_ = try enc_encoding.writeSingleNodeLocalTreeGroupImageWithCache(
			allocator,
			source,
			.gradient,
			&hist_cache,
			&section_writers[0],
		);
		try section_writers[0].zeroPadToByte();
	} else {
		try enc_encoding.writeEmptyModularGroup(&section_writers[0]);
		try section_writers[0].zeroPadToByte();

		for (ac_global_index + 1..num_sections) |section_id| {
			const group_id = (section_id - ac_global_index - 1) % frame_dim.num_groups;
			_ = try enc_encoding.writeSingleNodeLocalTreeGroupImageRectWithCache(
				allocator,
				source,
				frame_dim.groupRect(group_id),
				.gradient,
				&hist_cache,
				&section_writers[section_id],
			);
			try section_writers[section_id].zeroPadToByte();
		}
	}

	const section_payloads = try allocator.alloc([]const u8, num_sections);
	defer allocator.free(section_payloads);
	for (section_writers, 0..) |*section_writer, i| {
		section_payloads[i] = section_writer.bytes();
	}

	var frame_writer = BitWriter.init(allocator);
	defer frame_writer.deinit();
	try enc_frame.writeFrame(&frame_header, &codec_meta, section_payloads, &frame_writer);
	try frame_writer.zeroPadToByte();

	return allocator.dupe(u8, frame_writer.bytes());
}

fn encodePreparedSource(
	allocator: std.mem.Allocator,
	codec_meta: image_metadata.CodecMetadata,
	frame_header: frame_header_mod.FrameHeader,
	source: *modular_image.Image,
) ![]u8 {
	const frame_data = try encodePreparedFrameData(allocator, codec_meta, frame_header, source);
	defer allocator.free(frame_data);

	const frame_datas = [_][]const u8{frame_data};

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try enc_codestream.writeCodestreamFrames(&codec_meta, &frame_datas, &codestream);
	try codestream.zeroPadToByte();

	return allocator.dupe(u8, codestream.bytes());
}

/// Encodes narrow static lossless modular images from a full-size color plane,
/// optional full-size alpha plane, and separately staged sidecar extra planes.
pub fn encodeSimplePackedU8(
	allocator: std.mem.Allocator,
	image: SimplePackedU8Image,
	color_encoding: ?color_encoding_mod.ColorEncoding,
) ![]u8 {
	try validateSimplePackedImage(image);

	const num_extra_channels = @as(u32, @intFromBool(image.alpha_pixels.len != 0)) + @as(u32, @intCast(image.extra_planes.len));
	var extra_info_storage: [256]image_metadata.ExtraChannelInfo = undefined;
	var extra_info_len: usize = 0;
	if (image.alpha_pixels.len != 0) {
		extra_info_storage[extra_info_len] = image.alpha_info orelse .{
			.type = .alpha,
			.bit_depth = .{},
			.alpha_associated = image.alpha_associated,
		};
		extra_info_len += 1;
	}
	for (image.extra_planes) |extra| {
		extra_info_storage[extra_info_len] = extra.info;
		extra_info_len += 1;
	}
	const extra_info_slice = extra_info_storage[0..extra_info_len];

	const effective_color_encoding = color_encoding orelse if (image.num_color_channels == 1)
		graySrgbColorEncoding()
	else
		color_encoding_mod.ColorEncoding{};
	if (effective_color_encoding.channels() != image.num_color_channels) return error.Unsupported;
	if (effective_color_encoding.want_icc) return error.Unsupported;

	const codec_meta = buildCodecMetadata(
		image.width,
		image.height,
		num_extra_channels,
		image.alpha_associated,
		image.orientation,
		image.intrinsic_width,
		image.intrinsic_height,
		image.have_animation,
		image.animation,
		image.tone_mapping,
		extra_info_slice,
		effective_color_encoding,
	);
	const frame_header = buildSimpleFrameHeader(extra_info_slice, image.frame_duration, image.frame_timecode);

	var source = try buildPackedSourceImage(allocator, image);
	defer source.deinit();

	return encodePreparedSource(allocator, codec_meta, frame_header, &source);
}

/// Encodes a narrow animated lossless modular codestream from same-geometry
/// packed uint8 frames with shared metadata and per-frame duration/timecode.
pub fn encodeSimplePackedU8Animation(
	allocator: std.mem.Allocator,
	image: SimplePackedU8Animation,
	color_encoding: ?color_encoding_mod.ColorEncoding,
) ![]u8 {
	try validateSimplePackedAnimation(image);

	const has_alpha = image.frames[0].alpha_pixels.len != 0;
	const frame_extra_planes = image.frames[0].extra_planes;
	const num_extra_channels: u32 = @intCast(@as(usize, @intFromBool(has_alpha)) + frame_extra_planes.len);
	const extra_info_slice = try allocator.alloc(image_metadata.ExtraChannelInfo, num_extra_channels);
	defer allocator.free(extra_info_slice);
	var extra_index: usize = 0;
	if (has_alpha) {
		extra_info_slice[extra_index] = image.alpha_info orelse .{
			.type = .alpha,
			.bit_depth = .{},
			.alpha_associated = image.alpha_associated,
		};
		extra_index += 1;
	}
	for (frame_extra_planes) |extra| {
		extra_info_slice[extra_index] = extra.info;
		extra_index += 1;
	}

	const effective_color_encoding = color_encoding orelse if (image.num_color_channels == 1)
		graySrgbColorEncoding()
	else
		color_encoding_mod.ColorEncoding{};
	if (effective_color_encoding.channels() != image.num_color_channels) return error.Unsupported;
	if (effective_color_encoding.want_icc) return error.Unsupported;

	const codec_meta = buildCodecMetadata(
		image.width,
		image.height,
		num_extra_channels,
		image.alpha_associated,
		image.orientation,
		image.intrinsic_width,
		image.intrinsic_height,
		true,
		image.animation,
		image.tone_mapping,
		extra_info_slice,
		effective_color_encoding,
	);

	const frame_datas = try allocator.alloc([]const u8, image.frames.len);
	defer {
		for (frame_datas) |frame_data| {
			if (frame_data.len != 0) allocator.free(frame_data);
		}
		allocator.free(frame_datas);
	}
	@memset(frame_datas, &.{});

	for (image.frames, 0..) |frame, i| {
		var source = try buildPackedSourceImage(allocator, .{
			.width = image.width,
			.height = image.height,
			.num_color_channels = image.num_color_channels,
			.color_row_stride = frame.color_row_stride,
			.color_pixels = frame.color_pixels,
			.alpha_row_stride = frame.alpha_row_stride,
			.alpha_pixels = frame.alpha_pixels,
			.alpha_associated = image.alpha_associated,
			.alpha_info = image.alpha_info,
			.orientation = image.orientation,
			.intrinsic_width = image.intrinsic_width,
			.intrinsic_height = image.intrinsic_height,
			.have_animation = true,
			.animation = image.animation,
			.frame_duration = frame.frame_duration,
			.frame_timecode = frame.frame_timecode,
			.tone_mapping = image.tone_mapping,
			.extra_planes = frame.extra_planes,
		});
		defer source.deinit();

		var frame_header = buildSimpleFrameHeader(extra_info_slice, frame.frame_duration, frame.frame_timecode);
		frame_header.is_last = i + 1 == image.frames.len;
		frame_datas[i] = try encodePreparedFrameData(allocator, codec_meta, frame_header, &source);
	}

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try enc_codestream.writeCodestreamFrames(&codec_meta, frame_datas, &codestream);
	try codestream.zeroPadToByte();

	return allocator.dupe(u8, codestream.bytes());
}

/// Encodes the current narrow lossless modular surface from interleaved uint8
/// grayscale or RGB pixels by tiling local-tree groups and assembling a full
/// native codestream entirely in Zig.
pub fn encodeSimpleInterleavedU8(
	allocator: std.mem.Allocator,
	image: SimpleInterleavedU8Image,
	color_encoding: ?color_encoding_mod.ColorEncoding,
) ![]u8 {
	try validateSimpleImage(image);
	const num_color_channels = image.num_channels - image.num_extra_channels;

	const effective_color_encoding = color_encoding orelse if (num_color_channels == 1)
		graySrgbColorEncoding()
	else
		color_encoding_mod.ColorEncoding{};
	if (effective_color_encoding.channels() != num_color_channels) return error.Unsupported;
	if (effective_color_encoding.want_icc) return error.Unsupported;

	const codec_meta = buildCodecMetadata(
		image.width,
		image.height,
		image.num_extra_channels,
		image.alpha_associated,
		image.orientation,
		image.intrinsic_width,
		image.intrinsic_height,
		image.have_animation,
		image.animation,
		image.tone_mapping,
		image.extra_channel_info,
		effective_color_encoding,
	);
	const frame_header = buildSimpleFrameHeader(
		codec_meta.m.extra_channel_info[0..@intCast(codec_meta.m.num_extra_channels)],
		image.frame_duration,
		image.frame_timecode,
	);

	var source = try buildSourceImage(allocator, image);
	defer source.deinit();

	return encodePreparedSource(allocator, codec_meta, frame_header, &source);
}

const testing = std.testing;

fn expectCodestreamRoundtrip(
	allocator: std.mem.Allocator,
	encoded: []const u8,
	expected: SimpleInterleavedU8Image,
) !void {
	var br = BitReader.init(encoded[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var parsed_meta = image_metadata.CodecMetadata{};
	parsed_meta.m = metadata;
	parsed_meta.size = size;
	parsed_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, expected.num_channels), image.channels.items.len);
	try testing.expectEqual(@as(usize, expected.width), image.w);
	try testing.expectEqual(@as(usize, expected.height), image.h);

	for (0..image.h) |y| {
		const expected_row = expected.pixels[y * expected.row_stride .. y * expected.row_stride + expected.row_stride];
		for (0..image.w) |x| {
			const pixel_base = x * expected.num_channels;
			for (0..image.channels.items.len) |c| {
				try testing.expectEqual(@as(i32, expected_row[pixel_base + c]), image.channels.items[c].row(y)[x]);
			}
		}
	}
}

fn expectAnimationCodestreamRoundtrip(
	allocator: std.mem.Allocator,
	encoded: []const u8,
	expected_frames: []const SimpleInterleavedU8Image,
	expected_durations: []const u32,
	expected_timecodes: []const u32,
) !void {
	var br = BitReader.init(encoded[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var parsed_meta = image_metadata.CodecMetadata{};
	parsed_meta.m = metadata;
	parsed_meta.size = size;
	parsed_meta.transform_data = transform_data;

	try testing.expect(metadata.have_animation);

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	for (expected_frames, expected_durations, expected_timecodes, 0..) |expected, duration, timecode, i| {
		const frame_bytes = try dec_frame.frameByteCount(allocator, &parsed_meta, encoded[frame_offset..]);

		var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
		defer frame_dec.deinit();
		try frame_dec.decodeFrame(encoded[frame_offset .. frame_offset + frame_bytes]);

		try testing.expectEqual(duration, frame_dec.frame_header.animation_frame.duration);
		try testing.expectEqual(timecode, frame_dec.frame_header.animation_frame.timecode);
		try testing.expectEqual(i + 1 == expected_frames.len, frame_dec.frame_header.is_last);

		const image = frame_dec.getDecodedImage();
		try testing.expectEqual(@as(usize, expected.num_channels), image.channels.items.len);
		try testing.expectEqual(@as(usize, expected.width), image.w);
		try testing.expectEqual(@as(usize, expected.height), image.h);

		for (0..image.h) |y| {
			const expected_row = expected.pixels[y * expected.row_stride .. y * expected.row_stride + expected.row_stride];
			for (0..image.w) |x| {
				const pixel_base = x * expected.num_channels;
				for (0..image.channels.items.len) |c| {
					try testing.expectEqual(@as(i32, expected_row[pixel_base + c]), image.channels.items[c].row(y)[x]);
				}
			}
		}

		frame_offset += frame_bytes;
	}

	try testing.expectEqual(encoded.len, frame_offset);
}

test "encodeSimpleInterleavedU8 round-trips grayscale through FrameDecoder" {
	const pixels = [_]u8{
		10, 20, 30,
		40, 50, 60,
	};
	const image = SimpleInterleavedU8Image{
		.width = 3,
		.height = 2,
		.num_channels = 1,
		.row_stride = 3,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips RGB through FrameDecoder" {
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const image = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 3,
		.row_stride = 6,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips grayscale plus alpha through FrameDecoder" {
	const pixels = [_]u8{
		5, 255, 10, 128, 15, 64,
		20, 32, 25, 16, 30, 0,
	};
	const image = SimpleInterleavedU8Image{
		.width = 3,
		.height = 2,
		.num_channels = 2,
		.num_extra_channels = 1,
		.row_stride = 6,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips RGBA through FrameDecoder" {
	const pixels = [_]u8{
		0, 10, 20, 255, 30, 40, 50, 128,
		60, 70, 80, 64, 90, 100, 110, 0,
	};
	const image = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 4,
		.num_extra_channels = 1,
		.row_stride = 8,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "buildPackedSourceImage matches equivalent interleaved RGBA plus mask source" {
	const interleaved_pixels = [_]u8{
		0, 10, 20, 255, 0, 30, 40, 50, 128, 255,
		60, 70, 80, 64, 255, 90, 100, 110, 0, 0,
	};
	const interleaved = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 5,
		.num_extra_channels = 2,
		.row_stride = 10,
		.pixels = &interleaved_pixels,
		.extra_channel_info = &.{
			.{ .type = .alpha, .bit_depth = .{} },
			.{ .type = .selection_mask, .bit_depth = .{}, .name = "mask", .name_len = 4 },
		},
	};
	var expected = try buildSourceImage(testing.allocator, interleaved);
	defer expected.deinit();

	const color_pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const alpha_pixels = [_]u8{ 255, 128, 64, 0 };
	const mask_pixels = [_]u8{ 0, 255, 255, 0 };
	const extra = [_]SimpleExtraPlaneU8{
		.{
			.info = .{ .type = .selection_mask, .bit_depth = .{}, .name = "mask", .name_len = 4 },
			.row_stride = 2,
			.pixels = &mask_pixels,
		},
	};
	var actual = try buildPackedSourceImage(testing.allocator, .{
		.width = 2,
		.height = 2,
		.num_color_channels = 3,
		.color_row_stride = 6,
		.color_pixels = &color_pixels,
		.alpha_row_stride = 2,
		.alpha_pixels = &alpha_pixels,
		.extra_planes = &extra,
	});
	defer actual.deinit();

	try testing.expectEqual(expected.channels.items.len, actual.channels.items.len);
	for (expected.channels.items, actual.channels.items) |expected_channel, actual_channel| {
		try testing.expectEqual(expected_channel.w, actual_channel.w);
		try testing.expectEqual(expected_channel.h, actual_channel.h);
		try testing.expectEqualSlices(i32, expected_channel.data, actual_channel.data);
	}
}

test "encodeSimplePackedU8 round-trips RGBA plus mask through FrameDecoder" {
	const color_pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const alpha_pixels = [_]u8{ 255, 128, 64, 0 };
	const mask_pixels = [_]u8{ 0, 255, 255, 0 };
	const extra = [_]SimpleExtraPlaneU8{
		.{
			.info = .{
				.type = .selection_mask,
				.bit_depth = .{},
				.name = "mask",
				.name_len = 4,
			},
			.row_stride = 2,
			.pixels = &mask_pixels,
		},
	};

	const encoded = try encodeSimplePackedU8(testing.allocator, .{
		.width = 2,
		.height = 2,
		.num_color_channels = 3,
		.color_row_stride = 6,
		.color_pixels = &color_pixels,
		.alpha_row_stride = 2,
		.alpha_pixels = &alpha_pixels,
		.extra_planes = &extra,
	}, null);
	defer testing.allocator.free(encoded);

	const expected_pixels = [_]u8{
		0, 10, 20, 255, 0, 30, 40, 50, 128, 255,
		60, 70, 80, 64, 255, 90, 100, 110, 0, 0,
	};
	try expectCodestreamRoundtrip(testing.allocator, encoded, .{
		.width = 2,
		.height = 2,
		.num_channels = 5,
		.num_extra_channels = 2,
		.row_stride = 10,
		.pixels = &expected_pixels,
	});
}

test "encodeSimplePackedU8 round-trips RGB plus subsampled depth through FrameDecoder" {
	const color_pixels = [_]u8{
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	};
	const depth_pixels = [_]u8{ 100, 25 };
	const extra = [_]SimpleExtraPlaneU8{
		.{
			.info = .{
				.type = .depth,
				.dim_shift = 1,
				.name = "depth-half",
				.name_len = "depth-half".len,
			},
			.row_stride = 2,
			.pixels = &depth_pixels,
		},
	};

	const encoded = try encodeSimplePackedU8(testing.allocator, .{
		.width = 4,
		.height = 2,
		.num_color_channels = 3,
		.color_row_stride = 12,
		.color_pixels = &color_pixels,
		.extra_planes = &extra,
	}, null);
	defer testing.allocator.free(encoded);

	var br = BitReader.init(encoded[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	try testing.expectEqual(@as(usize, 4), size.xsize());
	try testing.expectEqual(@as(usize, 2), size.ysize());
	try testing.expectEqual(@as(u32, 1), metadata.num_extra_channels);
	try testing.expectEqual(image_metadata.ExtraChannel.depth, metadata.extra_channel_info[0].type);
	try testing.expectEqual(@as(u32, 1), metadata.extra_channel_info[0].dim_shift);

	var parsed_meta = image_metadata.CodecMetadata{};
	parsed_meta.size = size;
	parsed_meta.m = metadata;
	parsed_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(testing.allocator, &parsed_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 4), image.channels.items.len);
	try testing.expectEqual(@as(usize, 2), image.channels.items[3].w);
	try testing.expectEqual(@as(usize, 1), image.channels.items[3].h);
	try testing.expectEqualSlices(i32, &.{ 100, 25 }, image.channels.items[3].data);
}

test "encodeSimplePackedU8Animation round-trips two RGB animation frames" {
	const frame0_rgb = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const frame1_rgb = [_]u8{
		5, 15, 25, 35, 45, 55,
		65, 75, 85, 95, 105, 115,
	};
	const frame0 = SimplePackedU8AnimationFrame{
		.color_row_stride = 6,
		.color_pixels = &frame0_rgb,
		.frame_duration = 3,
		.frame_timecode = 0x01020304,
	};
	const frame1 = SimplePackedU8AnimationFrame{
		.color_row_stride = 6,
		.color_pixels = &frame1_rgb,
		.frame_duration = 5,
		.frame_timecode = 0x05060708,
	};
	const encoded = try encodeSimplePackedU8Animation(testing.allocator, .{
		.width = 2,
		.height = 2,
		.num_color_channels = 3,
		.animation = .{
			.tps_numerator = 24,
			.tps_denominator = 1,
			.num_loops = 2,
			.have_timecodes = true,
		},
		.frames = &.{ frame0, frame1 },
	}, null);
	defer testing.allocator.free(encoded);

	const expected_frame0 = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 3,
		.row_stride = 6,
		.pixels = &frame0_rgb,
	};
	const expected_frame1 = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 3,
		.row_stride = 6,
		.pixels = &frame1_rgb,
	};
	try expectAnimationCodestreamRoundtrip(
		testing.allocator,
		encoded,
		&.{ expected_frame0, expected_frame1 },
		&.{ 3, 5 },
		&.{ 0x01020304, 0x05060708 },
	);
}
