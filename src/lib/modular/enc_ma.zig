// Encoder-side MA tree helpers.
// Starts with the smallest real tree: a single leaf node.

const std = @import("std");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const enc_context_map = @import("../entropy/enc_context_map.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const pack_signed = @import("../base/pack_signed.zig");
const dec_ma = @import("dec_ma.zig");
const ma_common = @import("ma_common.zig");
const options = @import("options.zig");

const Predictor = options.Predictor;
const Token = enc_ans.Token;

const TreeHistogramConfig = struct {
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	alphabet_size: u32,
};

/// Mirrors upstream `TokenizeTree`: breadth-first MA-tree tokenization that also
/// rebuilds the decoder-visible node layout with leaf IDs and implicit child indices.
pub fn tokenizeTree(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	tokens: *std.ArrayList(Token),
	decoder_tree: *dec_ma.Tree,
) !void {
	if (tree.len == 0 or tree.len > ma_common.kMaxTreeSize) return error.GenericError;

	var queue: std.ArrayList(usize) = .empty;
	defer queue.deinit(allocator);
	try queue.append(allocator, 0);
	var queue_head: usize = 0;
	var leaf_id: u32 = 0;
	decoder_tree.clearRetainingCapacity();

	while (queue_head < queue.items.len) {
		const cur = queue.items[queue_head];
		queue_head += 1;
		if (cur >= tree.len) return error.GenericError;

		const node = tree[cur];
		if (node.property < -1) return error.GenericError;
		try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.property), @intCast(node.property + 1)));

		if (node.property == -1) {
			if (@intFromEnum(node.predictor) >= options.kNumModularPredictors) return error.GenericError;
			if (node.predictor_offset < std.math.minInt(i32) or node.predictor_offset > std.math.maxInt(i32)) {
				return error.Unsupported;
			}
			if (node.multiplier == 0) return error.GenericError;

			try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.predictor), @intCast(@intFromEnum(node.predictor))));
			try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.offset), pack_signed.packSigned(@intCast(node.predictor_offset))));

			const mul_log: u32 = @ctz(node.multiplier);
			const mul_bits: u32 = (node.multiplier >> @intCast(mul_log)) - 1;
			try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.multiplier_log), mul_log));
			try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.multiplier_bits), mul_bits));

			try decoder_tree.append(allocator, .{
				.property = -1,
				.splitval = 0,
				.lchild = leaf_id,
				.rchild = 0,
				.predictor = node.predictor,
				.predictor_offset = node.predictor_offset,
				.multiplier = node.multiplier,
			});
			leaf_id += 1;
			continue;
		}

		const queue_remaining = queue.items.len - queue_head;
		try decoder_tree.append(allocator, .{
			.property = node.property,
			.splitval = node.splitval,
			.lchild = @intCast(decoder_tree.items.len + queue_remaining + 1),
			.rchild = @intCast(decoder_tree.items.len + queue_remaining + 2),
			.predictor = .zero,
			.predictor_offset = 0,
			.multiplier = 1,
		});
		try queue.append(allocator, node.lchild);
		try queue.append(allocator, node.rchild);
		try tokens.append(allocator, Token.init(@intFromEnum(ma_common.MATreeContext.split_val), pack_signed.packSigned(node.splitval)));
	}
}

/// Rebuilds a tree into the decoder-visible layout where leaf context IDs are
/// implicit breadth-first leaf numbers. Encoder callers use this canonical form
/// whenever later tokenization must agree with the tree bytes emitted by writeTree.
pub fn canonicalizeTree(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
) !dec_ma.Tree {
	var tokens: std.ArrayList(Token) = .empty;
	defer tokens.deinit(allocator);
	var decoder_tree: dec_ma.Tree = .empty;
	errdefer decoder_tree.deinit(allocator);
	try tokenizeTree(allocator, tree, &tokens, &decoder_tree);
	return decoder_tree;
}

