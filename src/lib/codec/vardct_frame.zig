//! Decode VarDCT sections in dependency order, then reconstruct XYB pixels.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const BitReader = jxl.base.bit_reader.BitReader;
const ac_global = jxl.codec.ac_global;
const filter = jxl.codec.vardct_filters;

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

const default_biases = [4]sf.Fixed{ sf.parse("0.94534992669284599").?, sf.parse("0.92994550108251407").?, sf.parse("0.950064896662656345").?, sf.parse("0.145").? };
fn adjust(value: i32, c: usize, biases: *const [4]sf.Fixed) sf.Fixed {
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
	if (!fh.chroma_subsampling.is444() and fh.flags & jxl.codec.frame_header.FrameFlags.skip_adaptive_dc_smoothing == 0) return error.GenericError;
	const use_dc = fh.flags & jxl.codec.frame_header.FrameFlags.use_dc_frame != 0;
	if (!dec.force_render and (fh.frame_type == .reference_only or fh.needsBlending(dec.metadata.m.num_extra_channels))) return unsupported(.frame_blending);
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
	for (&full_dc.planes, 0..) |*plane, c| {
		const width = full_dc.width >> @intCast(fh.chroma_subsampling.hShift(c));
		const height = full_dc.height >> @intCast(fh.chroma_subsampling.vShift(c));
		plane.* = .{ .width = width, .height = height, .samples = try dec.allocator.alloc(sf.Fixed, width * height) };
	}
	if (use_dc) {
		if (fh.dc_level >= 4) return error.GenericError;
		const refs = dec.dc_references orelse return error.GenericError;
		const image = refs[fh.dc_level] orelse return error.GenericError;
		if (image.width != full_dc.width or image.height != full_dc.height or image.channels != 3 or image.data.len != 3 * image.width * image.height) return error.GenericError;
		for (full_dc.planes, 0..) |plane, c| @memcpy(plane.samples, image.data[c * image.width * image.height ..][0 .. image.width * image.height]);
	}
	var used_acs: u32 = 0;
	for (dc_sections, 0..) |*slot, id| {
		const br = section(readers, id + 1);
		const rect = dec.frame_dim.dcGroupRect(id);
		var dc = if (use_dc) jxl.codec.dc_group.DcGroup{ .allocator = dec.allocator, .width = rect.xsize(), .height = rect.ysize() } else try dec.decodeVarDctDC(br, id);
		errdefer dc.deinit();
		if (use_dc) {
			dc.buckets = try dec.allocator.alloc(u8, rect.xsize() * rect.ysize());
			@memset(dc.buckets, 0);
		}
		try dec.modular_decoder.decodeGroup(br, id, 0, true);
		const meta = try dec.modular_decoder.decodeAcMetadata(br, id, fh);
		slot.* = .{ .dc = dc, .meta = meta };
		used_acs |= meta.block_map.used_acs;
		if (!use_dc) for (dc.planes, full_dc.planes, 0..) |src, dst, c| for (0..src.height) |y| {
			const x0 = rect.x0() >> @intCast(fh.chroma_subsampling.hShift(c));
			const y0 = rect.y0() >> @intCast(fh.chroma_subsampling.vShift(c));
			@memcpy(dst.samples[(y0 + y) * dst.width + x0 ..][0..src.width], src.samples[y * src.width ..][0..src.width]);
		};
	}
	const global = &dec.vardct_global.?;
	// Smoothing needs neighbors across DC-group boundaries.
	if (!use_dc and fh.flags & jxl.codec.frame_header.FrameFlags.skip_adaptive_dc_smoothing == 0)
		try jxl.codec.dc_smoothing.smooth(dec.allocator, full_dc.planes, global.quantizer.dcSteps(dec.dequant_matrices.dc_quant));
	const ac_global_id = 1 + dec.frame_dim.num_dc_groups;
	const modular = &dec.modular_decoder;
	var acg = try ac_global.Global.decode(dec.allocator, section(readers, ac_global_id), &dec.dequant_matrices, used_acs, dec.frame_dim.num_groups, fh.passes.num_passes, &global.block_context, .{
		.first_stream_id = (jxl.codec.dec_frame.ModularStreamId{ .kind = .quant_table }).id(dec.frame_dim),
		.global = .{
			.tree = if (modular.has_tree) modular.tree.items else null,
			.code = if (modular.has_tree) &modular.code else null,
			.context_map = if (modular.has_tree) modular.context_map else null,
		},
	});
	defer acg.deinit();
	var output = filter.Image{
		.width = dec.frame_dim.xsize,
		.height = dec.frame_dim.ysize,
		.data = try dec.allocator.alloc(sf.Fixed, 3 * dec.frame_dim.xsize * dec.frame_dim.ysize),
	};
	defer dec.allocator.free(output.data);
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
		// Upstream permits unused tail bytes, including empty modular ANS states.
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		try br.close();
	}
	try dec.modular_decoder.finalizeDecoding();
	for (0..3) |c| {
		const hs = fh.chroma_subsampling.hShift(c);
		const vs = fh.chroma_subsampling.vShift(c);
		if (hs == 0 and vs == 0) continue;
		const width = (output.width + hs) >> @intCast(hs);
		const height = (output.height + vs) >> @intCast(vs);
		const plane = output.data[c * output.width * output.height ..][0 .. output.width * output.height];
		const sampled = try @import("chroma.zig").upsample(dec.allocator, .{ .width = width, .height = height, .data = plane[0 .. width * height] }, hs, vs, output.width, output.height);
		defer dec.allocator.free(sampled);
		@memcpy(plane, sampled);
	}
	const params = try filter.Params.fromHeader(fh.loop_filter);
	if (fh.loop_filter.gab) try filter.gaborish(dec.allocator, output, params);
	if (fh.loop_filter.epf_iters != 0) {
		const sigma = try dec.allocator.alloc(sf.Fixed, full_dc.width * full_dc.height);
		defer dec.allocator.free(sigma);
		for (dc_sections, 0..) |*dc_section, id| {
			const rect = dec.frame_dim.dcGroupRect(id);
			const map = &dc_section.*.?.meta.block_map;
			for (map.blocks, 0..) |block, index| {
				if (!block.is_first) continue;
				const bx = index % map.width;
				const by = index / map.width;
				const extent = try jxl.codec.ac_strategy.strategyExtent(block.strategy);
				for (0..extent.y) |dy| for (0..extent.x) |dx| {
					const sharp = map.blocks[(by + dy) * map.width + bx + dx].sharpness;
					sigma[(rect.y0() + by + dy) * full_dc.width + rect.x0() + bx + dx] = try filter.inverseSigma(global.quantizer.scale(), block.quant, params.sharp_lut[sharp], params.quant_mul);
				};
			}
		}
		if (fh.loop_filter.epf_iters == 3) try filter.epf(dec.allocator, output, params, sigma, 0);
		try filter.epf(dec.allocator, output, params, sigma, 1);
		if (fh.loop_filter.epf_iters >= 2) try filter.epf(dec.allocator, output, params, sigma, 2);
	}
	try @import("frame_render.zig").finish(dec, output);
}

