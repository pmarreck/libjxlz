// Minimal modular encoder tokenization helpers.
// Starts with the smallest grayscale slice: single-node predictor tokenization.

const std = @import("std");
const pack_signed = @import("../base/pack_signed.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
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
