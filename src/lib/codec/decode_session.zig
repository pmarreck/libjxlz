//! Own references across decoded frames and compose layers in Fixed.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const patch = @import("patches.zig");
const blend = patch.blend;
const FrameDecoder = jxl.codec.dec_frame.FrameDecoder;
const Error = jxl.base.status.JxlError;
const display = @import("../base/fixed_display.zig");
fn mode(info: jxl.codec.frame_header.BlendingInfo) blend.Info {
	return .{ .mode = switch (info.mode) {
		.replace => .replace,
		.add => .add,
		.blend => .blend_above,
		.alpha_weighted_add => .alpha_add_above,
		.mul => .mul,
	}, .alpha_channel = info.alpha_channel, .clamp = info.clamp };
}
pub const Session = struct {
	allocator: std.mem.Allocator,
	refs: [4]patch.Reference = @splat(.{}),
	dc_refs: [4]?patch.Image = @splat(null),
	coalescing: bool = true,
	visible_frame_index: u32 = 0,
	nonvisible_frame_index: u32 = 0,
	pub fn init(allocator: std.mem.Allocator) Session {
		return .{ .allocator = allocator };
	}
	pub fn deinit(self: *Session) void {
		self.visible_frame_index = 0;
		self.nonvisible_frame_index = 0;
		for (&self.dc_refs) |*slot| {
			if (slot.*) |image| self.allocator.free(image.data);
			slot.* = null;
		}
		for (&self.refs) |*ref| {
			if (ref.image) |image| self.allocator.free(image.data);
			ref.* = .{};
		}
	}
	pub fn decode(self: *Session, metadata: *const jxl.codec.image_metadata.CodecMetadata, data: []const u8) Error!FrameDecoder {
		var dec = FrameDecoder.init(self.allocator, metadata);
		errdefer dec.deinit();
		dec.force_render = true;
		dec.visible_frame_index = self.visible_frame_index;
		dec.nonvisible_frame_index = self.nonvisible_frame_index;
		dec.references = &self.refs;
		dec.dc_references = &self.dc_refs;
		try dec.decodeFrame(data);
		try self.finish(&dec);
		self.visible_frame_index = dec.visible_frame_index;
		self.nonvisible_frame_index = dec.nonvisible_frame_index;
		return dec;
	}
	fn finish(self: *Session, dec: *FrameDecoder) Error!void {
		const fh = &dec.frame_header;
		const metadata = dec.metadata;
		if (fh.frame_type == .dc_frame) {
			if (fh.dc_level == 0 or fh.dc_level > 4) return error.GenericError;
			const rendered = dec.rendered_image orelse return error.GenericError;
			if (rendered.channels < 3) return error.GenericError;
			const values = try self.allocator.alloc(sf.Fixed, 3 * rendered.xsize * rendered.ysize);
			errdefer self.allocator.free(values);
			for (rendered.data[0..values.len], values) |value, *dest| dest.* = try jxl.base.float16.loadFloat32Fixed(value);
			const slot = &self.dc_refs[fh.dc_level - 1];
			if (slot.*) |old| self.allocator.free(old.data);
			slot.* = .{ .width = rendered.xsize, .height = rendered.ysize, .channels = 3, .data = values };
			return;
		}
		const ycbcr = fh.color_transform == .ycbcr;
		if (!fh.canBeReferenced() and !fh.needsBlending(metadata.m.num_extra_channels) and !ycbcr) return;
		const rendered = dec.rendered_image orelse return error.GenericError;
		const xyb = metadata.m.xyb_encoded or fh.color_transform == .xyb;
		if (!xyb and !ycbcr and fh.color_transform != .none) return error.Unsupported;
		const input = patch.Image{ .width = rendered.xsize, .height = rendered.ysize, .channels = rendered.channels, .data = try self.allocator.alloc(sf.Fixed, rendered.data.len) };
		defer self.allocator.free(input.data);
		for (rendered.data, input.data) |value, *dest| dest.* = try jxl.base.float16.loadFloat32Fixed(value);
		const regular = fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive;
		const post_color = (xyb and self.coalescing and (!fh.save_before_color_transform or (regular and fh.needsBlending(metadata.m.num_extra_channels)))) or (ycbcr and (regular or !fh.save_before_color_transform));
		var converted: ?patch.Image = null;
		defer if (converted) |image| self.allocator.free(image.data);
		if (post_color) {
			const owned = try self.allocator.dupe(sf.Fixed, input.data);
			converted = input;
			converted.?.data = owned;
			const params = jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
			for (0..input.height) |y| for (0..input.width) |x| {
				if (ycbcr) {
					const area = input.width * input.height;
					const offset = y * input.width + x;
					const rgb = @import("chroma.zig").toRgb(input.data[offset], input.data[area + offset], input.data[2 * area + offset]);
					for (rgb, 0..) |value, c| converted.?.data[c * area + offset] = value;
				} else {
					const rgb = try jxl.codec.xyb.toOutputRgb(rendered.rowConst(y, 0)[x], rendered.rowConst(y, 1)[x], rendered.rowConst(y, 2)[x], &params, &metadata.m);
					for (rgb, 0..) |value, c| converted.?.data[(c * input.height + y) * input.width + x] = try jxl.base.float16.loadFloat32Fixed(value);
				}
			};
		}
		const pixels = converted orelse input;
		const composed = if (self.coalescing and regular and (!xyb or post_color)) try self.compose(pixels, fh, metadata) else null;
		defer if (composed) |image| self.allocator.free(image.data);
		var final = try jxl.codec.render.FloatImage.init(self.allocator, if (composed) |image| image.width else input.width, if (composed) |image| image.height else input.height, input.channels);
		errdefer final.deinit();
		for (if (composed) |image| image.data else pixels.data, final.data) |value, *dest| dest.* = @bitCast(display.bits(value));
		if (fh.canBeReferenced() and (fh.save_before_color_transform or self.coalescing)) {
			if (fh.save_as_reference >= 4) return error.GenericError;
			const saved = if (fh.save_before_color_transform) input else composed orelse pixels;
			const owned = try self.allocator.dupe(sf.Fixed, saved.data);
			const slot = &self.refs[fh.save_as_reference];
			if (slot.image) |old| self.allocator.free(old.data);
			slot.* = .{ .image = .{ .width = saved.width, .height = saved.height, .channels = saved.channels, .data = owned }, .pre_color = fh.save_before_color_transform };
		}
		dec.rendered_image.?.deinit();
		dec.rendered_image = final;
		dec.rendered_in_output_space = post_color;
	}
	fn compose(self: *Session, input: patch.Image, fh: *const jxl.codec.frame_header.FrameHeader, metadata: *const jxl.codec.image_metadata.CodecMetadata) Error!patch.Image {
		const width = metadata.xsize();
		const height = metadata.ysize();
		const channels = input.channels;
		const extras = metadata.m.num_extra_channels;
		if (channels != extras + 3) return error.GenericError;
		const length = std.math.mul(usize, std.math.mul(usize, width, height) catch return error.GenericError, channels) catch return error.GenericError;
		for (0..extras + 1) |c| {
			const source = if (c == 0) fh.blending_info.source else fh.extra_channel_blending_info[c - 1].source;
			if (source >= 4) return error.GenericError;
			if (self.refs[source].image) |image| {
				if (self.refs[source].pre_color or image.channels != channels or image.width < width or image.height < height) return error.GenericError;
			}
		}
		const output = patch.Image{ .width = width, .height = height, .channels = channels, .data = try self.allocator.alloc(sf.Fixed, length) };
		errdefer self.allocator.free(output.data);
		const info = try self.allocator.alloc(blend.Extra, extras);
		defer self.allocator.free(info);
		for (info, 0..) |*item, e| item.* = .{ .is_alpha = metadata.m.extra_channel_info[e].type == .alpha, .associated = metadata.m.extra_channel_info[e].alpha_associated, .blend = mode(fh.extra_channel_blending_info[e]) };
		const storage = try self.allocator.alloc(sf.Fixed, 3 * channels);
		defer self.allocator.free(storage);
		const bg = storage[0..channels];
		const fg = storage[channels..][0..channels];
		const result = storage[2 * channels ..];
		for (0..height) |y| for (0..width) |x| {
			for (bg, 0..) |*value, c| {
				const source = if (c < 3) fh.blending_info.source else fh.extra_channel_blending_info[c - 3].source;
				value.* = if (self.refs[source].image) |image| image.data[(c * image.height + y) * image.width + x] else sf.Fixed.zero;
			}
			const fx = @as(i64, @intCast(x)) - fh.frame_origin.x0;
			const fy = @as(i64, @intCast(y)) - fh.frame_origin.y0;
			if (fx >= 0 and fy >= 0 and fx < input.width and fy < input.height) {
				for (fg, 0..) |*value, c| value.* = input.data[(c * input.height + @as(usize, @intCast(fy))) * input.width + @as(usize, @intCast(fx))];
				try blend.pixel(bg, fg, result, mode(fh.blending_info), info);
			} else @memcpy(result, bg);
			for (result, 0..) |value, c| output.data[(c * height + y) * width + x] = value;
		};
		return output;
	}
};
