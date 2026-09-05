//! Integer binary32 filters over already reconstructed floating sample storage.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = @import("../base/binary32.zig");
const filter = @import("vardct_filters.zig").Binary32;
pub fn apply(dec: *jxl.codec.dec_frame.FrameDecoder) !void {
	const fh = &dec.frame_header;
	const rendered = dec.rendered_image orelse return error.GenericError;
	const count = 3 * rendered.xsize * rendered.ysize;
	const data = @as([*]u32, @ptrCast(rendered.data.ptr))[0..count];
	const image = filter.PixelImage{ .width = rendered.xsize, .height = rendered.ysize, .data = data };
	const params = try filter.FilterParams.fromHeader(fh.loop_filter);
	if (fh.loop_filter.gab) try filter.gaborish(dec.allocator, image, params);
	if (fh.loop_filter.epf_iters != 0) {
		const sigma_value = try sf.fromF32(fh.loop_filter.epf_sigma_for_modular);
		if (sf.cmp(sigma_value, comptime sf.parse("0.00000001").?) < 0) return error.GenericError;
		const sigma = try dec.allocator.alloc(u32, ((image.width + 7) / 8) * ((image.height + 7) / 8));
		defer dec.allocator.free(sigma);
		@memset(sigma, sf.div(comptime sf.parse("-1.1715728752538099024").?, sigma_value));
		if (fh.loop_filter.epf_iters == 3) try filter.epf(dec.allocator, image, params, sigma, 0);
		try filter.epf(dec.allocator, image, params, sigma, 1);
		if (fh.loop_filter.epf_iters >= 2) try filter.epf(dec.allocator, image, params, sigma, 2);
	}
	try @import("frame_render.zig").finishBinary32(dec, image);
	var previous = rendered;
	previous.deinit();
}
