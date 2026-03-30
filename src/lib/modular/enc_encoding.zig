// Minimal modular encoder tokenization helpers.
// Starts with the smallest grayscale slice: single-node predictor tokenization.

const std = @import("std");
const bits = @import("../base/bits.zig");
const common = @import("../base/common.zig");
const pack_signed = @import("../base/pack_signed.zig");
const fc = @import("../codec/field_coders.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const context_predict = @import("context_predict.zig");
const dec_ma = @import("dec_ma.zig");
const enc_ma = @import("enc_ma.zig");
const modular_image = @import("modular_image.zig");
const options = @import("options.zig");
const transform_mod = @import("transform.zig");
const weighted = @import("weighted.zig");
const Rect = @import("../base/rect.zig").Rect;

const Channel = modular_image.Channel;
const Predictor = options.Predictor;
const TreeKind = options.TreeKind;
const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;
const Token = enc_ans.Token;
const SqueezeParams = transform_mod.SqueezeParams;
const Transform = transform_mod.Transform;

const LocalHistogramConfig = struct {
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	alphabet_size: u32,
};

const FixedTreeNodeInfo = struct {
	begin: usize,
	end: usize,
	pos: usize,
};

/// Builds the fixed split tree upstream uses for DC contexts by breadth-first
/// partitioning sorted cutoffs, while shortening the tree for tiny images.
fn makeFixedTree(
	allocator: std.mem.Allocator,
	property: i16,
	cutoffs: []const i32,
	pred: Predictor,
	num_pixels: usize,
	bitdepth: i32,
) !dec_ma.Tree {
	if (num_pixels == 0) return error.GenericError;

	var tree: dec_ma.Tree = .{};
	errdefer tree.deinit(allocator);
	try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(pred, 0, 1));

	const log_px = bits.ceilLog2Nonzero(num_pixels);
	var min_gap: usize = 0;
	if (log_px < 14) min_gap = 8 * (14 - log_px);
	const shift: i32 = if (bitdepth > 11) @min(@as(i32, 4), bitdepth - 11) else 0;
	const mul: i32 = @as(i32, 1) << @intCast(shift);

	var queue: std.ArrayList(FixedTreeNodeInfo) = .{};
	defer queue.deinit(allocator);
	try queue.append(allocator, .{ .begin = 0, .end = cutoffs.len, .pos = 0 });
	var queue_head: usize = 0;

	while (queue_head < queue.items.len) {
		const info = queue.items[queue_head];
		queue_head += 1;
		if (info.begin + min_gap >= info.end) continue;

		const split = (info.begin + info.end) / 2;
		const cutoff = cutoffs[split] * mul;
		tree.items[info.pos] = dec_ma.PropertyDecisionNode.split(property, cutoff, @intCast(tree.items.len), 0);

		try queue.append(allocator, .{ .begin = split + 1, .end = info.end, .pos = tree.items.len });
		try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(pred, 0, 1));
		try queue.append(allocator, .{ .begin = info.begin, .end = split, .pos = tree.items.len });
		try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(pred, 0, 1));
	}

	return tree;
}

/// Mirrors upstream `PredefinedTree` so the encoder can select the same
/// hard-coded tree families before we port learned-tree construction.
pub fn predefinedTree(
	allocator: std.mem.Allocator,
	tree_kind: TreeKind,
	total_pixels: usize,
	bitdepth: i32,
	prevprop: i32,
) !dec_ma.Tree {
	switch (tree_kind) {
		.jpeg_transcode_ac_meta, .trivial_tree_no_predictor => {
			var tree: dec_ma.Tree = .{};
			errdefer tree.deinit(allocator);
			try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1));
			return tree;
		},
		.falcon_ac_meta => {
			var tree: dec_ma.Tree = .{};
			errdefer tree.deinit(allocator);
			try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(.left, 0, 1));
			return tree;
		},
		.ac_meta => {
			if (total_pixels < 1024) {
				var tree: dec_ma.Tree = .{};
				errdefer tree.deinit(allocator);
				try tree.append(allocator, dec_ma.PropertyDecisionNode.leaf(.left, 0, 1));
				return tree;
			}

			var tree: dec_ma.Tree = .{};
			errdefer tree.deinit(allocator);
			try tree.appendSlice(allocator, &.{
				dec_ma.PropertyDecisionNode.split(0, 1, 1, 0),
				dec_ma.PropertyDecisionNode.split(0, 2, 3, 0),
				dec_ma.PropertyDecisionNode.split(0, 0, 5, 0),
				dec_ma.PropertyDecisionNode.split(6, 3, 21, 0),
				dec_ma.PropertyDecisionNode.split(2, 0, 7, 0),
				dec_ma.PropertyDecisionNode.leaf(.gradient, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.gradient, 0, 1),
				dec_ma.PropertyDecisionNode.split(7, 5, 9, 0),
				dec_ma.PropertyDecisionNode.split(7, 5, 15, 0),
				dec_ma.PropertyDecisionNode.split(7, 11, 11, 0),
				dec_ma.PropertyDecisionNode.split(7, 3, 13, 0),
				dec_ma.PropertyDecisionNode.leaf(.left, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.left, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.left, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.left, 0, 1),
				dec_ma.PropertyDecisionNode.split(7, 11, 17, 0),
				dec_ma.PropertyDecisionNode.split(7, 3, 19, 0),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.split(7, 3, 23, 0),
				dec_ma.PropertyDecisionNode.split(7, 3, 25, 0),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
				dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1),
			});
			return tree;
		},
		.wp_fixed_dc => {
			const cutoffs = [_]i32{
				-500, -392, -255, -191, -127, -95, -63, -47, -31, -23, -15,
				-11, -7, -4, -3, -1, 0, 1, 3, 5, 7, 11,
				15, 23, 31, 47, 63, 95, 127, 191, 255, 392, 500,
			};
			return makeFixedTree(allocator, @intCast(context_predict.kWPProp), &cutoffs, .weighted, total_pixels, bitdepth);
		},
		.gradient_fixed_dc => {
			const cutoffs = [_]i32{
				-500, -392, -255, -191, -127, -95, -63, -47, -31, -23, -15,
				-11, -7, -4, -3, -1, 0, 1, 3, 5, 7, 11,
				15, 23, 31, 47, 63, 95, 127, 191, 255, 392, 500,
			};
			const property: i16 = @intCast(if (prevprop > 0) context_predict.kNumNonrefProperties + 2 else context_predict.kGradientProp);
			return makeFixedTree(allocator, property, &cutoffs, .gradient, total_pixels, bitdepth);
		},
		.learn => return error.Unsupported,
	}
}

test "makeFixedTree collapses tiny images to a single predictor leaf" {
	const allocator = testing.allocator;
	const cutoffs = [_]i32{ -1, 0, 1 };
	var tree = try makeFixedTree(allocator, 7, &cutoffs, .weighted, 1, 8);
	defer tree.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), tree.items.len);
	try testing.expectEqual(@as(i16, -1), tree.items[0].property);
	try testing.expectEqual(Predictor.weighted, tree.items[0].predictor);
}

test "makeFixedTree scales split cutoffs for high bitdepth" {
	const allocator = testing.allocator;
	const cutoffs = [_]i32{1};
	var tree = try makeFixedTree(allocator, 11, &cutoffs, .gradient, 1 << 20, 13);
	defer tree.deinit(allocator);

	try testing.expectEqual(@as(usize, 3), tree.items.len);
	try testing.expectEqual(@as(i16, 11), tree.items[0].property);
	try testing.expectEqual(@as(i32, 4), tree.items[0].splitval);
	try testing.expectEqual(@as(u32, 1), tree.items[0].lchild);
	try testing.expectEqual(@as(u32, 2), tree.items[0].rchild);
	try testing.expectEqual(Predictor.gradient, tree.items[1].predictor);
	try testing.expectEqual(Predictor.gradient, tree.items[2].predictor);
}

test "predefinedTree uses trivial zero leaf for the trivial tree kind" {
	const allocator = testing.allocator;
	var tree = try predefinedTree(allocator, .trivial_tree_no_predictor, 4096, 8, 0);
	defer tree.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), tree.items.len);
	try testing.expectEqual(@as(i16, -1), tree.items[0].property);
	try testing.expectEqual(Predictor.zero, tree.items[0].predictor);
}

test "predefinedTree gradient fixed dc switches property when previous channels exist" {
	const allocator = testing.allocator;

	var no_prev = try predefinedTree(allocator, .gradient_fixed_dc, 1 << 20, 8, 0);
	defer no_prev.deinit(allocator);
	try testing.expect(no_prev.items.len > 1);
	try testing.expectEqual(@as(i16, @intCast(context_predict.kGradientProp)), no_prev.items[0].property);
	try testing.expectEqual(@as(i32, 0), no_prev.items[0].splitval);

	var with_prev = try predefinedTree(allocator, .gradient_fixed_dc, 1 << 20, 8, 1);
	defer with_prev.deinit(allocator);
	try testing.expect(with_prev.items.len > 1);
	try testing.expectEqual(@as(i16, @intCast(context_predict.kNumNonrefProperties + 2)), with_prev.items[0].property);
	try testing.expectEqual(@as(i32, 0), with_prev.items[0].splitval);
}

test "predefinedTree keeps the large AC metadata layout" {
	const allocator = testing.allocator;
	var tree = try predefinedTree(allocator, .ac_meta, 4096, 8, 0);
	defer tree.deinit(allocator);

	try testing.expectEqual(@as(usize, 27), tree.items.len);
	try testing.expectEqual(@as(i16, 0), tree.items[0].property);
	try testing.expectEqual(@as(i32, 1), tree.items[0].splitval);
	try testing.expectEqual(@as(i16, 6), tree.items[3].property);
	try testing.expectEqual(@as(i32, 3), tree.items[3].splitval);
	try testing.expectEqual(Predictor.gradient, tree.items[5].predictor);
	try testing.expectEqual(Predictor.left, tree.items[11].predictor);
	try testing.expectEqual(Predictor.zero, tree.items[23].predictor);
}

const FlatHistogramInfoKey = struct {
	alphabet_size: u32,
	log_alpha_size: u5,
	split_exponent: u32,
	msb_in_token: u32,
	lsb_in_token: u32,
};

/// Caches the flat ANS info tables used by the narrow modular encoder path.
/// The key is the histogram shape plus HybridUintConfig, which is enough to reuse
/// the reverse maps across repeated tiles with the same token alphabet.
pub const FlatHistogramInfoCache = struct {
	allocator: std.mem.Allocator,
	entries: std.ArrayListUnmanaged(Entry) = .{},

	const Entry = struct {
		key: FlatHistogramInfoKey,
		info: []enc_ans.ANSEncSymbolInfo,
	};

	pub fn init(allocator: std.mem.Allocator) FlatHistogramInfoCache {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *FlatHistogramInfoCache) void {
		for (self.entries.items) |entry| {
			enc_ans.freeANSEncSymbolInfoTable(self.allocator, entry.info);
		}
		self.entries.deinit(self.allocator);
	}

	fn getOrCreate(self: *FlatHistogramInfoCache, cfg: LocalHistogramConfig) ![]const enc_ans.ANSEncSymbolInfo {
		const key = FlatHistogramInfoKey{
			.alphabet_size = cfg.alphabet_size,
			.log_alpha_size = cfg.log_alpha_size,
			.split_exponent = cfg.uint_config.split_exponent,
			.msb_in_token = cfg.uint_config.msb_in_token,
			.lsb_in_token = cfg.uint_config.lsb_in_token,
		};
		for (self.entries.items) |entry| {
			if (std.meta.eql(entry.key, key)) return entry.info;
		}

		const counts = try ans_common.createFlatHistogram(self.allocator, cfg.alphabet_size, ans_params.ans_tab_size);
		defer self.allocator.free(counts);
		const info = try enc_ans.buildANSEncSymbolInfoTable(self.allocator, counts, cfg.log_alpha_size);
		errdefer enc_ans.freeANSEncSymbolInfoTable(self.allocator, info);
		try self.entries.append(self.allocator, .{
			.key = key,
			.info = info,
		});
		return info;
	}
};

/// Emits just the modular group header for a stream whose channels are all
/// larger than `max_chan_size`, so decode returns after parsing the header.
pub fn writeEmptyModularGroup(writer: *BitWriter) !void {
	try writer.write(1, 0); // use_global_tree = false
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
}

