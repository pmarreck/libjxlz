// Minimal modular encoder tokenization helpers.
// Starts with the smallest grayscale slice: single-node predictor tokenization.

const std = @import("std");
const common = @import("../base/common.zig");
const pack_signed = @import("../base/pack_signed.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const context_predict = @import("context_predict.zig");
const enc_ma = @import("enc_ma.zig");
const modular_image = @import("modular_image.zig");
const options = @import("options.zig");
const Rect = @import("../base/rect.zig").Rect;

const Channel = modular_image.Channel;
const Predictor = options.Predictor;
const pixel_type_w = options.pixel_type_w;
const Token = enc_ans.Token;

const LocalHistogramConfig = struct {
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	alphabet_size: u32,
};

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

	try writer.write(1, 0); // use_global_tree = false
	try writer.write(1, 1); // weighted header all-default
	try writer.write(2, 0); // num_transforms = 0 via selector 0
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
	if (image.channels.items.len == 0) return error.GenericError;

	var tokens: std.ArrayList(Token) = .{};
	defer tokens.deinit(allocator);

	for (image.channels.items) |*channel| {
		const channel_tokens = try tokenizeSingleNodeChannelRect(allocator, channel, rect, predictor, 0);
		defer allocator.free(channel_tokens);
		try tokens.appendSlice(allocator, channel_tokens);
	}

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
