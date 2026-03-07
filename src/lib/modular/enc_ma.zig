// Encoder-side MA tree helpers.
// Starts with the smallest real tree: a single leaf node.

const std = @import("std");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const enc_context_map = @import("../entropy/enc_context_map.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const dec_ma = @import("dec_ma.zig");
const ma_common = @import("ma_common.zig");
const options = @import("options.zig");

const Predictor = options.Predictor;
const Token = enc_ans.Token;

/// Emits the smallest MA tree bitstream shape: a single leaf with zero offset
/// and multiplier 1, using one shared histogram across all tree contexts.
pub fn writeSingleLeafTree(
	allocator: std.mem.Allocator,
	predictor: Predictor,
	writer: *BitWriter,
) !void {
	std.debug.assert(@intFromEnum(predictor) < options.kNumModularPredictors);

	const log_alpha_size: u5 = 5;
	const uint_config = HybridUintConfig.init(log_alpha_size, 0, 0);
	const predictor_symbol: u8 = @intCast(@intFromEnum(predictor));

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeSimpleAllZeroContextMap(ma_common.kNumTreeContexts, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try enc_ans.encodeUintConfig(uint_config, writer, log_alpha_size);

	try writer.write(1, 1); // histogram simple_code = true
	if (predictor_symbol == 0) {
		try writer.write(1, 0); // num_symbols = 1
		try enc_ans.storeVarLenUint8(0, writer);
	} else {
		try writer.write(1, 1); // num_symbols = 2
		try enc_ans.storeVarLenUint8(0, writer);
		try enc_ans.storeVarLenUint8(predictor_symbol, writer);
		try writer.write(ans_params.ans_log_tab_size, ans_params.ans_tab_size / 2);
	}

	const counts = try allocator.alloc(i32, @as(usize, predictor_symbol) + 1);
	defer allocator.free(counts);
	@memset(counts, 0);
	if (predictor_symbol == 0) {
		counts[0] = @intCast(ans_params.ans_tab_size);
	} else {
		counts[0] = @intCast(ans_params.ans_tab_size / 2);
		counts[predictor_symbol] = @intCast(ans_params.ans_tab_size / 2);
	}

	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, log_alpha_size);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);

	const tokens = [_]Token{
		Token.init(0, 0),                // property => leaf
		Token.init(0, predictor_symbol), // predictor
		Token.init(0, 0),                // offset
		Token.init(0, 0),                // multiplier_log
		Token.init(0, 0),                // multiplier_bits
	};
	_ = try enc_ans.writeSingleHistogramTokens(&tokens, info, uint_config, writer);
}

const testing = std.testing;

test "writeSingleLeafTree round-trips through dec_ma.decodeTree" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleLeafTree(allocator, .gradient, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var tree: dec_ma.Tree = .{};
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
