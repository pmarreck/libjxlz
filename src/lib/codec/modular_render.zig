//! Lift modular planes into Fixed and reuse the VarDCT pixel filters/sampler.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const filter = jxl.codec.vardct_filters;
pub fn render(dec: *jxl.codec.dec_frame.FrameDecoder) !void {
	const fh = &dec.frame_header;
	const metadata = &dec.metadata.m;
	const xyb = metadata.xyb_encoded or fh.color_transform == .xyb;
	var effects = fh.upsampling != 1 or fh.loop_filter.gab or fh.loop_filter.epf_iters != 0;
	for (fh.extra_channel_upsampling[0..metadata.num_extra_channels]) |factor| effects = effects or factor != 1;
	if (dec.splines.hasAny()) {
		if (effects) return @import("../base/unsupported.zig").unsupported(.splines);
		return dec.renderSplineOverlays();
	}
	if (!effects and !xyb) return;
	if (metadata.bit_depth.floating_point_sample) return @import("../base/unsupported.zig").unsupported(.bit_depth);
	if (!fh.chroma_subsampling.is444()) return @import("../base/unsupported.zig").unsupported(.chroma_subsampling);
	const image = &dec.modular_decoder.full_image;
	const colors = image.channels.items.len - metadata.num_extra_channels;
	if (colors != 3 and (colors != 1 or xyb)) return @import("../base/unsupported.zig").unsupported(.color_channel_count);
	for (metadata.extra_channel_info[0..metadata.num_extra_channels]) |extra| {
		if (extra.bit_depth.floating_point_sample) return @import("../base/unsupported.zig").unsupported(.bit_depth);
	}
	const width = dec.frame_dim.xsize;
	const height = dec.frame_dim.ysize;
	const output = filter.Image{ .width = width, .height = height, .data = try dec.allocator.alloc(sf.Fixed, 3 * width * height) };
	defer dec.allocator.free(output.data);
	const bits = metadata.bit_depth.bits_per_sample;
	if (bits == 0 or bits > 32) return error.GenericError;
	const maximum = sf.fromInt((@as(i64, 1) << @as(u6, @intCast(bits))) - 1);
	for (image.channels.items[0..colors]) |channel| {
		if (channel.w != width or channel.h != height) return error.GenericError;
	}
	for (0..height) |y| for (0..width) |x| {
		const first = image.channels.items[0].rowConst(y)[x];
		const second = if (colors == 1) first else image.channels.items[1].rowConst(y)[x];
		const third = if (colors == 1) first else image.channels.items[2].rowConst(y)[x];
		const values = if (xyb) [3]sf.Fixed{ sf.mul(sf.fromInt(second), dec.dequant_matrices.dc_quant[0]), sf.mul(sf.fromInt(first), dec.dequant_matrices.dc_quant[1]), sf.mul(sf.fromInt(@as(i64, third) + first), dec.dequant_matrices.dc_quant[2]) } else [3]sf.Fixed{ sf.div(sf.fromInt(first), maximum), sf.div(sf.fromInt(second), maximum), sf.div(sf.fromInt(third), maximum) };
		for (values, 0..) |value, c| output.data[(c * height + y) * width + x] = value;
	};
	const params = try filter.Params.fromHeader(fh.loop_filter);
	if (fh.loop_filter.gab) try filter.gaborish(dec.allocator, output, params);
	if (fh.loop_filter.epf_iters != 0) {
		const sigma_value = try jxl.base.float16.loadFloat32Fixed(fh.loop_filter.epf_sigma_for_modular);
		if (sf.cmp(sigma_value, sf.parse("0.00000001").?) < 0) return error.GenericError;
		const sigma = try dec.allocator.alloc(sf.Fixed, ((width + 7) / 8) * ((height + 7) / 8));
		defer dec.allocator.free(sigma);
		@memset(sigma, sf.div(sf.parse("-1.1715728752538099024").?, sigma_value));
		if (fh.loop_filter.epf_iters == 3) try filter.epf(dec.allocator, output, params, sigma, 0);
		try filter.epf(dec.allocator, output, params, sigma, 1);
		if (fh.loop_filter.epf_iters >= 2) try filter.epf(dec.allocator, output, params, sigma, 2);
	}
	try @import("frame_render.zig").finish(dec, output);
}
