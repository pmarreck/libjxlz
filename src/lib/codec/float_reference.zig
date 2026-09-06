//! Reference storage and blending for binary32 samples, including non-finites.
const std = @import("std");
const jxl = @import("../root.zig");
const patch = @import("patches.zig");
const blend = patch.blend;
const FloatImage = jxl.codec.render.FloatImage;
const Error = jxl.base.status.JxlError;
fn mode(info: jxl.codec.frame_header.BlendingInfo) blend.Info {
	return .{ .mode = switch (info.mode) {
		.replace => .replace,
		.add => .add,
		.blend => .blend_above,
		.alpha_weighted_add => .alpha_add_above,
		.mul => .mul,
	}, .alpha_channel = info.alpha_channel, .clamp = info.clamp };
}
fn copy(allocator: std.mem.Allocator, input: FloatImage) Error!FloatImage {
	var result = input;
	result.data = try allocator.dupe(f32, input.data);
	return result;
}
fn background(ref: patch.Reference, c: usize, x: usize, y: usize) u32 {
	if (ref.float_image) |image| return @bitCast(image.rowConst(y, c)[x]);
	if (ref.image) |image| return @import("../base/fixed_display.zig").bits(image.data[(c * image.height + y) * image.width + x]);
	return 0;
}
fn compose(dec: *jxl.codec.dec_frame.FrameDecoder, refs: *[4]patch.Reference, input: FloatImage) Error!FloatImage {
	const metadata = dec.metadata;
	const fh = &dec.frame_header;
	const extras = metadata.m.num_extra_channels;
	const width = metadata.xsize();
	const height = metadata.ysize();
	const channels = input.channels;
	if (channels != 3 + extras) return error.GenericError;
	for (0..extras + 1) |c| {
		const source = if (c == 0) fh.blending_info.source else fh.extra_channel_blending_info[c - 1].source;
		if (source >= 4) return error.GenericError;
		const ref = refs[source];
		if (ref.float_image) |image| {
			if (ref.pre_color or image.channels != channels or image.xsize < width or image.ysize < height) return error.GenericError;
		} else if (ref.image) |image| {
			if (ref.pre_color or image.channels != channels or image.width < width or image.height < height) return error.GenericError;
		}
	}
	var output = try FloatImage.init(dec.allocator, width, height, channels);
	errdefer output.deinit();
	const info = try dec.allocator.alloc(blend.Extra, extras);
	defer dec.allocator.free(info);
	for (info, 0..) |*item, e| item.* = .{ .is_alpha = metadata.m.extra_channel_info[e].type == .alpha, .associated = metadata.m.extra_channel_info[e].alpha_associated, .blend = mode(fh.extra_channel_blending_info[e]) };
	const storage = try dec.allocator.alloc(u32, 3 * channels);
	defer dec.allocator.free(storage);
	const bg = storage[0..channels];
	const fg = storage[channels..][0..channels];
	const result = storage[2 * channels ..];
	for (0..height) |y| for (0..width) |x| {
		for (bg, 0..) |*value, c| {
			const source = if (c < 3) fh.blending_info.source else fh.extra_channel_blending_info[c - 3].source;
			value.* = background(refs[source], c, x, y);
		}
		const fx = @as(i64, @intCast(x)) - fh.frame_origin.x0;
		const fy = @as(i64, @intCast(y)) - fh.frame_origin.y0;
		if (fx >= 0 and fy >= 0 and fx < input.xsize and fy < input.ysize) {
			for (fg, 0..) |*value, c| value.* = @bitCast(input.rowConst(@intCast(fy), c)[@intCast(fx)]);
			try blend.pixelBinary32(bg, fg, result, mode(fh.blending_info), info);
		} else @memcpy(result, bg);
		for (result, 0..) |value, c| output.row(y, c)[x] = @bitCast(value);
	};
	return output;
}
pub fn finish(dec: *jxl.codec.dec_frame.FrameDecoder, refs: *[4]patch.Reference, coalescing: bool, post_color: bool) Error!void {
	const fh = &dec.frame_header;
	const input = dec.rendered_image orelse return error.GenericError;
	const regular = fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive;
	const metadata = dec.metadata;
	const xyb = metadata.m.xyb_encoded or fh.color_transform == .xyb;
	const ycbcr = fh.color_transform == .ycbcr;
	var converted: ?FloatImage = null;
	defer if (converted) |*image| image.deinit();
	if (post_color) {
		converted = try copy(dec.allocator, input);
		const params = if (ycbcr) null else try jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
		for (0..input.ysize) |y| for (0..input.xsize) |x| {
			if (ycbcr) {
				const rgb = @import("chroma.zig").toRgbBinary32(@bitCast(input.rowConst(y, 0)[x]), @bitCast(input.rowConst(y, 1)[x]), @bitCast(input.rowConst(y, 2)[x]));
				for (rgb, 0..) |value, c| converted.?.row(y, c)[x] = @bitCast(value);
			} else {
				const rgb = try jxl.codec.xyb.toOutputRgb(input.rowConst(y, 0)[x], input.rowConst(y, 1)[x], input.rowConst(y, 2)[x], &params.?, &metadata.m);
				for (rgb, 0..) |value, c| converted.?.row(y, c)[x] = value;
			}
		};
	}
	const pixels = converted orelse input;
	var output = if (coalescing and regular and (!xyb or post_color)) try compose(dec, refs, pixels) else try copy(dec.allocator, pixels);
	errdefer output.deinit();
	if (fh.canBeReferenced() and (fh.save_before_color_transform or coalescing)) {
		if (fh.save_as_reference >= 4) return error.GenericError;
		const saved = try copy(dec.allocator, if (fh.save_before_color_transform) input else output);
		const slot = &refs[fh.save_as_reference];
		if (slot.image) |old| dec.allocator.free(old.data);
		if (slot.float_image) |*old| old.deinit();
		slot.* = .{ .float_image = saved, .pre_color = fh.save_before_color_transform };
	}
	dec.rendered_image.?.deinit();
	dec.rendered_image = output;
	dec.rendered_in_output_space = post_color;
}