fn renderGroup(dec: *jxl.codec.dec_frame.FrameDecoder, meta: *const jxl.codec.ac_metadata.AcMetadata, dc: *const jxl.codec.dc_group.DcGroup, group: *const jxl.codec.ac_group.Group, rect: jxl.base.rect.Rect, output: *filter.Image) !void {
	const fh = &dec.frame_header;
	const global = &dec.vardct_global.?;
	var biases = default_biases;
	const opsin = dec.metadata.transform_data.opsin_inverse_matrix;
	if (opsin.custom) for (opsin.quant_biases, &biases) |value, *dest| {
		dest.* = try jxl.base.float16.loadFloat32Fixed(value);
	};
	var packed_offsets: [3]usize = @splat(0);
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
		@memset(coefficients, sf.Fixed.zero);
		const pixels = try dec.allocator.alloc(sf.Fixed, area);
		defer dec.allocator.free(pixels);
		const factor_index = (my / 8) * ((meta.block_map.width + 7) / 8) + mx / 8;
		const cfl = global.color_correlation.ratios(.{ meta.ytox[factor_index], meta.ytob[factor_index] });
		const scale = try global.quantizer.invQuantAC(block.quant);
		const channel_scale = [3]sf.Fixed{ sf.mul(scale, matrixScale(fh.x_qm_scale)), scale, sf.mul(scale, matrixScale(fh.b_qm_scale)) };
		for (0..3) |c| {
			const hs: u6 = @intCast(fh.chroma_subsampling.hShift(c));
			const vs: u6 = @intCast(fh.chroma_subsampling.vShift(c));
			if ((bx >> hs) << hs != bx or (by >> vs) << vs != by) continue;
			const matrix = dec.dequant_matrices.matrix(@enumFromInt(block.strategy), c);
			for (0..area) |i| coefficients[c * area + i] = sf.mul(adjust(group.planes[c][packed_offsets[c] + i], c, &biases), sf.mul(matrix[i], channel_scale[c]));
			packed_offsets[c] += area;
		}
		for (0..area) |i| {
			coefficients[i] = sf.add(coefficients[i], sf.mul(cfl[0], coefficients[area + i]));
			coefficients[2 * area + i] = sf.add(coefficients[2 * area + i], sf.mul(cfl[1], coefficients[area + i]));
		}
		for (0..3) |c| {
			const hs: u6 = @intCast(fh.chroma_subsampling.hShift(c));
			const vs: u6 = @intCast(fh.chroma_subsampling.vShift(c));
			const sbx = bx >> hs;
			const sby = by >> vs;
			if (sbx << hs != bx or sby << vs != by) continue;
			const coeff = coefficients[c * area ..][0..area];
			try jxl.codec.inverse_transform.lowestFrequencies(dec.allocator, block.strategy, dc.planes[c].samples[sby * dc.planes[c].width + sbx ..], dc.planes[c].width, coeff);
			try jxl.codec.inverse_transform.transform(dec.allocator, block.strategy, coeff, pixels, width);
			const plane_width = (output.width + fh.chroma_subsampling.hShift(c)) >> hs;
			const plane_height = (output.height + fh.chroma_subsampling.vShift(c)) >> vs;
			if (sbx * 8 >= plane_width or sby * 8 >= plane_height) continue;
			const copy_width = @min(width, plane_width - sbx * 8);
			const copy_height = @min(height, plane_height - sby * 8);
			for (0..copy_height) |y| for (0..copy_width) |x| {
				output.data[c * output.width * output.height + (sby * 8 + y) * plane_width + sbx * 8 + x] = pixels[y * width + x];
			};
		}
	};
}