fn writeSingleRCTTransform(begin_c: u32, rct_type: u32, writer: *BitWriter) !void {
	if (rct_type >= 42) return error.GenericError;

	try writer.write(2, 0); // TransformId.rct

	const bc_enc = fc.U32Enc.init(fc.bits(3), fc.bitsOffset(6, 8), fc.bitsOffset(10, 72), fc.bitsOffset(13, 1096));
	try fc.U32Coder.write(bc_enc, begin_c, writer);

	const rt_enc = fc.U32Enc.init(fc.val(6), fc.bits(2), fc.bitsOffset(4, 2), fc.bitsOffset(6, 10));
	try fc.U32Coder.write(rt_enc, rct_type, writer);
}

/// Serializes one squeeze parameter block exactly as `Transform.readFromBitStream`
/// expects, so encoder-authored squeeze metadata reuses the existing decoder path.
fn writeSingleSqueezeParam(param: SqueezeParams, writer: *BitWriter) !void {
	if (param.num_c == 0) return error.GenericError;

	try writer.write(1, @intFromBool(param.horizontal));
	try writer.write(1, @intFromBool(param.in_place));

	const bc_enc = fc.U32Enc.init(fc.bits(3), fc.bitsOffset(6, 8), fc.bitsOffset(10, 72), fc.bitsOffset(13, 1096));
	try fc.U32Coder.write(bc_enc, param.begin_c, writer);

	const nc_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.bitsOffset(4, 4));
	try fc.U32Coder.write(nc_enc, param.num_c, writer);
}

/// Emits the narrow modular squeeze transform header: one transform containing
/// an explicit squeeze parameter list for the decoder to meta-apply before ANS decode.
fn writeSingleSqueezeTransform(squeezes: []const SqueezeParams, writer: *BitWriter) !void {
	if (squeezes.len == 0) return error.GenericError;

	try writer.write(2, 2); // TransformId.squeeze

	const ns_enc = fc.U32Enc.init(fc.val(0), fc.bitsOffset(4, 1), fc.bitsOffset(6, 9), fc.bitsOffset(8, 41));
	try fc.U32Coder.write(ns_enc, @intCast(squeezes.len), writer);

	for (squeezes) |param| {
		try writeSingleSqueezeParam(param, writer);
	}
}

/// Serializes one narrow palette transform block so encoder-authored palette
/// streams can reuse the existing decoder-side `Transform.readFromBitStream`.
fn writeSinglePaletteTransform(palette: Transform, writer: *BitWriter) !void {
	if (palette.id != .palette) return error.GenericError;
	if (palette.num_c == 0) return error.GenericError;
	if (@intFromEnum(palette.predictor) >= @intFromEnum(Predictor.best)) return error.GenericError;

	try writer.write(2, 1); // TransformId.palette

	const bc_enc = fc.U32Enc.init(fc.bits(3), fc.bitsOffset(6, 8), fc.bitsOffset(10, 72), fc.bitsOffset(13, 1096));
	try fc.U32Coder.write(bc_enc, palette.begin_c, writer);

	const nc_enc = fc.U32Enc.init(fc.val(1), fc.val(3), fc.val(4), fc.bitsOffset(13, 1));
	try fc.U32Coder.write(nc_enc, palette.num_c, writer);

	const nbc_enc = fc.U32Enc.init(fc.bitsOffset(8, 0), fc.bitsOffset(10, 256), fc.bitsOffset(12, 1280), fc.bitsOffset(16, 5376));
	try fc.U32Coder.write(nbc_enc, palette.nb_colors, writer);

	const nbd_enc = fc.U32Enc.init(fc.val(0), fc.bitsOffset(8, 1), fc.bitsOffset(10, 257), fc.bitsOffset(16, 1281));
	try fc.U32Coder.write(nbd_enc, palette.nb_deltas, writer);

	try writer.write(4, @intFromEnum(palette.predictor));
}

pub fn writeEmptyModularGroupWithRCT(begin_c: u32, rct_type: u32, writer: *BitWriter) !void {
	try writer.write(1, 0); // use_global_tree = false
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 1); // num_transforms = 1 via selector 1
	try writeSingleRCTTransform(begin_c, rct_type, writer);
}

/// Emits an otherwise-empty modular group header with one explicit squeeze transform.
pub fn writeEmptyModularGroupWithSqueeze(squeezes: []const SqueezeParams, writer: *BitWriter) !void {
	try writer.write(1, 0); // use_global_tree = false
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 1); // num_transforms = 1 via selector 1
	try writeSingleSqueezeTransform(squeezes, writer);
}

/// Emits an otherwise-empty modular group header with one explicit palette transform.
pub fn writeEmptyModularGroupWithPalette(palette: Transform, writer: *BitWriter) !void {
	try writer.write(1, 0); // use_global_tree = false
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 1); // num_transforms = 1 via selector 1
	try writeSinglePaletteTransform(palette, writer);
}

fn subsampledSize(size: usize, shift: i32) usize {
	if (shift < 0) return size;
	return common.divCeil(size, @as(usize, 1) << @intCast(shift));
}

/// Copies a group-sized source rect into a standalone temporary image so the
/// existing local single-node writer can be reused for multigroup frame tiles.
fn extractImageRect(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
) !modular_image.Image {
	var tile = modular_image.Image{
		.channels = .{},
		.transforms = .{},
		.w = rect.xsize(),
		.h = rect.ysize(),
		.bitdepth = image.bitdepth,
		.nb_meta_channels = image.nb_meta_channels,
		.allocator = allocator,
	};
	errdefer tile.deinit();

	for (image.channels.items) |source_ch| {
		if (source_ch.hshift < 0 or source_ch.vshift < 0) return error.Unsupported;

		const shift_x: u6 = @intCast(source_ch.hshift);
		const shift_y: u6 = @intCast(source_ch.vshift);
		const align_x = (@as(usize, 1) << shift_x) - 1;
		const align_y = (@as(usize, 1) << shift_y) - 1;
		if ((rect.x0() & align_x) != 0 or (rect.y0() & align_y) != 0) return error.Unsupported;

		const rx0 = rect.x0() >> shift_x;
		const ry0 = rect.y0() >> shift_y;
		const rw = subsampledSize(rect.xsize(), source_ch.hshift);
		const rh = subsampledSize(rect.ysize(), source_ch.vshift);
		var tile_ch = try Channel.create(allocator, rw, rh, source_ch.hshift, source_ch.vshift);
		errdefer tile_ch.deinit();

		for (0..rh) |y| {
			@memcpy(
				tile_ch.row(y),
				source_ch.rowConst(ry0 + y)[rx0 .. rx0 + rw],
			);
		}
		try tile.channels.append(allocator, tile_ch);
	}

	return tile;
}

fn tokenizeSingleNodeChannelRect(
	allocator: std.mem.Allocator,
	channel: *const Channel,
	rect: Rect,
	predictor: Predictor,
	ctx_id: u32,
) ![]Token {
	if (predictor == .weighted or predictor == .best or predictor == .variable) {
		return error.GenericError;
	}
	if (channel.hshift < 0 or channel.vshift < 0) return error.Unsupported;

	const shift_x: u6 = @intCast(channel.hshift);
	const shift_y: u6 = @intCast(channel.vshift);
	const align_x = (@as(usize, 1) << shift_x) - 1;
	const align_y = (@as(usize, 1) << shift_y) - 1;
	if ((rect.x0() & align_x) != 0 or (rect.y0() & align_y) != 0) return error.Unsupported;

	const rx0 = rect.x0() >> shift_x;
	const ry0 = rect.y0() >> shift_y;
	const rw = subsampledSize(rect.xsize(), channel.hshift);
	const rh = subsampledSize(rect.ysize(), channel.vshift);
	const tokens = try allocator.alloc(Token, rw * rh);
	var token_index: usize = 0;

	for (0..rh) |y| {
		const global_y = ry0 + y;
		const row = channel.rowConst(global_y);
		const has_top = y > 0;
		const has_toptop = y > 1;
		const top_row = if (has_top) channel.rowConst(global_y - 1) else &[_]i32{};
		const top2_row = if (has_toptop) channel.rowConst(global_y - 2) else &[_]i32{};

		for (0..rw) |x| {
			const global_x = rx0 + x;
			const left: pixel_type_w = if (x > 0) row[global_x - 1] else if (has_top) top_row[global_x] else 0;
			const top: pixel_type_w = if (has_top) top_row[global_x] else left;
			const topleft: pixel_type_w = if (x > 0 and has_top) top_row[global_x - 1] else left;
			const topright: pixel_type_w = if (x + 1 < rw and has_top) top_row[global_x + 1] else top;
			const leftleft: pixel_type_w = if (x > 1) row[global_x - 2] else left;
			const toptop: pixel_type_w = if (has_toptop) top2_row[global_x] else top;
			const toprightright: pixel_type_w = if (x + 2 < rw and has_top) top_row[global_x + 2] else topright;
			const guess = context_predict.predictOne(
				predictor,
				left,
				top,
				toptop,
				topleft,
				topright,
				leftleft,
				toprightright,
				0,
			);
			const residual: i32 = @intCast(@as(pixel_type_w, row[global_x]) - guess);
			tokens[token_index] = Token.init(ctx_id, pack_signed.packSigned(residual));
			token_index += 1;
		}
	}

	return tokens;
}

inline fn absPixel(v: pixel_type_w) pixel_type {
	return @intCast(if (v >= 0) v else -v);
}

/// Computes rect-local previous-channel properties for MA-tree lookup, matching
/// decoder semantics by ignoring pixels above or left of the current group tile.
fn precomputeReferencesRect(
	channel: *const Channel,
	rect: Rect,
	y: usize,
	image: *const modular_image.Image,
	chan: usize,
	property_use: *const context_predict.PropertyUsePlan,
	references: *Channel,
) void {
	const reference_props = property_use.referenceProps();
	if (reference_props.len == 0) return;

	for (0..references.h) |x| {
		const rp = references.row(x);
		for (reference_props) |property_index_u8| {
			rp[@as(usize, property_index_u8) - context_predict.kNumNonrefProperties] = 0;
		}
	}

	const shift_x: u6 = @intCast(channel.hshift);
	const shift_y: u6 = @intCast(channel.vshift);
	const rx0 = rect.x0() >> shift_x;
	const ry0 = rect.y0() >> shift_y;
	const rw = subsampledSize(rect.xsize(), channel.hshift);

	var offset: usize = 0;
	const num_extra_props = references.w;
	var j: isize = @intCast(chan);
	while (j > 0 and offset < num_extra_props) {
		j -= 1;
		const ref_chan = &image.channels.items[@intCast(j)];
		if (ref_chan.w != channel.w or ref_chan.h != channel.h) continue;
		if (ref_chan.hshift != channel.hshift or ref_chan.vshift != channel.vshift) continue;

		const base_property = context_predict.kNumNonrefProperties + offset;
		const use_abs_value = property_use.uses(base_property);
		const use_value = property_use.uses(base_property + 1);
		const use_abs_diff = property_use.uses(base_property + 2);
		const use_diff = property_use.uses(base_property + 3);
		if (!use_abs_value and !use_value and !use_abs_diff and !use_diff) {
			offset += context_predict.kExtraPropsPerChannel;
			continue;
		}

		const row = ref_chan.rowConst(ry0 + y);
		const prev_row = ref_chan.rowConst(if (y > 0) ry0 + y - 1 else ry0 + y);
		for (0..rw) |x| {
			const global_x = rx0 + x;
			const rp = references.row(x);
			const value: pixel_type_w = row[global_x];
			if (use_abs_value) rp[offset + 0] = absPixel(value);
			if (use_value) rp[offset + 1] = @intCast(value);

			if (use_abs_diff or use_diff) {
				const left: pixel_type_w = if (x > 0) row[global_x - 1] else 0;
				const top: pixel_type_w = if (y > 0) prev_row[global_x] else left;
				const topleft: pixel_type_w = if (x > 0 and y > 0) prev_row[global_x - 1] else left;
				const predicted = context_predict.clampedGradient(
					@as(pixel_type, @intCast(left)),
					@as(pixel_type, @intCast(top)),
					@as(pixel_type, @intCast(topleft)),
				);
				const diff: pixel_type_w = value - predicted;
				if (use_abs_diff) rp[offset + 2] = absPixel(diff);
				if (use_diff) rp[offset + 3] = @intCast(diff);
			}
		}

		offset += context_predict.kExtraPropsPerChannel;
	}
}