fn selectTreeHistogramConfig(tokens: []const Token) !TreeHistogramConfig {
	var max_value: u32 = 0;
	for (tokens) |token| {
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

/// Writes a general MA tree using the same single shared histogram/context-map
/// shape we already support, while translating upstream tree-token order exactly.
pub fn writeTree(
	allocator: std.mem.Allocator,
	tree: []const dec_ma.PropertyDecisionNode,
	writer: *BitWriter,
) !void {
	var tokens: std.ArrayList(Token) = .empty;
	defer tokens.deinit(allocator);
	var decoder_tree: dec_ma.Tree = .empty;
	defer decoder_tree.deinit(allocator);
	try tokenizeTree(allocator, tree, &tokens, &decoder_tree);
	if (tokens.items.len == 0) return error.GenericError;

	const cfg = try selectTreeHistogramConfig(tokens.items);

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeSimpleAllZeroContextMap(ma_common.kNumTreeContexts, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, cfg.log_alpha_size - 5);
	try enc_ans.encodeUintConfig(cfg.uint_config, writer, cfg.log_alpha_size);
	try writer.write(1, 0); // histogram simple_code = false
	try writer.write(1, 1); // is_flat = true
	try enc_ans.storeVarLenUint8(@intCast(cfg.alphabet_size - 1), writer);

	const counts = try ans_common.createFlatHistogram(allocator, cfg.alphabet_size, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, cfg.log_alpha_size);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);

	const single_hist_tokens = try allocator.alloc(Token, tokens.items.len);
	defer allocator.free(single_hist_tokens);
	for (tokens.items, 0..) |token, i| {
		single_hist_tokens[i] = Token.init(0, token.value);
	}
	_ = try enc_ans.writeSingleHistogramTokens(single_hist_tokens, info, cfg.uint_config, writer);
}

/// Emits the smallest MA tree bitstream shape: a single leaf with zero offset
/// and multiplier 1. This is now a thin wrapper over the general tree writer.
pub fn writeSingleLeafTree(
	allocator: std.mem.Allocator,
	predictor: Predictor,
	writer: *BitWriter,
) !void {
	std.debug.assert(@intFromEnum(predictor) < options.kNumModularPredictors);
	const tree = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.leaf(predictor, 0, 1),
	};
	try writeTree(allocator, &tree, writer);
}

const testing = std.testing;

test "writeSingleLeafTree round-trips through dec_ma.decodeTree" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleLeafTree(allocator, .gradient, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var tree: dec_ma.Tree = .empty;
	defer tree.deinit(allocator);
	try dec_ma.decodeTree(allocator, &br, &tree, 16);
	try testing.expectEqual(@as(usize, 1), tree.items.len);
	try testing.expectEqual(@as(i16, -1), tree.items[0].property);
	try testing.expectEqual(Predictor.gradient, tree.items[0].predictor);
	try testing.expectEqual(@as(i64, 0), tree.items[0].predictor_offset);
	try testing.expectEqual(@as(u32, 1), tree.items[0].multiplier);
	try testing.expectEqual(@as(u32, 0), tree.items[0].lchild);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeTree round-trips a split tree through dec_ma.decodeTree" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();

	const source = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(3, 42, 1, 2),
		dec_ma.PropertyDecisionNode.leaf(.left, 0, 1),
		dec_ma.PropertyDecisionNode.leaf(.gradient, 5, 2),
	};
	try writeTree(allocator, &source, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var tree: dec_ma.Tree = .empty;
	defer tree.deinit(allocator);
	try dec_ma.decodeTree(allocator, &br, &tree, 16);
	try testing.expectEqual(@as(usize, 3), tree.items.len);
	try testing.expectEqual(@as(i16, 3), tree.items[0].property);
	try testing.expectEqual(@as(i32, 42), tree.items[0].splitval);
	try testing.expectEqual(@as(u32, 1), tree.items[0].lchild);
	try testing.expectEqual(@as(u32, 2), tree.items[0].rchild);
	try testing.expectEqual(Predictor.left, tree.items[1].predictor);
	try testing.expectEqual(@as(u32, 0), tree.items[1].lchild);
	try testing.expectEqual(Predictor.gradient, tree.items[2].predictor);
	try testing.expectEqual(@as(i64, 5), tree.items[2].predictor_offset);
	try testing.expectEqual(@as(u32, 2), tree.items[2].multiplier);
	try testing.expectEqual(@as(u32, 1), tree.items[2].lchild);
	try br.jumpToByteBoundary();
	try br.close();
}

test "canonicalizeTree renumbers leaf contexts to decoder breadth-first order" {
	const allocator = testing.allocator;
	const source = [_]dec_ma.PropertyDecisionNode{
		dec_ma.PropertyDecisionNode.split(3, 42, 1, 2),
		.{ .property = -1, .lchild = 7, .predictor = .left, .multiplier = 1 },
		.{ .property = -1, .lchild = 3, .predictor = .gradient, .predictor_offset = 5, .multiplier = 2 },
	};

	var tree = try canonicalizeTree(allocator, &source);
	defer tree.deinit(allocator);

	try testing.expectEqual(@as(usize, 3), tree.items.len);
	try testing.expectEqual(@as(u32, 1), tree.items[0].lchild);
	try testing.expectEqual(@as(u32, 2), tree.items[0].rchild);
	try testing.expectEqual(@as(u32, 0), tree.items[1].lchild);
	try testing.expectEqual(@as(u32, 1), tree.items[2].lchild);
}
