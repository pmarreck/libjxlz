//! Recover JPEG tables and quantized blocks before VarDCT pixel rendering.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const Error = jxl.base.status.JxlError;
const Decoder = jxl.codec.dec_frame.FrameDecoder;
const jpeg = jxl.codec.jpeg_reconstruction;
const cfl_precision = 11;
const cfl_one: i32 = 1 << cfl_precision;
const cfl_round: i32 = cfl_one / 2;
fn componentIndex(dec: *const Decoder, c: usize) usize {
	if (dec.jpeg_output.?.components.len == 1) return 0;
	return if (dec.frame_header.color_transform == .ycbcr and c < 2) c ^ 1 else c;
}
pub fn prepare(dec: *Decoder) Error!void {
	const output = dec.jpeg_output.?;
	const fh = &dec.frame_header;
	if (fh.encoding != .var_dct or dec.metadata.m.xyb_encoded or fh.color_transform == .xyb) return error.GenericError;
	if (output.components.len != 1 and output.components.len != 3) return error.GenericError;
	const correlation = &dec.vardct_global.?.color_correlation;
	if (correlation.color_factor != 84 or correlation.dc[0] != 0 or correlation.dc[1] != 0 or sf.cmp(correlation.base[0], sf.Fixed.zero) != 0 or sf.cmp(correlation.base[1], sf.Fixed.zero) != 0) return error.GenericError;
	const encoding = &dec.dequant_matrices.encodings[0];
	if (encoding.mode != .raw or encoding.raw.values.len != 192) return error.GenericError;
	var difference = sf.sub(encoding.raw.denominator, sf.div(sf.fromInt(1), sf.fromInt(8 * 255)));
	if (sf.cmp(difference, sf.Fixed.zero) < 0) difference = sf.neg(difference);
	if (sf.cmp(difference, sf.parse("0.00000001").?) > 0) return error.GenericError;
	for (encoding.raw.values) |value| if (value <= 0 or value >= 65536) return error.GenericError;
	output.width = dec.frame_dim.xsize;
	output.height = dec.frame_dim.ysize;
	const memory = output.arena.allocator();
	for (0..output.components.len) |c| {
		const index = if (output.components.len == 1) 0 else if (c < 2) c ^ 1 else c;
		const component = &output.components[index];
		component.width_blocks = dec.frame_dim.xsize_blocks >> @intCast(fh.chroma_subsampling.hShift(c));
		component.height_blocks = dec.frame_dim.ysize_blocks >> @intCast(fh.chroma_subsampling.vShift(c));
		component.h_sampling = @as(u8, 1) << @intCast(fh.chroma_subsampling.maxhs - fh.chroma_subsampling.hShift(c));
		component.v_sampling = @as(u8, 1) << @intCast(fh.chroma_subsampling.maxvs - fh.chroma_subsampling.vShift(c));
		const count = 64 * component.width_blocks * component.height_blocks;
		component.coefficients = try memory.alloc(i16, count);
		@memset(component.coefficients, 0);
	}
	var used: u4 = 0;
	for (0..output.components.len) |c| {
		const quant_channel = if (output.components.len == 1) 1 else c;
		const quant_index = output.components[componentIndex(dec, c)].quant_index;
		if (quant_index >= output.quant.len) return error.GenericError;
		used |= @as(u4, 1) << quant_index;
		for (0..64) |i| output.quant[quant_index].values[i] = encoding.raw.values[64 * quant_channel + (i % 8) * 8 + i / 8];
	}
	for (output.quant, 0..) |*quant, i| {
		if (used & (@as(u4, 1) << @intCast(i)) != 0) continue;
		if (i == 0) return error.GenericError;
		quant.values = output.quant[i - 1].values;
	}
}
pub fn group(dec: *Decoder, meta: *const jxl.codec.ac_metadata.AcMetadata, dc: *const jxl.codec.dc_group.DcGroup, ac: *const jxl.codec.ac_group.Group, rect: jxl.base.rect.Rect) Error!void {
	const output = dec.jpeg_output.?;
	const fh = &dec.frame_header;
	const raw = dec.dequant_matrices.encodings[0].raw.values;
	var offsets: [3]usize = @splat(0);
	for (0..rect.ysize()) |ly| for (0..rect.xsize()) |lx| {
		const bx = rect.x0() + lx;
		const by = rect.y0() + ly;
		const mx = bx % 256;
		const my = by % 256;
		const block = meta.block_map.blocks[my * meta.block_map.width + mx];
		if (block.strategy != 0 or !block.is_first) return error.GenericError;
		const factor_index = (my / 8) * ((meta.block_map.width + 7) / 8) + mx / 8;
		const factors = [3]i32{meta.ytox[factor_index], 0, meta.ytob[factor_index]};
		const y_offset = offsets[1];
		for ([_]usize{0, 2, 1}) |c| {
			const hs: u6 = @intCast(fh.chroma_subsampling.hShift(c));
			const vs: u6 = @intCast(fh.chroma_subsampling.vShift(c));
			const x = bx >> hs;
			const y = by >> vs;
			if (x << hs != bx or y << vs != by) continue;
			const values = ac.planes[c][offsets[c]..][0..64];
			offsets[c] += 64;
			if (output.components.len == 1 and c != 1) continue;
			const component = &output.components[componentIndex(dec, c)];
			if (x >= component.width_blocks or y >= component.height_blocks) return error.GenericError;
			const destination = component.coefficients[(y * component.width_blocks + x) * 64 ..][0..64];
			for (0..64) |i| {
				const transposed = (i % 8) * 8 + i / 8;
				var value = values[transposed];
				if (c != 1 and fh.chroma_subsampling.is444() and factors[c] != 0) {
					const ratio = @divTrunc(factors[c] * cfl_one, 84);
					const quant_ratio = @divTrunc(cfl_one * raw[64 + transposed], raw[64 * c + transposed]);
					const scale = (quant_ratio *% ratio +% cfl_round) >> cfl_precision;
					value +%= (ac.planes[1][y_offset + transposed] *% scale +% cfl_round) >> cfl_precision;
				}
				if (i == 0) {
					const dc_offset = if (fh.color_transform == .none) @divTrunc(@as(i32, 1024), raw[64 * c]) else 0;
					const dc_value = sf.sub(dc.planes[c].samples[y * dc.planes[c].width + x], sf.fromInt(dc_offset));
					value = if (sf.cmp(dc_value, sf.fromInt(-2047)) < 0) -2047 else if (sf.cmp(dc_value, sf.fromInt(2047)) > 0) 2047 else @intCast(sf.toIntTrunc(dc_value));
				}
				if (value < -4095 or value > 4095) return error.GenericError;
				destination[i] = @intCast(value);
			}
		}
	};
}