/// Shared MA-tree tokenizer for one channel rect. It mirrors the upstream
/// per-pixel encoder loop and can opt into weighted state and/or previous-
/// channel properties as each compatibility slice is implemented.
fn tokenizeGlobalTreeChannelRectImpl(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	chan: usize,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	rect: Rect,
	comptime allow_wp: bool,
	comptime allow_refs: bool,
) ![]Token {
	const channel = &image.channels.items[chan];
	if (channel.hshift < 0 or channel.vshift < 0) return error.Unsupported;

	const static_props = [_]options.pixel_type{
		@intCast(chan),
		@intCast(group_id),
	};
	var num_props: usize = 0;
	var use_wp: bool = false;
	var wp_only: bool = false;
	var gradient_only: bool = false;
	var property_use = context_predict.PropertyUsePlan{};
	var flat_tree = try context_predict.filterTree(
		allocator,
		global_tree,
		static_props,
		&num_props,
		&use_wp,
		&wp_only,
		&gradient_only,
		&property_use,
	);
	defer flat_tree.deinit(allocator);

	if ((!allow_wp and use_wp) or (!allow_refs and property_use.usesReferenceProps())) return error.Unsupported;

	const shift_x: u6 = @intCast(channel.hshift);
	const shift_y: u6 = @intCast(channel.vshift);
	const align_x = (@as(usize, 1) << shift_x) - 1;
	const align_y = (@as(usize, 1) << shift_y) - 1;
	if ((rect.x0() & align_x) != 0 or (rect.y0() & align_y) != 0) return error.Unsupported;

	const rx0 = rect.x0() >> shift_x;
	const ry0 = rect.y0() >> shift_y;
	const rw = subsampledSize(rect.xsize(), channel.hshift);
	const rh = subsampledSize(rect.ysize(), channel.vshift);
	const tokens = try allocator.alloc(Token, rw * rh);
	var token_index: usize = 0;

	const tree_lookup = context_predict.MATreeLookup.init(flat_tree.items);
	var stack_properties = [_]pixel_type{0} ** context_predict.kNumNonrefProperties;
	var heap_properties: ?[]pixel_type = null;
	const properties = if (num_props <= stack_properties.len)
		stack_properties[0..num_props]
	else blk: {
		heap_properties = try allocator.alloc(pixel_type, num_props);
		break :blk heap_properties.?;
	};
	defer if (heap_properties) |allocated| allocator.free(allocated);
	@memset(properties, 0);
	properties[0] = static_props[0];
	properties[1] = static_props[1];

	const use_prop_y = property_use.uses(2);
	const use_prop_x = property_use.uses(3);
	const use_prop_abs_top = property_use.uses(4);
	const use_prop_abs_left = property_use.uses(5);
	const use_prop_top = property_use.uses(6);
	const use_prop_left = property_use.uses(7);
	const use_prop_left_minus_gradient = property_use.uses(8);
	const use_prop_gradient = property_use.uses(9);
	const use_prop_left_minus_topleft = property_use.uses(10);
	const use_prop_topleft_minus_top = property_use.uses(11);
	const use_prop_top_minus_topright = property_use.uses(12);
	const use_prop_top_minus_toptop = property_use.uses(13);
	const use_prop_left_minus_leftleft = property_use.uses(14);
	const use_prop_wp = property_use.uses(context_predict.kWPProp);
	const use_local_gradient_history = property_use.needsLocalGradientHistory();
	const reference_props = property_use.referenceProps();
	var references: ?Channel = null;
	if (allow_refs and reference_props.len > 0 and num_props > context_predict.kNumNonrefProperties) {
		references = try Channel.create(allocator, num_props - context_predict.kNumNonrefProperties, rw, 0, 0);
	}
	defer {
		if (references) |*channel_refs| channel_refs.deinit();
	}
	var wp_state: ?weighted.State = null;
	if (use_wp) {
		wp_state = try weighted.State.init(allocator, .{}, rw, rh);
	}
	defer {
		if (wp_state) |*state| state.deinit();
	}

	for (0..rh) |y| {
		const global_y = ry0 + y;
		const row = channel.rowConst(global_y);
		const has_top = y > 0;
		const has_toptop = y > 1;
		const top_row = if (has_top) channel.rowConst(global_y - 1) else &[_]i32{};
		const top2_row = if (has_toptop) channel.rowConst(global_y - 2) else &[_]i32{};
		var prev_gradient: pixel_type_w = 0;
		if (references) |*channel_refs| {
			precomputeReferencesRect(channel, rect, y, image, chan, &property_use, channel_refs);
		}

		if (use_prop_y) properties[2] = @intCast(y);

		for (0..rw) |x| {
			const global_x = rx0 + x;
			const left: pixel_type_w = if (x > 0) row[global_x - 1] else if (has_top) top_row[global_x] else 0;
			const top: pixel_type_w = if (has_top) top_row[global_x] else left;
			const topleft: pixel_type_w = if (x > 0 and has_top) top_row[global_x - 1] else left;
			const topright: pixel_type_w = if (x + 1 < rw and has_top) top_row[global_x + 1] else top;
			const leftleft: pixel_type_w = if (x > 1) row[global_x - 2] else left;
			const toptop: pixel_type_w = if (has_toptop) top2_row[global_x] else top;
			const toprightright: pixel_type_w = if (x + 2 < rw and has_top) top_row[global_x + 2] else topright;

			if (use_prop_x) properties[3] = @intCast(x);
			if (use_prop_abs_top) properties[4] = absPixel(top);
			if (use_prop_abs_left) properties[5] = absPixel(left);
			if (use_prop_top) properties[6] = @intCast(top);
			if (use_prop_left) properties[7] = @intCast(left);
			if (use_local_gradient_history) {
				const next_gradient = left + top - topleft;
				if (use_prop_left_minus_gradient) properties[8] = @intCast(left - prev_gradient);
				if (use_prop_gradient) properties[9] = @intCast(next_gradient);
				prev_gradient = next_gradient;
			}
			if (use_prop_left_minus_topleft) properties[10] = @intCast(left - topleft);
			if (use_prop_topleft_minus_top) properties[11] = @intCast(topleft - top);
			if (use_prop_top_minus_topright) properties[12] = @intCast(top - topright);
			if (use_prop_top_minus_toptop) properties[13] = @intCast(top - toptop);
			if (use_prop_left_minus_leftleft) properties[14] = @intCast(left - leftleft);

			var wp_pred: pixel_type_w = 0;
			if (wp_state) |*state| {
				if (use_prop_wp) {
					wp_pred = state.predictNoProps(x, y, rw, top, left, topright, topleft, toptop);
					properties[context_predict.kWPProp] = state.getWPProp();
				} else {
					wp_pred = state.predictNoWPProp(x, y, rw, top, left, topright, topleft, toptop);
				}
			}
			if (references) |*channel_refs| {
				const ref_props = channel_refs.rowConst(x);
				for (reference_props) |property_index_u8| {
					const property_index: usize = property_index_u8;
					properties[property_index] = ref_props[property_index - context_predict.kNumNonrefProperties];
				}
			}

			const lr = tree_lookup.lookup(properties);
			const pred = context_predict.predictOne(
				lr.predictor,
				left,
				top,
				toptop,
				topleft,
				topright,
				leftleft,
				toprightright,
				wp_pred,
			) + lr.offset;
			const residual = @as(pixel_type_w, row[global_x]) - pred;
			const multiplier = @as(pixel_type_w, lr.multiplier);
			if (@mod(residual, multiplier) != 0) return error.GenericError;

			tokens[token_index] = Token.init(
				lr.context,
				pack_signed.packSigned(@intCast(@divExact(residual, multiplier))),
			);
			if (wp_state) |*state| {
				state.updateErrors(row[global_x], x, y, rw);
			}
			token_index += 1;
		}
	}

	return tokens;
}

/// Tokenizes one channel rect using the filtered MA tree itself instead of a
/// fixed predictor, mirroring the no-WP/no-reference per-pixel encoder loop.
fn tokenizeGlobalTreeChannelRectNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	chan: usize,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	rect: Rect,
) ![]Token {
	return tokenizeGlobalTreeChannelRectImpl(
		allocator,
		image,
		chan,
		group_id,
		global_tree,
		rect,
		false,
		false,
	);
}

/// Tokenizes one channel rect through the same filtered tree path, but keeps
/// the default weighted predictor state active for trees that need it.
fn tokenizeGlobalTreeChannelRectWPNoRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	chan: usize,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	rect: Rect,
) ![]Token {
	return tokenizeGlobalTreeChannelRectImpl(
		allocator,
		image,
		chan,
		group_id,
		global_tree,
		rect,
		true,
		false,
	);
}

/// Tokenizes one channel rect using filtered MA-tree lookup plus rect-local
/// previous-channel properties, while still forbidding weighted state.
fn tokenizeGlobalTreeChannelRectRefsNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	chan: usize,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	rect: Rect,
) ![]Token {
	return tokenizeGlobalTreeChannelRectImpl(
		allocator,
		image,
		chan,
		group_id,
		global_tree,
		rect,
		false,
		true,
	);
}

/// Tokenizes one channel rect through the fully general filtered MA-tree path:
/// rect-local previous-channel properties plus default weighted predictor state.
fn tokenizeGlobalTreeChannelRectWPRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	chan: usize,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	rect: Rect,
) ![]Token {
	return tokenizeGlobalTreeChannelRectImpl(
		allocator,
		image,
		chan,
		group_id,
		global_tree,
		rect,
		true,
		true,
	);
}

fn selectLocalHistogramConfig(tokens: []const Token) !LocalHistogramConfig {
	var max_value: u32 = 0;
	for (tokens) |token| {
		if (token.context != 0) return error.GenericError;
		max_value = @max(max_value, token.value);
	}

	if (max_value < 256) {
		const alphabet_size = max_value + 1;
		const log_alpha_size: u5 = if (alphabet_size <= 32)
			5
		else if (alphabet_size <= 64)
			6
		else if (alphabet_size <= 128)
			7
		else
			8;
		return .{
			.uint_config = HybridUintConfig.init(log_alpha_size, 0, 0),
			.log_alpha_size = log_alpha_size,
			.alphabet_size = alphabet_size,
		};
	}

	const uint_config = HybridUintConfig.initDefault();
	var max_encoded_token: u32 = 0;
	for (tokens) |token| {
		const encoded = uint_config.encode(token.value);
		max_encoded_token = @max(max_encoded_token, encoded.token);
	}
	if (max_encoded_token >= 256) return error.Unsupported;
	return .{
		.uint_config = uint_config,
		.log_alpha_size = 8,
		.alphabet_size = max_encoded_token + 1,
	};
}

fn writeSingleNodeLocalTreeGroupTokens(
	allocator: std.mem.Allocator,
	tokens: []const Token,
	predictor: Predictor,
	cache: ?*FlatHistogramInfoCache,
	writer: *BitWriter,
) !usize {
	if (tokens.len == 0) return error.GenericError;
	const cfg = try selectLocalHistogramConfig(tokens);

	try writeEmptyModularGroup(writer);
	return writeSingleNodeLocalTreeGroupTokensBody(allocator, tokens, predictor, cache, cfg, writer);
}

/// Writes the local tree, histogram, and token payload after any desired modular
/// header has already been emitted, so narrow transform-bearing paths can reuse the same body.
fn writeSingleNodeLocalTreeGroupTokensBody(
	allocator: std.mem.Allocator,
	tokens: []const Token,
	predictor: Predictor,
	cache: ?*FlatHistogramInfoCache,
	cfg: LocalHistogramConfig,
	writer: *BitWriter,
) !usize {
	try enc_ma.writeSingleLeafTree(allocator, predictor, writer);
	try enc_ans.writeSingleContextFlatHistogram(@intCast(cfg.alphabet_size), cfg.uint_config, cfg.log_alpha_size, writer);

	const info = if (cache) |hist_cache|
		try hist_cache.getOrCreate(cfg)
	else blk: {
		const counts = try ans_common.createFlatHistogram(allocator, cfg.alphabet_size, ans_params.ans_tab_size);
		defer allocator.free(counts);
		const built = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, cfg.log_alpha_size);
		break :blk built;
	};
	defer if (cache == null) enc_ans.freeANSEncSymbolInfoTable(allocator, @constCast(info));

	return enc_ans.writeSingleHistogramTokens(tokens, info, cfg.uint_config, writer);
}

