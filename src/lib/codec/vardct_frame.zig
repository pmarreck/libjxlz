//! Decode VarDCT sections in dependency order, then reconstruct XYB pixels.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const BitReader = jxl.base.bit_reader.BitReader;
const ac_global = jxl.codec.ac_global;

fn section(readers: []BitReader, id: usize) *BitReader {
	// One-group, one-pass frames share a single reader for every section.
	return &readers[if (readers.len == 1) 0 else id];
}
const DcSection = struct {
	dc: jxl.codec.dc_group.DcGroup,
	meta: jxl.codec.ac_metadata.AcMetadata,
	fn deinit(self: *DcSection) void {
		self.dc.deinit();
		self.meta.deinit();
	}
};

fn adjust(value: i32, c: usize) sf.Fixed {
	const biases = [4]sf.Fixed{ sf.parse("0.94534992669284599").?, sf.parse("0.92994550108251407").?, sf.parse("0.950064896662656345").?, sf.parse("0.145").? };
	return switch (value) {
		0 => sf.Fixed.zero,
		1 => biases[c],
		-1 => sf.neg(biases[c]),
		else => sf.sub(sf.fromInt(value), sf.div(biases[3], sf.fromInt(value))),
	};
}
fn matrixScale(scale: u32) sf.Fixed {
	var value = sf.fromInt(1);
	const exponent: i32 = @as(i32, @intCast(scale)) - 2;
	for (0..@abs(exponent)) |_| value = sf.mul(value, if (exponent < 0) sf.div(sf.fromInt(5), sf.fromInt(4)) else sf.div(sf.fromInt(4), sf.fromInt(5)));
	return value;
}
pub fn decode(dec: *jxl.codec.dec_frame.FrameDecoder, data: []const u8, offset: usize) !void {
	const fh = &dec.frame_header;
	const unsupported = @import("../base/unsupported.zig").unsupported;
	if (fh.encoding != .var_dct) return error.GenericError;
	if (!fh.chroma_subsampling.is444()) return unsupported(.chroma_subsampling);
	if (fh.loop_filter.gab or fh.loop_filter.epf_iters != 0) return unsupported(.vardct_frame);
	if (dec.metadata.m.num_extra_channels != 0) return unsupported(.extra_channel_type);
	if (fh.flags & jxl.codec.frame_header.FrameFlags.use_dc_frame != 0) return unsupported(.progressive_dc_frame);
	if (fh.upsampling != 1) return unsupported(.upsampling);
	if (fh.frame_type == .dc_frame) return unsupported(.progressive_dc_frame);
	if (fh.frame_type == .reference_only) return unsupported(.reference_frame);
	if (fh.blending_info.mode != .replace or fh.custom_size_or_origin) return unsupported(.frame_blending);
	if (fh.color_transform != .xyb) return unsupported(.color_encoding);
	if (fh.flags & jxl.codec.frame_header.FrameFlags.splines != 0) return unsupported(.splines);
	if (dec.metadata.m.color_encoding.want_icc) return unsupported(.icc_profile);
	if (dec.metadata.transform_data.opsin_inverse_matrix.custom) return unsupported(.color_encoding);
	for (dec.metadata.transform_data.opsin_inverse_matrix.inverse_matrix) |row| for (row) |value| {
		if (@as(u32, @bitCast(value)) != 0) return unsupported(.color_encoding);
	};
	const readers = try dec.allocator.alloc(BitReader, dec.toc_entries.len);
	defer dec.allocator.free(readers);
	var physical = offset;
	for (dec.toc_entries) |entry| {
		if (physical > data.len or entry.size > data.len - physical) return error.NotEnoughBytes;
		if (entry.id >= readers.len) return error.GenericError;
		readers[entry.id] = BitReader.init(data[physical..][0..entry.size]);
		physical += entry.size;
	}
	try dec.processDCGlobal(section(readers, 0));
	const dc_sections = try dec.allocator.alloc(?DcSection, dec.frame_dim.num_dc_groups);
	defer dec.allocator.free(dc_sections);
	@memset(dc_sections, null);
	defer for (dc_sections) |*item| {
		if (item.*) |*value| value.deinit();
	};
	var full_dc = jxl.codec.dc_group.DcGroup{ .allocator = dec.allocator, .width = dec.frame_dim.xsize_blocks, .height = dec.frame_dim.ysize_blocks };
	defer full_dc.deinit();
	for (&full_dc.planes) |*plane| {
		plane.* = .{ .width = full_dc.width, .height = full_dc.height, .samples = try dec.allocator.alloc(sf.Fixed, full_dc.width * full_dc.height) };
	}
	var used_acs: u32 = 0;
	for (dc_sections, 0..) |*slot, id| {
		const br = section(readers, id + 1);
		var dc = try dec.decodeVarDctDC(br, id);
		errdefer dc.deinit();
		try dec.modular_decoder.decodeGroup(br, id, 0, true);
		const meta = try dec.modular_decoder.decodeAcMetadata(br, id, fh);
		slot.* = .{ .dc = dc, .meta = meta };
		used_acs |= meta.block_map.used_acs;
		const rect = dec.frame_dim.dcGroupRect(id);
		for (dc.planes, full_dc.planes) |src, dst| for (0..rect.ysize()) |y| {
			@memcpy(dst.samples[(rect.y0() + y) * full_dc.width + rect.x0() ..][0..rect.xsize()], src.samples[y * src.width ..][0..rect.xsize()]);
		};
	}
	const global = &dec.vardct_global.?;
	// Smoothing needs neighbors across DC-group boundaries.
	if (fh.flags & jxl.codec.frame_header.FrameFlags.skip_adaptive_dc_smoothing == 0)
		try jxl.codec.dc_smoothing.smooth(dec.allocator, full_dc.planes, global.quantizer.dcSteps(dec.dequant_matrices.dc_quant));
	const ac_global_id = 1 + dec.frame_dim.num_dc_groups;
	var acg = try ac_global.Global.decode(dec.allocator, section(readers, ac_global_id), &dec.dequant_matrices, used_acs, dec.frame_dim.num_groups, fh.passes.num_passes, &global.block_context);
	defer acg.deinit();
	var output = try jxl.codec.render.FloatImage.init(dec.allocator, dec.frame_dim.xsize, dec.frame_dim.ysize, 3);
	errdefer output.deinit();
	for (0..dec.frame_dim.num_groups) |id| {
		const rect = dec.frame_dim.blockGroupRect(id);
		const dc_id = (rect.y0() / 256) * dec.frame_dim.xsize_dc_groups + rect.x0() / 256;
		const dc_section = &dc_sections[dc_id].?;
		const local_x = rect.x0() % 256;
		const local_y = rect.y0() % 256;
		var group = try jxl.codec.ac_group.Group.create(dec.allocator, rect.xsize(), rect.ysize(), fh.chroma_subsampling);
		defer group.deinit();
		for (acg.passes, 0..) |*pass, pid| {
			const br = section(readers, ac_global_id + 1 + pid * dec.frame_dim.num_groups + id);
			try group.decodeEntropyPass(dec.allocator, .{ .map = &dc_section.meta.block_map, .dc = dc_section.dc.buckets, .orders = &pass.orders, .context = &global.block_context, .x = local_x, .y = local_y, .shift = @intCast(fh.passes.shift[pid]) }, br, &pass.code, pass.contexts, acg.num_histograms);
			try dec.modular_decoder.decodeGroup(br, id, pid, false);
		}
		try renderGroup(dec, &dc_section.meta, &full_dc, &group, rect, &output);
	}
	for (dec.toc_entries) |entry| {
		const br = &readers[entry.id];
		try br.jumpToByteBoundary();
		if (br.totalBitsConsumed() != entry.size * 8) return error.GenericError;
		try br.close();
	}
	try dec.modular_decoder.finalizeDecoding();
	dec.rendered_image = output;
}

