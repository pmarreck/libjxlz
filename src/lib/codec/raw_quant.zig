//! Decode raw quantization weights through the existing modular decoder.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
pub const Params = struct { width: usize, height: usize, stream_id: usize = 0, global: jxl.codec.ac_metadata.GlobalEntropy = .{} };
pub fn decode(allocator: std.mem.Allocator, br: *jxl.base.bit_reader.BitReader, params: Params) jxl.base.status.JxlError![]sf.Fixed {
	return decodeInner(allocator, br, params) catch |err| {
		return if (!br.allReadsWithinBounds()) error.NotEnoughBytes else err;
	};
}
fn decodeInner(allocator: std.mem.Allocator, br: *jxl.base.bit_reader.BitReader, params: Params) jxl.base.status.JxlError![]sf.Fixed {
	if (params.width == 0 or params.height == 0 or params.width > 256 or params.height > 256) return error.GenericError;
	const denominator = try jxl.base.float16.loadFloat16Fixed(@intCast(br.readBits(16)));
	if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
	if (sf.cmp(denominator, sf.parse("0.00000001").?) < 0) return error.GenericError;
	var image = try jxl.modular.modular_image.Image.create(allocator, params.width, params.height, 8, 3);
	defer image.deinit();
	const options = jxl.modular.options.ModularOptions{};
	try jxl.modular.encoding.modularGenericDecompress(br, &image, params.stream_id, &options, true, params.global.tree, params.global.code, params.global.context_map, allocator);
	if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
	if (image.channels.items.len != 3) return error.GenericError;
	const weights = try allocator.alloc(sf.Fixed, 3 * params.width * params.height);
	errdefer allocator.free(weights);
	for (image.channels.items, 0..) |channel, c| {
		if (channel.w != params.width or channel.h != params.height) return error.GenericError;
		for (0..channel.h) |y| for (channel.rowConst(y), 0..) |value, x| {
			if (value <= 0) return error.GenericError;
			weights[(c * params.height + y) * params.width + x] = sf.div(sf.fromInt(1), sf.mul(denominator, sf.fromInt(value)));
		};
	}
	return weights;
}