fn appendImageRectTokens(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	ctx_id: u32,
	tokens: *std.ArrayList(Token),
) !void {
	if (image.channels.items.len == 0) return error.GenericError;

	for (image.channels.items) |*channel| {
		const channel_tokens = try tokenizeSingleNodeChannelRect(allocator, channel, rect, predictor, ctx_id);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}
}

fn appendImageRectTokensWithChannelContexts(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	channel_contexts: []const u32,
	tokens: *std.ArrayList(Token),
) !void {
	if (image.channels.items.len == 0 or image.channels.items.len != channel_contexts.len) return error.GenericError;

	for (image.channels.items, 0..) |*channel, channel_index| {
		const channel_tokens = try tokenizeSingleNodeChannelRect(allocator, channel, rect, predictor, channel_contexts[channel_index]);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}
}

/// Shared multichannel no-reference MA-tree token gatherer for one group rect.
fn appendGlobalTreeImageRectTokensNoRefsImpl(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
	comptime allow_wp: bool,
) !void {
	if (image.channels.items.len == 0) return error.GenericError;

	for (image.channels.items, 0..) |_, chan| {
		const channel_tokens = if (comptime allow_wp)
			try tokenizeGlobalTreeChannelRectWPNoRefs(allocator, image, chan, group_id, global_tree, rect)
		else
			try tokenizeGlobalTreeChannelRectNoWP(allocator, image, chan, group_id, global_tree, rect);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}
}

/// Tokenizes every channel in a group rect by walking the filtered MA tree per
/// pixel, which is the first upstream-shaped path toward general modular encode.
fn appendGlobalTreeImageRectTokensNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
) !void {
	return appendGlobalTreeImageRectTokensNoRefsImpl(
		allocator,
		image,
		rect,
		group_id,
		global_tree,
		tokens,
		false,
	);
}

/// Tokenizes every channel in a group rect through the no-reference MA-tree
/// path while keeping default weighted predictor state active when needed.
fn appendGlobalTreeImageRectTokensWPNoRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
) !void {
	return appendGlobalTreeImageRectTokensNoRefsImpl(
		allocator,
		image,
		rect,
		group_id,
		global_tree,
		tokens,
		true,
	);
}

/// Tokenizes every channel in a group rect through the rect-local
/// previous-channel-property path while keeping weighted state disabled.
fn appendGlobalTreeImageRectTokensRefsNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
) !void {
	if (image.channels.items.len == 0) return error.GenericError;

	for (image.channels.items, 0..) |_, chan| {
		const channel_tokens = try tokenizeGlobalTreeChannelRectRefsNoWP(
			allocator,
			image,
			chan,
			group_id,
			global_tree,
			rect,
		);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}
}

/// Tokenizes every channel in a group rect through the fully general MA-tree
/// path: weighted predictor state plus rect-local previous-channel properties.
fn appendGlobalTreeImageRectTokensWPRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
) !void {
	if (image.channels.items.len == 0) return error.GenericError;

	for (image.channels.items, 0..) |_, chan| {
		const channel_tokens = try tokenizeGlobalTreeChannelRectWPRefs(
			allocator,
			image,
			chan,
			group_id,
			global_tree,
			rect,
		);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}
}

fn leafCount(tree: []const dec_ma.PropertyDecisionNode) usize {
	var count: usize = 0;
	for (tree) |node| {
		if (node.property == -1) count += 1;
	}
	return count;
}

pub const GroupRect = struct {
	group_id: usize,
	rect: Rect,
};

/// Emits the narrow global-tree DC-global payload: a serialized MA tree, a
/// single shared flat histogram for all leaf contexts, then an empty modular image.
pub fn writeGlobalTreeDcSection(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	alphabet_size: u16,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	if (tree.len == 0) return error.GenericError;

	try writer.write(1, 1); // has_tree = true
	try enc_ma.writeTree(allocator, tree, writer);
	try enc_ans.writeAllZeroContextMapFlatHistogram(leafCount(tree), alphabet_size, uint_config, log_alpha_size, writer);
	try writeEmptyModularGroup(writer);
}

/// Emits the narrow DC-global shape for an encoded global tree plus a simple
/// direct-entry context map and one flat histogram per histogram ID.
pub fn writeGlobalTreeDcSectionWithFlatHistograms(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	num_histograms: usize,
	alphabet_sizes: []const u16,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	if (tree.len == 0 or leafCount(tree) != context_map.len) return error.GenericError;

	try writer.write(1, 1); // has_tree = true
	try enc_ma.writeTree(allocator, tree, writer);
	try enc_ans.writeContextMapFlatHistograms(allocator, context_map, num_histograms, alphabet_sizes, uint_configs, log_alpha_size, writer);
	try writeEmptyModularGroup(writer);
}

/// Emits the same narrow DC-global shape as the flat helper, but preserves the
/// real normalized counts gathered from already-tokenized MA-tree streams.
pub fn writeGlobalTreeDcSectionWithNormalizedHistograms(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	num_histograms: usize,
	normalized_counts: []const []const i32,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	if (tree.len == 0 or leafCount(tree) != context_map.len) return error.GenericError;
	if (normalized_counts.len != num_histograms or uint_configs.len != num_histograms) return error.GenericError;

	try writer.write(1, 1); // has_tree = true
	try enc_ma.writeTree(allocator, tree, writer);
	try enc_ans.writeContextMapNormalizedHistograms(allocator, context_map, num_histograms, normalized_counts, uint_configs, log_alpha_size, writer);
	try writeEmptyModularGroup(writer);
}

/// Emits the same exact-histogram DC-global payload as the normalized helper,
/// but keeps one narrow modular RCT transform in the header for RGB lossless paths.
pub fn writeGlobalTreeDcSectionWithNormalizedHistogramsAndRCT(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	num_histograms: usize,
	normalized_counts: []const []const i32,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	begin_c: u32,
	rct_type: u32,
	writer: *BitWriter,
) !void {
	if (tree.len == 0 or leafCount(tree) != context_map.len) return error.GenericError;
	if (normalized_counts.len != num_histograms or uint_configs.len != num_histograms) return error.GenericError;

	try writer.write(1, 1); // has_tree = true
	try enc_ma.writeTree(allocator, tree, writer);
	try enc_ans.writeContextMapNormalizedHistograms(allocator, context_map, num_histograms, normalized_counts, uint_configs, log_alpha_size, writer);
	try writeEmptyModularGroupWithRCT(begin_c, rct_type, writer);
}

/// Tokenizes one channel against a single predictor leaf, producing the packed
/// residual integers the ANS writer will later entropy-code for grayscale paths.
pub fn tokenizeSingleNodeChannel(
    allocator: std.mem.Allocator,
    channel: *const Channel,
    predictor: Predictor,
    ctx_id: u32,
) ![]Token {
    if (predictor == .weighted or predictor == .best or predictor == .variable) {
        return error.GenericError;
    }

    const total = channel.w * channel.h;
    const tokens = try allocator.alloc(Token, total);
    var token_index: usize = 0;

    for (0..channel.h) |y| {
        const row = channel.rowConst(y);
        const has_top = y > 0;
        const has_toptop = y > 1;
        const top_row = if (has_top) channel.rowConst(y - 1) else &[_]i32{};
        const top2_row = if (has_toptop) channel.rowConst(y - 2) else &[_]i32{};

        for (0..channel.w) |x| {
            const left: pixel_type_w = if (x > 0) row[x - 1] else if (has_top) top_row[x] else 0;
            const top: pixel_type_w = if (has_top) top_row[x] else left;
            const topleft: pixel_type_w = if (x > 0 and has_top) top_row[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < channel.w and has_top) top_row[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) row[x - 2] else left;
            const toptop: pixel_type_w = if (has_toptop) top2_row[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < channel.w and has_top) top_row[x + 2] else topright;
            const guess = context_predict.predictOne(
                predictor,
                left,
                top,
                toptop,
                topleft,
                topright,
                leftleft,
                toprightright,
                0,
            );
            const residual: i32 = @intCast(@as(pixel_type_w, row[x]) - guess);
            tokens[token_index] = Token.init(ctx_id, pack_signed.packSigned(residual));
            token_index += 1;
        }
    }

    return tokens;
}

/// Bridges grayscale residual tokenization to the ANS writer so the first
/// modular encoder slice can emit a real decodable entropy stream end-to-end.
pub fn writeSingleNodeChannelTokens(
    allocator: std.mem.Allocator,
    channel: *const Channel,
    predictor: Predictor,
    ctx_id: u32,
    info: []const enc_ans.ANSEncSymbolInfo,
    uint_config: HybridUintConfig,
    writer: *BitWriter,
) !usize {
    const tokens = try tokenizeSingleNodeChannel(allocator, channel, predictor, ctx_id);
    defer allocator.free(tokens);
    return enc_ans.writeSingleHistogramTokens(tokens, info, uint_config, writer);
}

/// Emits the smallest real modular group stream we can currently write:
/// global-tree mode, default WP header, no transforms, then one single-node channel payload.
pub fn writeSingleNodeGlobalTreeGroup(
    allocator: std.mem.Allocator,
    channel: *const Channel,
    predictor: Predictor,
    ctx_id: u32,
    info: []const enc_ans.ANSEncSymbolInfo,
    uint_config: HybridUintConfig,
    writer: *BitWriter,
) !usize {
    try writer.write(1, 1); // use_global_tree = true
    try writer.write(1, 1); // weighted header all-default
    try writer.write(2, 0); // num_transforms = 0 via selector 0
    return writeSingleNodeChannelTokens(allocator, channel, predictor, ctx_id, info, uint_config, writer);
}

/// Emits a multichannel/group-rect payload that reuses an already-encoded
/// global tree and histogram bundle, so per-group sections only carry tokens.
pub fn writeSingleNodeGlobalTreeGroupImageRect(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	ctx_id: u32,
	info: []const enc_ans.ANSEncSymbolInfo,
	uint_config: HybridUintConfig,
	writer: *BitWriter,
) !usize {
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{info};
	const context_map = [_]u8{0};
	const uint_configs = [_]HybridUintConfig{uint_config};
	const channel_contexts = try allocator.alloc(u32, image.channels.items.len);
	defer allocator.free(channel_contexts);
	@memset(channel_contexts, ctx_id);
	return writeSingleNodeGlobalTreeGroupImageRectContexts(
		allocator,
		image,
		rect,
		predictor,
		channel_contexts,
		&infos,
		&context_map,
		&uint_configs,
		writer,
	);
}

/// Emits a multichannel/group-rect payload whose token contexts can vary by
/// channel, while reusing a previously-encoded global tree/context-map bundle.
pub fn writeSingleNodeGlobalTreeGroupImageRectContexts(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	channel_contexts: []const u32,
	infos: []const []const enc_ans.ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendImageRectTokensWithChannelContexts(allocator, image, rect, predictor, channel_contexts, &tokens);

	try writer.write(1, 1); // use_global_tree = true
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
	return enc_ans.writeContextualHistogramTokens(tokens.items, infos, context_map, uint_configs, writer);
}

/// Writes one global-tree group section whose token contexts come from real
/// per-pixel MA-tree decisions instead of a fixed predictor or channel split.
pub fn writeGlobalTreeGroupImageRectNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	infos: []const []const enc_ans.ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeImageRectTokensNoWP(allocator, image, rect, group_id, global_tree, &tokens);

	try writer.write(1, 1); // use_global_tree = true
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
	return enc_ans.writeContextualHistogramTokens(tokens.items, infos, context_map, uint_configs, writer);
}

/// Writes one global-tree group section for no-reference trees that may use the
/// default weighted predictor state while still sourcing contexts per pixel from
/// MA-tree lookup.
pub fn writeGlobalTreeGroupImageRectWPNoRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	infos: []const []const enc_ans.ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeImageRectTokensWPNoRefs(allocator, image, rect, group_id, global_tree, &tokens);

	try writer.write(1, 1); // use_global_tree = true
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
	return enc_ans.writeContextualHistogramTokens(tokens.items, infos, context_map, uint_configs, writer);
}

/// Writes one global-tree group section for trees that need rect-local
/// previous-channel properties while keeping weighted predictor state disabled.
pub fn writeGlobalTreeGroupImageRectRefsNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	infos: []const []const enc_ans.ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeImageRectTokensRefsNoWP(allocator, image, rect, group_id, global_tree, &tokens);

	try writer.write(1, 1); // use_global_tree = true
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
	return enc_ans.writeContextualHistogramTokens(tokens.items, infos, context_map, uint_configs, writer);
}

