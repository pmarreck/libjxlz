//! Shared sampling and output conversion after color reconstruction/filtering.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const display = @import("../base/fixed_display.zig");
pub fn finish(dec: *jxl.codec.dec_frame.FrameDecoder, output: jxl.codec.vardct_filters.Image) !void {
	const fh = &dec.frame_header;
	const width = dec.frame_dim.xsize_upsampled;
	const height = dec.frame_dim.ysize_upsampled;
	var rendered = try jxl.codec.render.FloatImage.init(dec.allocator, width, height, 3 + dec.metadata.m.num_extra_channels);
	errdefer rendered.deinit();
	for (0..3) |c| {
		const source = output.data[c * output.width * output.height ..][0 .. output.width * output.height];
		const sampled = if (fh.upsampling == 1) null else try @import("upsampling.zig").fromMetadata(dec.allocator, .{ .width = output.width, .height = output.height, .data = source }, @intCast(fh.upsampling), &dec.metadata.transform_data, width, height);
		defer if (sampled) |values| dec.allocator.free(values);
		for (sampled orelse source, rendered.data[c * width * height ..][0 .. width * height]) |value, *dest| dest.* = @bitCast(display.bits(value));
	}
	for (0..dec.metadata.m.num_extra_channels) |index| {
		const channel = &dec.modular_decoder.full_image.channels.items[dec.modular_decoder.full_image.channels.items.len - dec.metadata.m.num_extra_channels + index];
		const values = try dec.allocator.alloc(sf.Fixed, channel.w * channel.h);
		defer dec.allocator.free(values);
		const bits = dec.metadata.m.extra_channel_info[index].bit_depth.bits_per_sample;
		if (bits == 0 or bits > 32) return error.GenericError;
		const maximum = sf.fromInt((@as(i64, 1) << @as(u6, @intCast(bits))) - 1);
		for (0..channel.h) |y| for (channel.rowConst(y)[0..channel.w], values[y * channel.w ..][0..channel.w]) |raw, *value| {
			value.* = sf.div(sf.fromInt(raw), maximum);
		};
		const factor = fh.extra_channel_upsampling[index];
		const sampled = if (factor == 1) null else try @import("upsampling.zig").fromMetadata(dec.allocator, .{ .width = channel.w, .height = channel.h, .data = values }, @intCast(factor), &dec.metadata.transform_data, width, height);
		defer if (sampled) |data_values| dec.allocator.free(data_values);
		for (sampled orelse values, rendered.data[(3 + index) * width * height ..][0 .. width * height]) |value, *dest| dest.* = @bitCast(display.bits(value));
	}
	dec.rendered_image = rendered;
}
