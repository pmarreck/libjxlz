// Minimal modular encoder tokenization helpers.
// Starts with the smallest grayscale slice: single-node predictor tokenization.

const std = @import("std");
const pack_signed = @import("../base/pack_signed.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const context_predict = @import("context_predict.zig");
const modular_image = @import("modular_image.zig");
const options = @import("options.zig");

const Channel = modular_image.Channel;
const Predictor = options.Predictor;
const pixel_type_w = options.pixel_type_w;
const Token = enc_ans.Token;

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