/// Writes one global-tree group section for trees that need both default
/// weighted predictor state and rect-local previous-channel properties.
pub fn writeGlobalTreeGroupImageRectWPRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	group_id: usize,
	global_tree: []const dec_ma.PropertyDecisionNode,
	infos: []const []const enc_ans.ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeImageRectTokensWPRefs(allocator, image, rect, group_id, global_tree, &tokens);

	try writer.write(1, 1); // use_global_tree = true
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
	return enc_ans.writeContextualHistogramTokens(tokens.items, infos, context_map, uint_configs, writer);
}

fn appendGlobalTreeTokensForGroupRects(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
	comptime allow_wp: bool,
	comptime allow_refs: bool,
) !void {
	for (group_rects) |group_rect| {
		if (comptime allow_wp and allow_refs) {
			try appendGlobalTreeImageRectTokensWPRefs(
				allocator,
				image,
				group_rect.rect,
				group_rect.group_id,
				global_tree,
				tokens,
			);
		} else if (comptime allow_wp) {
			try appendGlobalTreeImageRectTokensWPNoRefs(
				allocator,
				image,
				group_rect.rect,
				group_rect.group_id,
				global_tree,
				tokens,
			);
		} else if (comptime allow_refs) {
			try appendGlobalTreeImageRectTokensRefsNoWP(
				allocator,
				image,
				group_rect.rect,
				group_rect.group_id,
				global_tree,
				tokens,
			);
		} else {
			try appendGlobalTreeImageRectTokensNoWP(
				allocator,
				image,
				group_rect.rect,
				group_rect.group_id,
				global_tree,
				tokens,
			);
		}
	}
}

/// Builds exact ANS histograms for every group section that will share one
/// encoded MA tree. This mirrors upstream's two-pass shape: tokenize first,
/// then normalize/write histogram metadata once for all groups.
fn buildGlobalTreeHistogramBundleImpl(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	comptime allow_wp: bool,
	comptime allow_refs: bool,
) !enc_ans.ContextualHistogramBundle {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeTokensForGroupRects(
		allocator,
		image,
		group_rects,
		global_tree,
		&tokens,
		allow_wp,
		allow_refs,
	);
	return enc_ans.buildContextualHistogramBundle(
		allocator,
		tokens.items,
		context_map,
		uint_configs,
		log_alpha_size,
	);
}

/// Builds exact histograms for no-WP/no-reference MA-tree group streams.
pub fn buildGlobalTreeHistogramBundleNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !enc_ans.ContextualHistogramBundle {
	return buildGlobalTreeHistogramBundleImpl(
		allocator,
		image,
		group_rects,
		global_tree,
		context_map,
		uint_configs,
		log_alpha_size,
		false,
		false,
	);
}

/// Builds exact histograms for weighted/no-reference MA-tree group streams.
pub fn buildGlobalTreeHistogramBundleWPNoRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !enc_ans.ContextualHistogramBundle {
	return buildGlobalTreeHistogramBundleImpl(
		allocator,
		image,
		group_rects,
		global_tree,
		context_map,
		uint_configs,
		log_alpha_size,
		true,
		false,
	);
}

/// Builds exact histograms for reference-property/no-WP MA-tree group streams.
pub fn buildGlobalTreeHistogramBundleRefsNoWP(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !enc_ans.ContextualHistogramBundle {
	return buildGlobalTreeHistogramBundleImpl(
		allocator,
		image,
		group_rects,
		global_tree,
		context_map,
		uint_configs,
		log_alpha_size,
		false,
		true,
	);
}

/// Builds exact histograms for weighted/reference-property MA-tree group streams.
pub fn buildGlobalTreeHistogramBundleWPRefs(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	group_rects: []const GroupRect,
	global_tree: []const dec_ma.PropertyDecisionNode,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !enc_ans.ContextualHistogramBundle {
	return buildGlobalTreeHistogramBundleImpl(
		allocator,
		image,
		group_rects,
		global_tree,
		context_map,
		uint_configs,
		log_alpha_size,
		true,
		true,
	);
}

/// Emits the smallest local-tree modular group currently supported: one
/// single-leaf tree plus a degenerate one-context channel histogram.
pub fn writeSingleNodeLocalTreeGroup(
	allocator: std.mem.Allocator,
	channel: *const Channel,
	predictor: Predictor,
	writer: *BitWriter,
) !usize {
	const tokens = try tokenizeSingleNodeChannel(allocator, channel, predictor, 0);
	defer allocator.free(tokens);
	return writeSingleNodeLocalTreeGroupTokens(allocator, tokens, predictor, null, writer);
}

/// Extends the local single-leaf modular writer across multiple image channels
/// so the first RGB path can reuse the same tree and histogram while decoding
/// channels in the standard modular channel order.
pub fn writeSingleNodeLocalTreeGroupImage(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	predictor: Predictor,
	writer: *BitWriter,
) !usize {
	return writeSingleNodeLocalTreeGroupImageWithCache(allocator, image, predictor, null, writer);
}

/// Reuses cached flat histogram info tables when repeated tiles share the same
/// token alphabet, avoiding per-tile alias-table rebuilds in the narrow RGB path.
pub fn writeSingleNodeLocalTreeGroupImageWithCache(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	predictor: Predictor,
	cache: ?*FlatHistogramInfoCache,
	writer: *BitWriter,
) !usize {
	if (image.channels.items.len == 0) return error.GenericError;

	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);

    for (image.channels.items) |*channel| {
		const channel_tokens = try tokenizeSingleNodeChannel(allocator, channel, predictor, 0);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}

	return writeSingleNodeLocalTreeGroupTokens(allocator, tokens.items, predictor, cache, writer);
}

/// Extends the narrow local-tree image writer with one squeeze transform header,
/// allowing a forward-squeezed channel set to round-trip through the standard decoder.
pub fn writeSingleNodeLocalTreeGroupImageWithSqueeze(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	squeezes: []const SqueezeParams,
	predictor: Predictor,
	writer: *BitWriter,
) !usize {
	if (image.channels.items.len == 0 or squeezes.len == 0) return error.GenericError;

	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);

	for (image.channels.items) |*channel| {
		const channel_tokens = try tokenizeSingleNodeChannel(allocator, channel, predictor, 0);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}

	const cfg = try selectLocalHistogramConfig(tokens.items);
	try writeEmptyModularGroupWithSqueeze(squeezes, writer);
	return writeSingleNodeLocalTreeGroupTokensBody(allocator, tokens.items, predictor, null, cfg, writer);
}

/// Extends the narrow local-tree image writer with one explicit palette transform,
/// allowing an already palette-transformed grayscale image to round-trip end-to-end.
pub fn writeSingleNodeLocalTreeGroupImageWithPalette(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	palette: Transform,
	predictor: Predictor,
	writer: *BitWriter,
) !usize {
	if (image.channels.items.len == 0) return error.GenericError;

	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);

	for (image.channels.items) |*channel| {
		const channel_tokens = try tokenizeSingleNodeChannel(allocator, channel, predictor, 0);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}

	const cfg = try selectLocalHistogramConfig(tokens.items);
	try writeEmptyModularGroupWithPalette(palette, writer);
	return writeSingleNodeLocalTreeGroupTokensBody(allocator, tokens.items, predictor, null, cfg, writer);
}

/// Reuses the existing local-tree image writer for one frame group by first
/// extracting the caller-requested tile into a temporary standalone image.
pub fn writeSingleNodeLocalTreeGroupImageRect(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	writer: *BitWriter,
) !usize {
	return writeSingleNodeLocalTreeGroupImageRectWithCache(allocator, image, rect, predictor, null, writer);
}

pub fn writeSingleNodeLocalTreeGroupImageRectWithCache(
	allocator: std.mem.Allocator,
	image: *const modular_image.Image,
	rect: Rect,
	predictor: Predictor,
	cache: ?*FlatHistogramInfoCache,
	writer: *BitWriter,
) !usize {
	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendImageRectTokens(allocator, image, rect, predictor, 0, &tokens);

	return writeSingleNodeLocalTreeGroupTokens(allocator, tokens.items, predictor, cache, writer);
}

const testing = std.testing;

test "tokenizeSingleNodeChannel with zero predictor emits packed raw values" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 2, 2, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 1;
    channel.row(0)[1] = -1;
    channel.row(1)[0] = 2;
    channel.row(1)[1] = -2;

    const tokens = try tokenizeSingleNodeChannel(allocator, &channel, .zero, 7);
    defer allocator.free(tokens);

    try testing.expectEqual(@as(usize, 4), tokens.len);
    for (tokens) |token| {
        try testing.expectEqual(@as(u32, 7), token.context);
        try testing.expect(!token.is_lz77_length);
    }
    try testing.expectEqual(pack_signed.packSigned(1), tokens[0].value);
    try testing.expectEqual(pack_signed.packSigned(-1), tokens[1].value);
    try testing.expectEqual(pack_signed.packSigned(2), tokens[2].value);
    try testing.expectEqual(pack_signed.packSigned(-2), tokens[3].value);
}

test "tokenizeSingleNodeChannel with gradient predictor emits packed residuals" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();

    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    const tokens = try tokenizeSingleNodeChannel(allocator, &channel, .gradient, 0);
    defer allocator.free(tokens);

    const expected_residuals = [_]i32{ 10, 2, 2, 1, 1, 1, 2, 1, 3 };
    try testing.expectEqual(expected_residuals.len, tokens.len);
    for (expected_residuals, tokens) |residual, token| {
        try testing.expectEqual(pack_signed.packSigned(residual), token.value);
    }
}

test "tokenizeGlobalTreeChannelRectNoWP emits tree-selected contexts and residuals" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 1);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 1;
	source.channels.items[0].row(0)[2] = 5;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 1;
	source.channels.items[0].row(1)[2] = 10;

	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(@intCast(context_predict.kGradientProp), 0, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .gradient, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};

	const tokens = try tokenizeGlobalTreeChannelRectNoWP(
		allocator,
		&source,
		0,
		0,
		&global_tree,
		Rect.init(0, 0, 3, 2),
	);
	defer allocator.free(tokens);

	const expected_contexts = [_]u32{ 0, 0, 1, 0, 1, 1 };
	const expected_residuals = [_]i32{ 0, 1, 4, 0, 0, 5 };

	try testing.expectEqual(expected_contexts.len, tokens.len);
	for (tokens, 0..) |token, i| {
		try testing.expectEqual(expected_contexts[i], token.context);
		try testing.expectEqual(pack_signed.packSigned(expected_residuals[i]), token.value);
	}
}

test "tokenizeGlobalTreeChannelRectWPNoRefs matches manual weighted predictor tokenization" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 3, 8, 1);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 10;
	source.channels.items[0].row(0)[1] = 12;
	source.channels.items[0].row(0)[2] = 14;
	source.channels.items[0].row(1)[0] = 11;
	source.channels.items[0].row(1)[1] = 13;
	source.channels.items[0].row(1)[2] = 15;
	source.channels.items[0].row(2)[0] = 13;
	source.channels.items[0].row(2)[1] = 14;
	source.channels.items[0].row(2)[2] = 18;

	const global_tree = [_]dec_ma.PropertyDecisionNode{
		.{ .property = -1, .lchild = 0, .predictor = .weighted, .multiplier = 1 },
	};
	const rect = Rect.init(0, 0, 3, 3);

	const tokens = try tokenizeGlobalTreeChannelRectWPNoRefs(
		allocator,
		&source,
		0,
		0,
		&global_tree,
		rect,
	);
	defer allocator.free(tokens);

	var wp_state = try weighted.State.init(allocator, .{}, rect.xsize(), rect.ysize());
	defer wp_state.deinit();
	const expected = try allocator.alloc(Token, tokens.len);
	defer allocator.free(expected);
	var token_index: usize = 0;
	for (0..rect.ysize()) |y| {
		const row = source.channels.items[0].rowConst(rect.y0() + y);
		const has_top = y > 0;
		const has_toptop = y > 1;
		const top_row = if (has_top) source.channels.items[0].rowConst(rect.y0() + y - 1) else &[_]i32{};
		const top2_row = if (has_toptop) source.channels.items[0].rowConst(rect.y0() + y - 2) else &[_]i32{};
		for (0..rect.xsize()) |x| {
			const global_x = rect.x0() + x;
			const left: pixel_type_w = if (x > 0) row[global_x - 1] else if (has_top) top_row[global_x] else 0;
			const top: pixel_type_w = if (has_top) top_row[global_x] else left;
			const topleft: pixel_type_w = if (x > 0 and has_top) top_row[global_x - 1] else left;
			const topright: pixel_type_w = if (x + 1 < rect.xsize() and has_top) top_row[global_x + 1] else top;
			const toptop: pixel_type_w = if (has_toptop) top2_row[global_x] else top;
			const guess = wp_state.predictNoProps(x, y, rect.xsize(), top, left, topright, topleft, toptop);
			const value = row[global_x];
			expected[token_index] = Token.init(0, pack_signed.packSigned(@intCast(@as(pixel_type_w, value) - guess)));
			wp_state.updateErrors(value, x, y, rect.xsize());
			token_index += 1;
		}
	}

	try testing.expectEqual(expected.len, tokens.len);
	for (tokens, expected) |got, want| {
		try testing.expectEqual(want.context, got.context);
		try testing.expectEqual(want.value, got.value);
	}
}

