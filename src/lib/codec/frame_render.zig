//! Shared sampling and patch application after color reconstruction/filtering.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const display = @import("../base/fixed_display.zig");
const up = @import("upsampling.zig");
const Plane = struct { width: usize = 0, height: usize = 0, data: []sf.Fixed = &.{} };
pub fn finish(dec: *jxl.codec.dec_frame.FrameDecoder, output: jxl.codec.vardct_filters.Image) !void {
	const fh = &dec.frame_header;
	const metadata = &dec.metadata.m;
	const width = dec.frame_dim.xsize_upsampled;
	const height = dec.frame_dim.ysize_upsampled;
	const channels = 3 + metadata.num_extra_channels;
	var late = fh.upsampling != 1;
	for (fh.extra_channel_upsampling[0..metadata.num_extra_channels]) |factor| late = late and factor == fh.upsampling;
	const planes = try dec.allocator.alloc(Plane, channels);
	defer dec.allocator.free(planes);
	@memset(planes, .{});
	defer for (planes[3..]) |plane| dec.allocator.free(plane.data);
	for (planes[0..3], 0..) |*plane, c| plane.* = .{ .width = output.width, .height = output.height, .data = output.data[c * output.width * output.height ..][0 .. output.width * output.height] };
	for (planes[3..], 0..) |*plane, e| {
		const channel = &dec.modular_decoder.full_image.channels.items[dec.modular_decoder.full_image.channels.items.len - metadata.num_extra_channels + e];
		const bits = metadata.extra_channel_info[e].bit_depth.bits_per_sample;
		if (bits == 0 or bits > 32) return error.GenericError;
		const maximum = sf.fromInt((@as(i64, 1) << @as(u6, @intCast(bits))) - 1);
		plane.* = .{ .width = channel.w, .height = channel.h, .data = try dec.allocator.alloc(sf.Fixed, channel.w * channel.h) };
		for (0..channel.h) |y| for (channel.rowConst(y)[0..channel.w], plane.data[y * channel.w ..][0..channel.w]) |raw, *value| {
			value.* = sf.div(sf.fromInt(raw), maximum);
		};
		if (!late and fh.extra_channel_upsampling[e] != 1) {
			const sampled = try up.fromMetadata(dec.allocator, .{ .width = plane.width, .height = plane.height, .data = plane.data }, @intCast(fh.extra_channel_upsampling[e]), &dec.metadata.transform_data, width, height);
			dec.allocator.free(plane.data);
			plane.* = .{ .width = width, .height = height, .data = sampled };
		}
	}
	if (dec.patches) |*dictionary| {
		const values = try dec.allocator.alloc(sf.Fixed, output.width * output.height * channels);
		defer dec.allocator.free(values);
		for (planes, 0..) |plane, c| {
			if (plane.width < output.width or plane.height < output.height) return error.GenericError;
			for (0..output.height) |y| @memcpy(values[(c * output.height + y) * output.width ..][0..output.width], plane.data[y * plane.width ..][0..output.width]);
		}
		const extras = try dec.allocator.alloc(@import("blending.zig").Extra, metadata.num_extra_channels);
		defer dec.allocator.free(extras);
		for (extras, 0..) |*extra, e| extra.* = .{ .is_alpha = metadata.extra_channel_info[e].type == .alpha, .associated = metadata.extra_channel_info[e].alpha_associated };
		try dictionary.apply(.{ .width = output.width, .height = output.height, .channels = channels, .data = values }, dec.references orelse return error.GenericError, extras);
		for (planes, 0..) |plane, c| for (0..output.height) |y| {
			@memcpy(plane.data[y * plane.width ..][0..output.width], values[(c * output.height + y) * output.width ..][0..output.width]);
		};
	}
	var rendered = try jxl.codec.render.FloatImage.init(dec.allocator, width, height, channels);
	errdefer rendered.deinit();
	const noise_pixels = if (dec.noise.hasAny()) try dec.allocator.alloc(sf.Fixed, 3 * width * height) else null;
	defer if (noise_pixels) |pixels| dec.allocator.free(pixels);
	for (planes, 0..) |plane, c| {
		const factor = if (c < 3 or late) fh.upsampling else 1;
		const sampled = if (factor == 1) null else try up.fromMetadata(dec.allocator, .{ .width = plane.width, .height = plane.height, .data = plane.data }, @intCast(factor), &dec.metadata.transform_data, width, height);
		defer if (sampled) |data| dec.allocator.free(data);
		if ((sampled orelse plane.data).len != width * height) return error.GenericError;
		if (c < 3) if (noise_pixels) |pixels| {
			@memcpy(pixels[c * width * height ..][0 .. width * height], sampled orelse plane.data);
			continue;
		};
		for (sampled orelse plane.data, rendered.data[c * width * height ..][0 .. width * height]) |value, *dest| dest.* = @bitCast(display.bits(value));
	}
	if (noise_pixels) |pixels| {
		const cfl = if (dec.vardct_global) |global| global.color_correlation.base else [2]sf.Fixed{ sf.Fixed.zero, sf.fromInt(@intFromBool(metadata.xyb_encoded)) };
		try @import("noise.zig").apply(dec.allocator, .{ .width = width, .height = height, .data = pixels }, dec.noise, .{ .visible = dec.visible_frame_index, .nonvisible = dec.nonvisible_frame_index, .group_dim = dec.frame_dim.grp_dim }, cfl);
		for (pixels, rendered.data[0..pixels.len]) |value, *dest| dest.* = @bitCast(display.bits(value));
	}
	dec.rendered_image = rendered;
}
