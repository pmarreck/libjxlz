const std = @import("std");

const JxlError = @import("../lib/base/status.zig").JxlError;
const image_metadata = @import("../lib/codec/image_metadata.zig");
const dec_frame = @import("../lib/codec/dec_frame.zig");
const render_mod = @import("../lib/codec/render.zig");
const xyb_mod = @import("../lib/codec/xyb.zig");
const Image = @import("../lib/modular/modular_image.zig").Image;
const pixel_format = @import("pixel_format.zig");

pub const JxlPixelFormat = pixel_format.JxlPixelFormat;

const bytesPerChannel = pixel_format.bytesPerChannel;
const rowStrideBytes = pixel_format.rowStrideBytes;
const storeU16 = pixel_format.storeU16;
const storeU32 = pixel_format.storeU32;
const normalizedFloat = pixel_format.normalizedFloat;
const scaleToU8 = pixel_format.scaleToU8;
const clampNormalizedSample = pixel_format.clampNormalizedSample;
const scaleRenderedToU8 = pixel_format.scaleRenderedToU8;

fn bitDepthMax(bits_per_sample: u32) u32 {
	if (bits_per_sample == 0) return 0;
	if (bits_per_sample >= 32) return std.math.maxInt(u32);
	return (@as(u32, 1) << @intCast(bits_per_sample)) - 1;
}

/// Locates the first alpha extra channel so C API buffer writers and metadata
/// export agree on the same alpha-plane-to-channel mapping.
pub fn alphaChannelIndex(metadata: *const image_metadata.ImageMetadata) ?usize {
	for (0..metadata.num_extra_channels) |i| {
		if (metadata.extra_channel_info[i].type == .alpha) {
			return @as(usize, @intCast(i));
		}
	}
	return null;
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
	return renderedAlphaOutputValue(rendered, alpha_img, metadata, x, y);
}

fn renderedAlphaOutputValue(rendered: *const render_mod.FloatImage, alpha_img: ?*const Image, metadata: *const image_metadata.ImageMetadata, x: usize, y: usize) f32 {
	if (alphaChannelIndex(metadata)) |index| {
		if (rendered.channels > 3 + index) return rendered.rowConst(y, 3 + index)[x];
	}
	return normalizedAlphaOutputValue(alpha_img, metadata, x, y);
}

fn normalizedAlphaOutputValue(alpha_img: ?*const Image, metadata: *const image_metadata.ImageMetadata, x: usize, y: usize) f32 {
	if (alpha_img) |img| {
		if (alphaChannelIndex(metadata)) |idx| {
			const color_channels = img.channels.items.len - metadata.num_extra_channels;
			const extra = metadata.extra_channel_info[idx];
			return normalizedFloat(img.channels.items[color_channels + idx].rowConst(y)[x], bitDepthMax(extra.bit_depth.bits_per_sample));
		}
	}
	return 1.0;
}

/// Writes the decoded planar modular image into the caller-owned interleaved
/// pixel buffer described by JxlPixelFormat, including row alignment handling.
pub fn writeImageToOutput(img: *const Image, metadata: *const image_metadata.ImageMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
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

/// Writes a post-render normalized float RGB image into the public C API output
/// buffer; XYB-to-output color conversion is a separate stage.
pub fn writeRenderedImageToOutput(rendered: *const render_mod.FloatImage, alpha_img: ?*const Image, metadata: *const image_metadata.ImageMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	const gray = metadata.color_encoding.channels() == 1;
	if (!gray and metadata.color_encoding.channels() != 3) return error.Unsupported;
	if (rendered.channels < 3) return error.Unsupported;
	if (format.num_channels < (if (gray) @as(u32, 1) else 3) or format.num_channels > 4) return error.Unsupported;

	const stride = rowStrideBytes(rendered.xsize, format) orelse return error.Unsupported;
	if (stride * rendered.ysize > buffer_size) return error.GenericError;

	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return error.Unsupported;
	const num_channels: usize = @intCast(format.num_channels);

	if (format.data_type == .JXL_TYPE_UINT8 and format.num_channels == 3) {
		for (0..rendered.ysize) |y| {
			const dst = buffer[y * stride .. y * stride + rendered.xsize * 3];
			const row_r = rendered.rowConst(y, 0);
			const row_g = rendered.rowConst(y, 1);
			const row_b = rendered.rowConst(y, 2);
			for (0..rendered.xsize) |x| {
				dst[x * 3 + 0] = scaleRenderedToU8(row_r[x], x, y, 0);
				dst[x * 3 + 1] = scaleRenderedToU8(row_g[x], x, y, 1);
				dst[x * 3 + 2] = scaleRenderedToU8(row_b[x], x, y, 2);
			}
		}
		return;
	}

	for (0..rendered.ysize) |y| {
		const row = buffer[y * stride .. y * stride + stride];
		for (0..rendered.xsize) |x| {
			const pixel = row[x * num_channels * bytes_per_channel ..];
			for (0..num_channels) |c| {
				const source_channel = if (gray and num_channels == 2 and c == 1) 3 else c;
				const value = renderedOutputValue(rendered, alpha_img, metadata, x, y, source_channel);
				const normalized = clampNormalizedSample(value);
				switch (format.data_type) {
					.JXL_TYPE_UINT8 => {
						pixel[c] = scaleRenderedToU8(normalized, x, y, c);
					},
					.JXL_TYPE_UINT16 => {
						const scaled: u32 = @intFromFloat(@round(normalized * 65535.0));
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, @intCast(scaled));
					},
					.JXL_TYPE_FLOAT => {
						const raw: u32 = @bitCast(value);
						storeU32(pixel[c * 4 .. c * 4 + 4], format.endianness, raw);
					},
					.JXL_TYPE_FLOAT16 => {
						const half: f16 = @floatCast(value);
						const raw: u16 = @bitCast(half);
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, raw);
					},
				}
			}
		}
	}
}