test "tokenizeGlobalTreeChannelRectRefsNoWP uses previous-channel properties for contexts" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 20;
	source.channels.items[0].row(1)[2] = 0;

	source.channels.items[1].row(0)[0] = 5;
	source.channels.items[1].row(0)[1] = 6;
	source.channels.items[1].row(0)[2] = 7;
	source.channels.items[1].row(1)[0] = 8;
	source.channels.items[1].row(1)[1] = 9;
	source.channels.items[1].row(1)[2] = 10;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .zero, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};

	const tokens = try tokenizeGlobalTreeChannelRectRefsNoWP(
		allocator,
		&source,
		1,
		0,
		&global_tree,
		Rect.init(0, 0, 3, 2),
	);
	defer allocator.free(tokens);

	const expected_contexts = [_]u32{ 0, 1, 0, 0, 1, 0 };
	const expected_residuals = [_]i32{ 5, 6, 7, 8, 9, 10 };

	try testing.expectEqual(expected_contexts.len, tokens.len);
	for (tokens, 0..) |token, i| {
		try testing.expectEqual(expected_contexts[i], token.context);
		try testing.expectEqual(pack_signed.packSigned(expected_residuals[i]), token.value);
	}
}

test "tokenizeGlobalTreeChannelRectWPRefs matches weighted residuals with reference-selected contexts" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 3, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 20;
	source.channels.items[0].row(1)[1] = 0;
	source.channels.items[0].row(1)[2] = 20;
	source.channels.items[0].row(2)[0] = 0;
	source.channels.items[0].row(2)[1] = 20;
	source.channels.items[0].row(2)[2] = 0;

	source.channels.items[1].row(0)[0] = 10;
	source.channels.items[1].row(0)[1] = 12;
	source.channels.items[1].row(0)[2] = 14;
	source.channels.items[1].row(1)[0] = 11;
	source.channels.items[1].row(1)[1] = 13;
	source.channels.items[1].row(1)[2] = 15;
	source.channels.items[1].row(2)[0] = 13;
	source.channels.items[1].row(2)[1] = 14;
	source.channels.items[1].row(2)[2] = 18;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .weighted, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .weighted, .multiplier = 1 },
	};
	const rect = Rect.init(0, 0, 3, 3);

	const tokens = try tokenizeGlobalTreeChannelRectWPRefs(
		allocator,
		&source,
		1,
		0,
		&global_tree,
		rect,
	);
	defer allocator.free(tokens);

	var wp_state = try weighted.State.init(allocator, .{}, rect.xsize(), rect.ysize());
	defer wp_state.deinit();
	const expected = try allocator.alloc(Token, tokens.len);
	defer allocator.free(expected);
	var token_index: usize = 0;
	for (0..rect.ysize()) |y| {
		const row = source.channels.items[1].rowConst(rect.y0() + y);
		const ref_row = source.channels.items[0].rowConst(rect.y0() + y);
		const has_top = y > 0;
		const has_toptop = y > 1;
		const top_row = if (has_top) source.channels.items[1].rowConst(rect.y0() + y - 1) else &[_]i32{};
		const top2_row = if (has_toptop) source.channels.items[1].rowConst(rect.y0() + y - 2) else &[_]i32{};
		for (0..rect.xsize()) |x| {
			const global_x = rect.x0() + x;
			const left: pixel_type_w = if (x > 0) row[global_x - 1] else if (has_top) top_row[global_x] else 0;
			const top: pixel_type_w = if (has_top) top_row[global_x] else left;
			const topleft: pixel_type_w = if (x > 0 and has_top) top_row[global_x - 1] else left;
			const topright: pixel_type_w = if (x + 1 < rect.xsize() and has_top) top_row[global_x + 1] else top;
			const toptop: pixel_type_w = if (has_toptop) top2_row[global_x] else top;
			const guess = wp_state.predictNoProps(x, y, rect.xsize(), top, left, topright, topleft, toptop);
			const value = row[global_x];
			const context: u32 = if (ref_row[global_x] > 10) 1 else 0;
			expected[token_index] = Token.init(context, pack_signed.packSigned(@intCast(@as(pixel_type_w, value) - guess)));
			wp_state.updateErrors(value, x, y, rect.xsize());
			token_index += 1;
		}
	}

	try testing.expectEqual(expected.len, tokens.len);
	for (tokens, expected) |got, want| {
		try testing.expectEqual(want.context, got.context);
		try testing.expectEqual(want.value, got.value);
	}
}

test "writeSingleNodeChannelTokens round-trips a grayscale gradient channel through ANS" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();

    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    const tokens = try tokenizeSingleNodeChannel(allocator, &channel, .gradient, 0);
    defer allocator.free(tokens);

    var max_token: u32 = 0;
    for (tokens) |token| max_token = @max(max_token, token.value);
    const alphabet_size = max_token + 1;
    const counts = try ans_common.createFlatHistogram(allocator, alphabet_size, ans_params.ans_tab_size);
    defer allocator.free(counts);

    const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 5);
    defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
    var code = blk: {
        var built = dec_ans.ANSCode.init(allocator);
        errdefer built.deinit();
        built.use_prefix_code = false;
        built.log_alpha_size = 5;
        built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 1 << 5);
        try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 5, built.alias_tables.ptr);
        built.uint_config = try allocator.alloc(HybridUintConfig, 1);
        built.uint_config[0] = HybridUintConfig.init(5, 0, 0);
        break :blk built;
    };
    defer code.deinit();

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeChannelTokens(
        allocator,
        &channel,
        .gradient,
        0,
        info,
        HybridUintConfig.init(5, 0, 0),
        &writer,
    ));
    try writer.zeroPadToByte();

    const context_map = [_]u8{0};
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
    defer reader.deinit();
    var reconstructed = try Channel.create(allocator, 3, 3, 0, 0);
    defer reconstructed.deinit();

    for (0..reconstructed.h) |y| {
        const row = reconstructed.row(y);
        const has_top = y > 0;
        const has_toptop = y > 1;
        const top_row = if (has_top) reconstructed.rowConst(y - 1) else &[_]i32{};
        const top2_row = if (has_toptop) reconstructed.rowConst(y - 2) else &[_]i32{};
        for (0..reconstructed.w) |x| {
            const left: pixel_type_w = if (x > 0) row[x - 1] else if (has_top) top_row[x] else 0;
            const top: pixel_type_w = if (has_top) top_row[x] else left;
            const topleft: pixel_type_w = if (x > 0 and has_top) top_row[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < reconstructed.w and has_top) top_row[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) row[x - 2] else left;
            const toptop: pixel_type_w = if (has_toptop) top2_row[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < reconstructed.w and has_top) top_row[x + 2] else topright;
            const guess = context_predict.predictOne(.gradient, left, top, toptop, topleft, topright, leftleft, toprightright, 0);
            const encoded = reader.readHybridUint(0, &br, &context_map);
            row[x] = @intCast(guess + pack_signed.unpackSigned(@intCast(encoded)));
        }
    }

    try testing.expectEqualSlices(i32, channel.data, reconstructed.data);
    try testing.expect(reader.checkANSFinalState());
    try br.jumpToByteBoundary();
    try br.close();
}

test "writeSingleNodeGlobalTreeGroup round-trips through modularDecode with injected global tree" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();

    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    const tokens = try tokenizeSingleNodeChannel(allocator, &channel, .gradient, 0);
    defer allocator.free(tokens);

    var max_token: u32 = 0;
    for (tokens) |token| max_token = @max(max_token, token.value);
    const alphabet_size = max_token + 1;
    const counts = try ans_common.createFlatHistogram(allocator, alphabet_size, ans_params.ans_tab_size);
    defer allocator.free(counts);

    const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 5);
    defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
    var code = blk: {
        var built = dec_ans.ANSCode.init(allocator);
        errdefer built.deinit();
        built.use_prefix_code = false;
        built.log_alpha_size = 5;
        built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 1 << 5);
        try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 5, built.alias_tables.ptr);
        built.uint_config = try allocator.alloc(HybridUintConfig, 1);
        built.uint_config[0] = HybridUintConfig.init(5, 0, 0);
        break :blk built;
    };
    defer code.deinit();

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeGlobalTreeGroup(
        allocator,
        &channel,
        .gradient,
        0,
        info,
        HybridUintConfig.init(5, 0, 0),
        &writer,
    ));
    try writer.zeroPadToByte();

    const global_tree = [_]@import("dec_ma.zig").PropertyDecisionNode{
        @import("dec_ma.zig").PropertyDecisionNode.leaf(.gradient, 0, 1),
    };
    const context_map = [_]u8{0};

    var image = try modular_image.Image.create(allocator, 3, 3, 8, 1);
    defer image.deinit();
    var header = @import("encoding.zig").GroupHeader{};
    defer header.deinit();
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    try @import("encoding.zig").modularDecode(
        &br,
        &image,
        &header,
        0,
        &options.ModularOptions{},
        global_tree[0..],
        &code,
        context_map[0..],
        allocator,
    );
    try br.jumpToByteBoundary();
    try br.close();

	try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeSingleNodeGlobalTreeGroup round-trips through modularDecode with a generated fixed tree" {
	const allocator = testing.allocator;
	var channel = try Channel.create(allocator, 3, 3, 0, 0);
	defer channel.deinit();

	channel.row(0)[0] = 10;
	channel.row(0)[1] = 12;
	channel.row(0)[2] = 14;
	channel.row(1)[0] = 11;
	channel.row(1)[1] = 13;
	channel.row(1)[2] = 15;
	channel.row(2)[0] = 13;
	channel.row(2)[1] = 14;
	channel.row(2)[2] = 18;

	const tokens = try tokenizeSingleNodeChannel(allocator, &channel, .gradient, 0);
	defer allocator.free(tokens);

	var max_token: u32 = 0;
	for (tokens) |token| max_token = @max(max_token, token.value);
	const alphabet_size = max_token + 1;
	const counts = try ans_common.createFlatHistogram(allocator, alphabet_size, ans_params.ans_tab_size);
	defer allocator.free(counts);

	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 5);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
	var code = blk: {
		var built = dec_ans.ANSCode.init(allocator);
		errdefer built.deinit();
		built.use_prefix_code = false;
		built.log_alpha_size = 5;
		built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 1 << 5);
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 5, built.alias_tables.ptr);
		built.uint_config = try allocator.alloc(HybridUintConfig, 1);
		built.uint_config[0] = HybridUintConfig.init(5, 0, 0);
		break :blk built;
	};
	defer code.deinit();

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeSingleNodeGlobalTreeGroup(
		allocator,
		&channel,
		.gradient,
		0,
		info,
		HybridUintConfig.init(5, 0, 0),
		&writer,
	));
	try writer.zeroPadToByte();

	var global_tree = try predefinedTree(allocator, .gradient_fixed_dc, channel.w * channel.h, 8, 0);
	defer global_tree.deinit(allocator);
	var num_leaves: usize = 0;
	for (global_tree.items) |node| {
		if (node.property == -1) num_leaves += 1;
	}
	const context_map = try allocator.alloc(u8, num_leaves);
	defer allocator.free(context_map);
	@memset(context_map, 0);

	var image = try modular_image.Image.create(allocator, 3, 3, 8, 1);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree.items,
		&code,
		context_map,
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeGlobalTreeGroupImageRectNoWP round-trips tree-driven grayscale tokens through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 1);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 1;
	source.channels.items[0].row(0)[2] = 5;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 1;
	source.channels.items[0].row(1)[2] = 10;

	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(@intCast(context_predict.kGradientProp), 0, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .gradient, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(8, 0, 0),
		HybridUintConfig.init(8, 0, 0),
	};
	const alphabet_sizes = [_]u16{ 256, 256 };

	const counts = try ans_common.createFlatHistogram(allocator, 256, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{ info, info };

	var hist_writer = BitWriter.init(allocator);
	defer hist_writer.deinit();
	try enc_ans.writeSimpleContextMapFlatHistograms(
		&context_map,
		2,
		&alphabet_sizes,
		&uint_configs,
		8,
		&hist_writer,
	);
	try hist_writer.zeroPadToByte();

	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	var hist_br = @import("../base/bit_reader.zig").BitReader.init(hist_writer.bytes());
	const decoded_context_map = try dec_ans.decodeHistograms(allocator, &hist_br, context_map.len, &code);
	defer allocator.free(decoded_context_map);
	try testing.expectEqualSlices(u8, &context_map, decoded_context_map);
	try hist_br.close();

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeGlobalTreeGroupImageRectNoWP(
		allocator,
		&source,
		Rect.init(0, 0, 3, 2),
		0,
		&global_tree,
		&infos,
		&context_map,
		&uint_configs,
		&writer,
	));
	try writer.zeroPadToByte();

	var image = try modular_image.Image.create(allocator, 3, 2, 8, 1);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		decoded_context_map,
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	try testing.expectEqualSlices(i32, source.channels.items[0].data, image.channels.items[0].data);
}