fn renderGroup(dec: *jxl.codec.dec_frame.FrameDecoder, meta: *const jxl.codec.ac_metadata.AcMetadata, dc: *const jxl.codec.dc_group.DcGroup, group: *const jxl.codec.ac_group.Group, rect: jxl.base.rect.Rect, output: *jxl.codec.render.FloatImage) !void {
	const fh = &dec.frame_header;
	const global = &dec.vardct_global.?;
	var packed_offset: usize = 0;
	for (0..rect.ysize()) |local_y| for (0..rect.xsize()) |local_x| {
		const bx = rect.x0() + local_x;
		const by = rect.y0() + local_y;
		const mx = bx % 256;
		const my = by % 256;
		const block = meta.block_map.blocks[my * meta.block_map.width + mx];
		if (!block.is_first) continue;
		const extent = try jxl.codec.ac_strategy.strategyExtent(block.strategy);
		const width = extent.x * 8;
		const height = extent.y * 8;
		const area = width * height;
		const coefficients = try dec.allocator.alloc(sf.Fixed, 3 * area);
		defer dec.allocator.free(coefficients);
		const pixels = try dec.allocator.alloc(sf.Fixed, area);
		defer dec.allocator.free(pixels);
		const factor_index = (my / 8) * ((meta.block_map.width + 7) / 8) + mx / 8;
		const cfl = global.color_correlation.ratios(.{ meta.ytox[factor_index], meta.ytob[factor_index] });
		const scale = try global.quantizer.invQuantAC(block.quant);
		const channel_scale = [3]sf.Fixed{ sf.mul(scale, matrixScale(fh.x_qm_scale)), scale, sf.mul(scale, matrixScale(fh.b_qm_scale)) };
		for (0..3) |c| {
			const matrix = dec.dequant_matrices.matrix(@enumFromInt(block.strategy), c);
			for (0..area) |i| coefficients[c * area + i] = sf.mul(adjust(group.planes[c][packed_offset + i], c), sf.mul(matrix[i], channel_scale[c]));
		}
		for (0..area) |i| {
			coefficients[i] = sf.add(coefficients[i], sf.mul(cfl[0], coefficients[area + i]));
			coefficients[2 * area + i] = sf.add(coefficients[2 * area + i], sf.mul(cfl[1], coefficients[area + i]));
		}
		for (0..3) |c| {
			const coeff = coefficients[c * area ..][0..area];
			try jxl.codec.inverse_transform.lowestFrequencies(dec.allocator, block.strategy, dc.planes[c].samples[by * dc.width + bx ..], dc.width, coeff);
			try jxl.codec.inverse_transform.transform(dec.allocator, block.strategy, coeff, pixels, width);
			const copy_width = @min(width, output.xsize - bx * 8);
			const copy_height = @min(height, output.ysize - by * 8);
			for (0..copy_height) |y| for (0..copy_width) |x| {
				// Convert to IEEE-754 only at the XYB display boundary.
				const value = pixels[y * width + x];
				output.row(by * 8 + y, c)[bx * 8 + x] = std.math.ldexp(@as(f32, @floatFromInt(value.m)), value.e - 62);
			};
		}
		packed_offset += area;
	};
}