/// Converts rendered XYB float rows through the scalar inverse-opsin path and
/// writes normalized RGB samples into the public C API's interleaved buffer.
fn xybToOutputRgb(x: f32, y: f32, b: f32, params: *const xyb_mod.OpsinParams, metadata: *const image_metadata.ImageMetadata) JxlError![3]f32 {
	return xyb_mod.toOutputRgb(x, y, b, params, metadata);
}

pub fn writeXYBRenderedImageToOutput(rendered: *const render_mod.FloatImage, alpha_img: ?*const Image, codec_meta: *const image_metadata.CodecMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	const metadata = &codec_meta.m;
	const gray = metadata.color_encoding.isGray();
	if (!gray and metadata.color_encoding.channels() != 3) return error.Unsupported;
	if (rendered.channels < 3) return error.Unsupported;
	if (format.num_channels < (if (gray) @as(u32, 1) else 3) or format.num_channels > 4) return error.Unsupported;

	const stride = rowStrideBytes(rendered.xsize, format) orelse return error.Unsupported;
	if (stride * rendered.ysize > buffer_size) return error.GenericError;

	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return error.Unsupported;
	const num_channels: usize = @intCast(format.num_channels);
	const params = try xyb_mod.opsinParams(metadata, &codec_meta.transform_data);

	if (format.data_type == .JXL_TYPE_UINT8 and format.num_channels == 3) {
		for (0..rendered.ysize) |y| {
			const dst = buffer[y * stride .. y * stride + rendered.xsize * 3];
			const row_x = rendered.rowConst(y, 0);
			const row_y = rendered.rowConst(y, 1);
			const row_b = rendered.rowConst(y, 2);
			for (0..rendered.xsize) |x| {
				const rgb = try xybToOutputRgb(row_x[x], row_y[x], row_b[x], &params, metadata);
				dst[x * 3 + 0] = scaleRenderedToU8(rgb[0], x, y, 0);
				dst[x * 3 + 1] = scaleRenderedToU8(rgb[1], x, y, 1);
				dst[x * 3 + 2] = scaleRenderedToU8(rgb[2], x, y, 2);
			}
		}
		return;
	}

	for (0..rendered.ysize) |y| {
		const row = buffer[y * stride .. y * stride + stride];
		const row_x = rendered.rowConst(y, 0);
		const row_y = rendered.rowConst(y, 1);
		const row_b = rendered.rowConst(y, 2);
		for (0..rendered.xsize) |x| {
			const rgb = try xybToOutputRgb(row_x[x], row_y[x], row_b[x], &params, metadata);
			const pixel = row[x * num_channels * bytes_per_channel ..];
			for (0..num_channels) |c| {
				const color_channels: usize = if (num_channels <= 2) 1 else 3;
				const value = if (c < color_channels) rgb[c] else renderedAlphaOutputValue(rendered, alpha_img, metadata, x, y);
				const normalized = clampNormalizedSample(value);
				switch (format.data_type) {
					.JXL_TYPE_UINT8 => {
						pixel[c] = scaleRenderedToU8(normalized, x, y, c);
					},
					.JXL_TYPE_UINT16 => {
						const scaled: u32 = @intFromFloat(@round(normalized * 65535.0));
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, @intCast(scaled));
					},
					.JXL_TYPE_FLOAT => {
						const raw: u32 = @bitCast(value);
						storeU32(pixel[c * 4 .. c * 4 + 4], format.endianness, raw);
					},
					.JXL_TYPE_FLOAT16 => {
						const half: f16 = @floatCast(value);
						const raw: u16 = @bitCast(half);
						storeU16(pixel[c * 2 .. c * 2 + 2], format.endianness, raw);
					},
				}
			}
		}
	}
}

/// Dispatches decoded frame output through the integer, rendered-output, or XYB
/// conversion writer so the public C API exposes one buffer-filling seam.
pub fn writeFrameDecoderOutput(frame_dec: *dec_frame.FrameDecoder, codec_meta: *const image_metadata.CodecMetadata, format: JxlPixelFormat, buffer: [*]u8, buffer_size: usize) JxlError!void {
	const metadata = &codec_meta.m;
	if (frame_dec.rendered_image) |*rendered| {
		if (!frame_dec.rendered_in_output_space and (metadata.xyb_encoded or frame_dec.frame_header.color_transform == .xyb)) {
			return writeXYBRenderedImageToOutput(rendered, frame_dec.getDecodedImage(), codec_meta, format, buffer, buffer_size);
		}
		return writeRenderedImageToOutput(rendered, frame_dec.getDecodedImage(), metadata, format, buffer, buffer_size);
	}
	return writeImageToOutput(frame_dec.getDecodedImage(), metadata, format, buffer, buffer_size);
}