test "buildGlobalTreeHistogramBundleNoWP matches direct tree-driven token histograms" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 1);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 1;
	source.channels.items[0].row(0)[2] = 5;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 1;
	source.channels.items[0].row(1)[2] = 10;

	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(@intCast(context_predict.kGradientProp), 0, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .gradient, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.initDefault(),
		HybridUintConfig.initDefault(),
	};
	const group_rects = [_]GroupRect{
		.{ .group_id = 0, .rect = Rect.init(0, 0, 3, 2) },
	};

	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);
	try appendGlobalTreeImageRectTokensNoWP(
		allocator,
		&source,
		group_rects[0].rect,
		group_rects[0].group_id,
		&global_tree,
		&tokens,
	);

	var want_bundle = try enc_ans.buildContextualHistogramBundle(
		allocator,
		tokens.items,
		&context_map,
		&uint_configs,
		8,
	);
	defer want_bundle.deinit(allocator);

	var got_bundle = try buildGlobalTreeHistogramBundleNoWP(
		allocator,
		&source,
		&group_rects,
		&global_tree,
		&context_map,
		&uint_configs,
		8,
	);
	defer got_bundle.deinit(allocator);

	try testing.expect(want_bundle.normalized_counts[0].len > 1);
	try testing.expect(want_bundle.normalized_counts[0][0] != want_bundle.normalized_counts[0][1]);
	try testing.expectEqualSlices(u8, want_bundle.context_map, got_bundle.context_map);
	try testing.expectEqual(@as(usize, want_bundle.normalized_counts.len), got_bundle.normalized_counts.len);
	for (want_bundle.normalized_counts, got_bundle.normalized_counts) |want_counts, got_counts| {
		try testing.expectEqualSlices(i32, want_counts, got_counts);
	}
	try testing.expectEqualSlices(HybridUintConfig, want_bundle.uint_configs, got_bundle.uint_configs);
}

test "writeGlobalTreeGroupImageRectWPNoRefs round-trips weighted grayscale tokens through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 3, 8, 1);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 10;
	source.channels.items[0].row(0)[1] = 12;
	source.channels.items[0].row(0)[2] = 14;
	source.channels.items[0].row(1)[0] = 11;
	source.channels.items[0].row(1)[1] = 13;
	source.channels.items[0].row(1)[2] = 15;
	source.channels.items[0].row(2)[0] = 13;
	source.channels.items[0].row(2)[1] = 14;
	source.channels.items[0].row(2)[2] = 18;

	const global_tree = [_]dec_ma.PropertyDecisionNode{
		.{ .property = -1, .lchild = 0, .predictor = .weighted, .multiplier = 1 },
	};
	const context_map = [_]u8{0};
	const uint_config = HybridUintConfig.init(8, 0, 0);

	const counts = try ans_common.createFlatHistogram(allocator, 256, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{info};
	const uint_configs = [_]HybridUintConfig{uint_config};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeGlobalTreeGroupImageRectWPNoRefs(
		allocator,
		&source,
		Rect.init(0, 0, 3, 3),
		0,
		&global_tree,
		&infos,
		&context_map,
		&uint_configs,
		&writer,
	));
	try writer.zeroPadToByte();

	var code = blk: {
		var built = dec_ans.ANSCode.init(allocator);
		errdefer built.deinit();
		built.use_prefix_code = false;
		built.log_alpha_size = 8;
		built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 1 << 8);
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 8, built.alias_tables.ptr);
		built.uint_config = try allocator.alloc(HybridUintConfig, 1);
		built.uint_config[0] = uint_config;
		break :blk built;
	};
	defer code.deinit();

	var image = try modular_image.Image.create(allocator, 3, 3, 8, 1);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		context_map[0..],
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	try testing.expectEqualSlices(i32, source.channels.items[0].data, image.channels.items[0].data);
}

test "writeGlobalTreeGroupImageRectRefsNoWP round-trips reference-property tokens through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 20;
	source.channels.items[0].row(1)[2] = 0;

	source.channels.items[1].row(0)[0] = 5;
	source.channels.items[1].row(0)[1] = 6;
	source.channels.items[1].row(0)[2] = 7;
	source.channels.items[1].row(1)[0] = 8;
	source.channels.items[1].row(1)[1] = 9;
	source.channels.items[1].row(1)[2] = 10;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .zero, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_config = HybridUintConfig.init(8, 0, 0);

	const counts = try ans_common.createFlatHistogram(allocator, 256, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{ info, info };
	const uint_configs = [_]HybridUintConfig{ uint_config, uint_config };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeGlobalTreeGroupImageRectRefsNoWP(
		allocator,
		&source,
		Rect.init(0, 0, 3, 2),
		0,
		&global_tree,
		&infos,
		&context_map,
		&uint_configs,
		&writer,
	));
	try writer.zeroPadToByte();

	var code = blk: {
		var built = dec_ans.ANSCode.init(allocator);
		errdefer built.deinit();
		built.use_prefix_code = false;
		built.log_alpha_size = 8;
		built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 2 * (1 << 8));
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 8, built.alias_tables[0 .. (1 << 8)].ptr);
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 8, built.alias_tables[(1 << 8) ..][0 .. (1 << 8)].ptr);
		built.uint_config = try allocator.alloc(HybridUintConfig, 2);
		built.uint_config[0] = uint_config;
		built.uint_config[1] = uint_config;
		break :blk built;
	};
	defer code.deinit();

	var image = try modular_image.Image.create(allocator, 3, 2, 8, 2);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		context_map[0..],
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeGlobalTreeGroupImageRectRefsNoWP round-trips with exact histogram metadata" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 2, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 0;
	source.channels.items[0].row(1)[1] = 20;
	source.channels.items[0].row(1)[2] = 0;

	source.channels.items[1].row(0)[0] = 5;
	source.channels.items[1].row(0)[1] = 6;
	source.channels.items[1].row(0)[2] = 7;
	source.channels.items[1].row(1)[0] = 8;
	source.channels.items[1].row(1)[1] = 9;
	source.channels.items[1].row(1)[2] = 10;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .zero, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.initDefault(),
		HybridUintConfig.initDefault(),
	};
	const group_rects = [_]GroupRect{
		.{ .group_id = 0, .rect = Rect.init(0, 0, 3, 2) },
	};

	var bundle = try buildGlobalTreeHistogramBundleRefsNoWP(
		allocator,
		&source,
		&group_rects,
		&global_tree,
		&context_map,
		&uint_configs,
		8,
	);
	defer bundle.deinit(allocator);

	var hist_writer = BitWriter.init(allocator);
	defer hist_writer.deinit();
	try enc_ans.writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		8,
		&hist_writer,
	);
	try hist_writer.zeroPadToByte();

	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	var hist_br = @import("../base/bit_reader.zig").BitReader.init(hist_writer.bytes());
	const decoded_context_map = try dec_ans.decodeHistograms(allocator, &hist_br, context_map.len, &code);
	defer allocator.free(decoded_context_map);
	try testing.expectEqualSlices(u8, bundle.context_map, decoded_context_map);
	try hist_br.close();

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	const extra_bits = try writeGlobalTreeGroupImageRectRefsNoWP(
		allocator,
		&source,
		Rect.init(0, 0, 3, 2),
		0,
		&global_tree,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try testing.expect(extra_bits > 0);
	try writer.zeroPadToByte();

	var image = try modular_image.Image.create(allocator, 3, 2, 8, 2);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		decoded_context_map,
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "buildGlobalTreeHistogramBundleRefsNoWP reuses one exact bundle across multiple group ids" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 6, 4, 8, 2);
	defer source.deinit();

	for (0..source.h) |y| {
		for (0..source.w) |x| {
			source.channels.items[0].row(y)[x] = if ((x + y) % 2 == 0) 0 else 20;
			source.channels.items[1].row(y)[x] = @intCast(5 + x * 2 + y * 3);
		}
	}

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .zero, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .zero, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.initDefault(),
		HybridUintConfig.initDefault(),
	};
	const group_rects = [_]GroupRect{
		.{ .group_id = 0, .rect = Rect.init(0, 0, 3, 2) },
		.{ .group_id = 1, .rect = Rect.init(3, 0, 3, 2) },
		.{ .group_id = 2, .rect = Rect.init(0, 2, 3, 2) },
	};

	var bundle = try buildGlobalTreeHistogramBundleRefsNoWP(
		allocator,
		&source,
		&group_rects,
		&global_tree,
		&context_map,
		&uint_configs,
		8,
	);
	defer bundle.deinit(allocator);

	var hist_writer = BitWriter.init(allocator);
	defer hist_writer.deinit();
	try enc_ans.writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		8,
		&hist_writer,
	);
	try hist_writer.zeroPadToByte();

	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	var hist_br = @import("../base/bit_reader.zig").BitReader.init(hist_writer.bytes());
	const decoded_context_map = try dec_ans.decodeHistograms(allocator, &hist_br, context_map.len, &code);
	defer allocator.free(decoded_context_map);
	try testing.expectEqualSlices(u8, bundle.context_map, decoded_context_map);
	try hist_br.close();

	for (group_rects) |group_rect| {
		var writer = BitWriter.init(allocator);
		defer writer.deinit();
		_ = try writeGlobalTreeGroupImageRectRefsNoWP(
			allocator,
			&source,
			group_rect.rect,
			group_rect.group_id,
			&global_tree,
			bundle.infos,
			bundle.context_map,
			bundle.uint_configs,
			&writer,
		);
		try writer.zeroPadToByte();

		var image = try modular_image.Image.create(allocator, group_rect.rect.xsize(), group_rect.rect.ysize(), 8, 2);
		defer image.deinit();
		var header = @import("encoding.zig").GroupHeader{};
		defer header.deinit();
		var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
		try @import("encoding.zig").modularDecode(
			&br,
			&image,
			&header,
			group_rect.group_id,
			&options.ModularOptions{},
			global_tree[0..],
			&code,
			decoded_context_map,
			allocator,
		);
		try br.jumpToByteBoundary();
		try br.close();

		for (source.channels.items, image.channels.items) |want, got| {
			for (0..group_rect.rect.ysize()) |y| {
				try testing.expectEqualSlices(
					i32,
					want.rowConst(group_rect.rect.y0() + y)[group_rect.rect.x0() .. group_rect.rect.x0() + group_rect.rect.xsize()],
					got.rowConst(y),
				);
			}
		}
	}
}

test "writeGlobalTreeGroupImageRectWPRefs round-trips weighted reference-property tokens through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 3, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 20;
	source.channels.items[0].row(1)[1] = 0;
	source.channels.items[0].row(1)[2] = 20;
	source.channels.items[0].row(2)[0] = 0;
	source.channels.items[0].row(2)[1] = 20;
	source.channels.items[0].row(2)[2] = 0;

	source.channels.items[1].row(0)[0] = 10;
	source.channels.items[1].row(0)[1] = 12;
	source.channels.items[1].row(0)[2] = 14;
	source.channels.items[1].row(1)[0] = 11;
	source.channels.items[1].row(1)[1] = 13;
	source.channels.items[1].row(1)[2] = 15;
	source.channels.items[1].row(2)[0] = 13;
	source.channels.items[1].row(2)[1] = 14;
	source.channels.items[1].row(2)[2] = 18;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .weighted, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .weighted, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_config = HybridUintConfig.init(8, 0, 0);

	const counts = try ans_common.createFlatHistogram(allocator, 256, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{ info, info };
	const uint_configs = [_]HybridUintConfig{ uint_config, uint_config };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeGlobalTreeGroupImageRectWPRefs(
		allocator,
		&source,
		Rect.init(0, 0, 3, 3),
		0,
		&global_tree,
		&infos,
		&context_map,
		&uint_configs,
		&writer,
	));
	try writer.zeroPadToByte();

	var code = blk: {
		var built = dec_ans.ANSCode.init(allocator);
		errdefer built.deinit();
		built.use_prefix_code = false;
		built.log_alpha_size = 8;
		built.alias_tables = try allocator.alloc(ans_common.AliasTable.Entry, 2 * (1 << 8));
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 8, built.alias_tables[0 .. (1 << 8)].ptr);
		try ans_common.initAliasTable(counts, ans_params.ans_log_tab_size, 8, built.alias_tables[(1 << 8) ..][0 .. (1 << 8)].ptr);
		built.uint_config = try allocator.alloc(HybridUintConfig, 2);
		built.uint_config[0] = uint_config;
		built.uint_config[1] = uint_config;
		break :blk built;
	};
	defer code.deinit();

	var image = try modular_image.Image.create(allocator, 3, 3, 8, 2);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		context_map[0..],
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeGlobalTreeGroupImageRectWPRefs round-trips with exact histogram metadata" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 3, 3, 8, 2);
	defer source.deinit();

	source.channels.items[0].row(0)[0] = 0;
	source.channels.items[0].row(0)[1] = 20;
	source.channels.items[0].row(0)[2] = 0;
	source.channels.items[0].row(1)[0] = 20;
	source.channels.items[0].row(1)[1] = 0;
	source.channels.items[0].row(1)[2] = 20;
	source.channels.items[0].row(2)[0] = 0;
	source.channels.items[0].row(2)[1] = 20;
	source.channels.items[0].row(2)[2] = 0;

	source.channels.items[1].row(0)[0] = 10;
	source.channels.items[1].row(0)[1] = 12;
	source.channels.items[1].row(0)[2] = 14;
	source.channels.items[1].row(1)[0] = 11;
	source.channels.items[1].row(1)[1] = 13;
	source.channels.items[1].row(1)[2] = 15;
	source.channels.items[1].row(2)[0] = 13;
	source.channels.items[1].row(2)[1] = 14;
	source.channels.items[1].row(2)[2] = 18;

	const ref_value_prop: i16 = @intCast(context_predict.kNumNonrefProperties + 1);
	const global_tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(ref_value_prop, 10, 1, 2),
		.{ .property = -1, .lchild = 1, .predictor = .weighted, .multiplier = 1 },
		.{ .property = -1, .lchild = 0, .predictor = .weighted, .multiplier = 1 },
	};
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.initDefault(),
		HybridUintConfig.initDefault(),
	};
	const group_rects = [_]GroupRect{
		.{ .group_id = 0, .rect = Rect.init(0, 0, 3, 3) },
	};

	var bundle = try buildGlobalTreeHistogramBundleWPRefs(
		allocator,
		&source,
		&group_rects,
		&global_tree,
		&context_map,
		&uint_configs,
		8,
	);
	defer bundle.deinit(allocator);

	var hist_writer = BitWriter.init(allocator);
	defer hist_writer.deinit();
	try enc_ans.writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		8,
		&hist_writer,
	);
	try hist_writer.zeroPadToByte();

	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	var hist_br = @import("../base/bit_reader.zig").BitReader.init(hist_writer.bytes());
	const decoded_context_map = try dec_ans.decodeHistograms(allocator, &hist_br, context_map.len, &code);
	defer allocator.free(decoded_context_map);
	try testing.expectEqualSlices(u8, bundle.context_map, decoded_context_map);
	try hist_br.close();

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	const extra_bits = try writeGlobalTreeGroupImageRectWPRefs(
		allocator,
		&source,
		Rect.init(0, 0, 3, 3),
		0,
		&global_tree,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try testing.expect(extra_bits > 0);
	try writer.zeroPadToByte();

	var image = try modular_image.Image.create(allocator, 3, 3, 8, 2);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		global_tree[0..],
		&code,
		decoded_context_map,
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeSingleNodeLocalTreeGroup round-trips a minimal zero pixel through modularDecode" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 1, 1, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 0;

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeLocalTreeGroup(
        allocator,
        &channel,
        .zero,
        &writer,
    ));
    try writer.zeroPadToByte();

    var image = try modular_image.Image.create(allocator, 1, 1, 8, 1);
    defer image.deinit();
    var header = @import("encoding.zig").GroupHeader{};
    defer header.deinit();
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    try @import("encoding.zig").modularDecode(
        &br,
        &image,
        &header,
        0,
        &options.ModularOptions{},
        null,
        null,
        null,
        allocator,
    );
    try br.jumpToByteBoundary();
    try br.close();

    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeSingleNodeLocalTreeGroup round-trips a small zero-predictor tile through modularDecode" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 2, 2, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 0;
    channel.row(0)[1] = 1;
    channel.row(1)[0] = 2;
    channel.row(1)[1] = 3;

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeLocalTreeGroup(
        allocator,
        &channel,
        .zero,
        &writer,
    ));
    try writer.zeroPadToByte();

    var image = try modular_image.Image.create(allocator, 2, 2, 8, 1);
    defer image.deinit();
    var header = @import("encoding.zig").GroupHeader{};
    defer header.deinit();
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    try @import("encoding.zig").modularDecode(
        &br,
        &image,
        &header,
        0,
        &options.ModularOptions{},
        null,
        null,
        null,
        allocator,
    );
    try br.jumpToByteBoundary();
    try br.close();

    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeSingleNodeLocalTreeGroup round-trips a small gradient tile through modularDecode" {
    const allocator = testing.allocator;
    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeLocalTreeGroup(
        allocator,
        &channel,
        .gradient,
        &writer,
    ));
    try writer.zeroPadToByte();

    var image = try modular_image.Image.create(allocator, 3, 3, 8, 1);
    defer image.deinit();
    var header = @import("encoding.zig").GroupHeader{};
    defer header.deinit();
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    try @import("encoding.zig").modularDecode(
        &br,
        &image,
        &header,
        0,
        &options.ModularOptions{},
        null,
        null,
        null,
        allocator,
    );
    try br.jumpToByteBoundary();
    try br.close();

    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeSingleNodeLocalTreeGroupImage round-trips a small RGB tile through modularDecode" {
    const allocator = testing.allocator;
    var source = try modular_image.Image.create(allocator, 3, 2, 8, 3);
    defer source.deinit();

    source.channels.items[0].row(0)[0] = 10;
    source.channels.items[0].row(0)[1] = 12;
    source.channels.items[0].row(0)[2] = 14;
    source.channels.items[0].row(1)[0] = 13;
    source.channels.items[0].row(1)[1] = 15;
    source.channels.items[0].row(1)[2] = 17;

    source.channels.items[1].row(0)[0] = 20;
    source.channels.items[1].row(0)[1] = 19;
    source.channels.items[1].row(0)[2] = 18;
    source.channels.items[1].row(1)[0] = 17;
    source.channels.items[1].row(1)[1] = 16;
    source.channels.items[1].row(1)[2] = 15;

    source.channels.items[2].row(0)[0] = 7;
    source.channels.items[2].row(0)[1] = 8;
    source.channels.items[2].row(0)[2] = 9;
    source.channels.items[2].row(1)[0] = 11;
    source.channels.items[2].row(1)[1] = 12;
    source.channels.items[2].row(1)[2] = 13;

    var writer = BitWriter.init(allocator);
    defer writer.deinit();
    try testing.expectEqual(@as(usize, 0), try writeSingleNodeLocalTreeGroupImage(
        allocator,
        &source,
        .gradient,
        &writer,
    ));
    try writer.zeroPadToByte();

    var image = try modular_image.Image.create(allocator, 3, 2, 8, 3);
    defer image.deinit();
    var header = @import("encoding.zig").GroupHeader{};
    defer header.deinit();
    var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
    try @import("encoding.zig").modularDecode(
        &br,
        &image,
        &header,
        0,
        &options.ModularOptions{},
        null,
        null,
        null,
        allocator,
    );
    try br.jumpToByteBoundary();
    try br.close();

    for (source.channels.items, image.channels.items) |want, got| {
        try testing.expectEqualSlices(i32, want.data, got.data);
    }
}

test "writeSingleNodeLocalTreeGroupImageRect round-trips a cropped RGB tile through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 4, 3, 8, 3);
	defer source.deinit();

	for (0..source.h) |y| {
		for (0..source.w) |x| {
			source.channels.items[0].row(y)[x] = @intCast(10 + x + y * 4);
			source.channels.items[1].row(y)[x] = @intCast(20 + x * 2 + y);
			source.channels.items[2].row(y)[x] = @intCast(30 + x + y * 3);
		}
	}

	const rect = Rect.init(1, 1, 2, 2);
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeSingleNodeLocalTreeGroupImageRect(
		allocator,
		&source,
		rect,
		.gradient,
		&writer,
	));
	try writer.zeroPadToByte();

	var image = try modular_image.Image.create(allocator, rect.xsize(), rect.ysize(), 8, 3);
	defer image.deinit();
	var header = @import("encoding.zig").GroupHeader{};
	defer header.deinit();
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try @import("encoding.zig").modularDecode(
		&br,
		&image,
		&header,
		0,
		&options.ModularOptions{},
		null,
		null,
		null,
		allocator,
	);
	try br.jumpToByteBoundary();
	try br.close();

	for (source.channels.items, image.channels.items) |want, got| {
		for (0..rect.ysize()) |y| {
			try testing.expectEqualSlices(
				i32,
				want.rowConst(rect.y0() + y)[rect.x0() .. rect.x0() + rect.xsize()],
				got.rowConst(y),
			);
		}
	}
}

test "writeSingleNodeLocalTreeGroupImageRectWithCache round-trips cropped RGB tiles through modularDecode" {
	const allocator = testing.allocator;
	var source = try modular_image.Image.create(allocator, 6, 4, 8, 3);
	defer source.deinit();

	for (0..source.h) |y| {
		for (0..source.w) |x| {
			source.channels.items[0].row(y)[x] = @intCast(10 + x + y * 6);
			source.channels.items[1].row(y)[x] = @intCast(20 + x * 3 + y);
			source.channels.items[2].row(y)[x] = @intCast(30 + x + y * 4);
		}
	}

	var cache = FlatHistogramInfoCache.init(allocator);
	defer cache.deinit();

	const rects = [_]Rect{
		Rect.init(0, 0, 3, 2),
		Rect.init(3, 0, 3, 2),
		Rect.init(0, 2, 3, 2),
	};

	for (rects) |rect| {
		var writer = BitWriter.init(allocator);
		defer writer.deinit();
		_ = try writeSingleNodeLocalTreeGroupImageRectWithCache(
			allocator,
			&source,
			rect,
			.gradient,
			&cache,
			&writer,
		);
		try writer.zeroPadToByte();

		var image = try modular_image.Image.create(allocator, rect.xsize(), rect.ysize(), 8, 3);
		defer image.deinit();
		var header = @import("encoding.zig").GroupHeader{};
		defer header.deinit();
		var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
		try @import("encoding.zig").modularDecode(
			&br,
			&image,
			&header,
			0,
			&options.ModularOptions{},
			null,
			null,
			null,
			allocator,
		);
		try br.jumpToByteBoundary();
		try br.close();

		for (source.channels.items, image.channels.items) |want, got| {
			for (0..rect.ysize()) |y| {
				try testing.expectEqualSlices(
					i32,
					want.rowConst(rect.y0() + y)[rect.x0() .. rect.x0() + rect.xsize()],
					got.rowConst(y),
				);
			}
		}
	}
}
