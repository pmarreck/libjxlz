// Encoder-side ANS helpers.
// Starts with the smallest real entropy-writing slice: HybridUintConfig encoding.

const std = @import("std");
const params = @import("ans_params.zig");
const ans_common = @import("ans_common.zig");
const AliasTable = ans_common.AliasTable;
const bits_mod = @import("../base/bits.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const HybridUintConfig = @import("hybrid_uint.zig").HybridUintConfig;
const dec_ans = @import("dec_ans.zig");

const reciprocal_precision: u6 = 32 + @as(u6, params.ans_log_tab_size);

pub const SizeWriter = struct {
	size: usize = 0,

	pub fn write(self: *SizeWriter, n_bits: usize, bits: anytype) !void {
		_ = bits;
		self.size += n_bits;
	}
};

pub const Token = struct {
	is_lz77_length: bool = false,
	context: u32,
	value: u32,

	pub fn init(context: u32, value: u32) Token {
		return .{
			.context = context,
			.value = value,
		};
	}
};

pub const ANSEncSymbolInfo = struct {
	freq: u16 = 0,
	reverse_map: []u16 = &.{},
	ifreq: u64 = 1,
	depth: u8 = 0,
	bits: u16 = 0,
};

pub const ANSCoder = struct {
	state: u32 = params.ans_signature << 16,

	pub const PutResult = struct {
		bits: u32,
		nbits: u8,
	};

	/// Advances the ANS encoder state for one already-tokenized symbol, using
	/// the reciprocal-frequency form so later token writing matches libjxl.
	pub fn putSymbol(self: *ANSCoder, info: *const ANSEncSymbolInfo) PutResult {
		const renorm_shift: u6 = 32 - @as(u6, params.ans_log_tab_size);
		var emitted_bits: u32 = 0;
		var emitted_nbits: u8 = 0;
		if ((self.state >> renorm_shift) >= info.freq) {
			emitted_bits = self.state & 0xffff;
			self.state >>= 16;
			emitted_nbits = 16;
		}

		const v: u32 = @intCast((@as(u64, self.state) * info.ifreq) >> reciprocal_precision);
		const offset = info.reverse_map[self.state - v * info.freq];
		self.state = (v << params.ans_log_tab_size) + offset;
		return .{ .bits = emitted_bits, .nbits = emitted_nbits };
	}

	pub fn getState(self: *const ANSCoder) u32 {
		return self.state;
	}
};

pub fn buildANSEncSymbolInfoTable(
	allocator: std.mem.Allocator,
	counts: []const i32,
	log_alpha_size: u5,
) ![]ANSEncSymbolInfo {
	const info_len = @max(@as(usize, 1), counts.len);
	const info = try allocator.alloc(ANSEncSymbolInfo, info_len);
	errdefer allocator.free(info);
	for (info) |*entry| entry.* = .{};

	const table_size = @as(usize, 1) << log_alpha_size;
	const table = try allocator.alloc(AliasTable.Entry, table_size);
	defer allocator.free(table);

	try ans_common.initAliasTable(counts, params.ans_log_tab_size, log_alpha_size, table.ptr);

	for (0..info_len) |symbol| {
		const freq: u16 = if (counts.len == 0)
			(if (symbol == 0) @intCast(params.ans_tab_size) else 0)
		else if (symbol < counts.len)
			@intCast(counts[symbol])
		else
			0;
		info[symbol].freq = freq;
		info[symbol].ifreq = if (freq != 0)
			((@as(u64, 1) << reciprocal_precision) + freq - 1) / freq
		else
			1;
		info[symbol].reverse_map = if (freq != 0) try allocator.alloc(u16, freq) else &.{};
	}

	const log_entry_size = params.ans_log_tab_size - log_alpha_size;
	const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
	for (0..params.ans_tab_size) |i| {
		const symbol = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
		info[symbol.value].reverse_map[symbol.offset] = @intCast(i);
	}

	return info;
}

pub fn freeANSEncSymbolInfoTable(allocator: std.mem.Allocator, info: []ANSEncSymbolInfo) void {
	for (info) |entry| {
		if (entry.reverse_map.len != 0) allocator.free(entry.reverse_map);
	}
	allocator.free(info);
}

/// Packs reversed ANS/extra-bit chunks into a forward bitstream order suitable
/// for `BitWriter`, matching libjxl's `WriteTokens` buffering discipline.
fn addReversedBits(
	out: *std.ArrayList(u64),
	out_nbits: *std.ArrayList(u8),
	allbits: *u64,
	numallbits: *usize,
	bits: u64,
	nbits: usize,
	allocator: std.mem.Allocator,
) !void {
	if (nbits == 0) return;
	std.debug.assert(bits >> @intCast(nbits) == 0);
	if (numallbits.* + nbits > BitWriter.kMaxBitsPerCall) {
		try out.append(allocator, allbits.*);
		try out_nbits.append(allocator, @intCast(numallbits.*));
		allbits.* = 0;
		numallbits.* = 0;
	}
	allbits.* <<= @intCast(nbits);
	allbits.* |= bits;
	numallbits.* += nbits;
}

pub fn writeSingleHistogramTokens(
	tokens: []const Token,
	info: []const ANSEncSymbolInfo,
	uint_config: HybridUintConfig,
	writer: *BitWriter,
) !usize {
	var out: std.ArrayList(u64) = .{};
	defer out.deinit(writer.allocator);
	var out_nbits: std.ArrayList(u8) = .{};
	defer out_nbits.deinit(writer.allocator);

	var allbits: u64 = 0;
	var numallbits: usize = 0;
	var num_extra_bits: usize = 0;
	var ans = ANSCoder{};

	var i = tokens.len;
	while (i > 0) {
		i -= 1;
		const token = tokens[i];
		std.debug.assert(!token.is_lz77_length);
		std.debug.assert(token.context == 0);

		const encoded = uint_config.encode(token.value);
		try addReversedBits(&out, &out_nbits, &allbits, &numallbits, encoded.bits, encoded.nbits, writer.allocator);
		num_extra_bits += encoded.nbits;

		const ans_bits = ans.putSymbol(&info[encoded.token]);
		try addReversedBits(&out, &out_nbits, &allbits, &numallbits, ans_bits.bits, ans_bits.nbits, writer.allocator);
	}

	try writer.write(32, ans.getState());
	try writer.write(numallbits, allbits);
	var chunk_index = out.items.len;
	while (chunk_index > 0) {
		chunk_index -= 1;
		try writer.write(out_nbits.items[chunk_index], out.items[chunk_index]);
	}
	return num_extra_bits;
}

pub fn encodeUintConfig(cfg: HybridUintConfig, writer: anytype, log_alpha_size: u5) !void {
	try writer.write(bits_mod.ceilLog2Nonzero(@as(u32, log_alpha_size) + 1), cfg.split_exponent);
	if (cfg.split_exponent == log_alpha_size) return;

	var nbits = bits_mod.ceilLog2Nonzero(cfg.split_exponent + 1);
	try writer.write(nbits, cfg.msb_in_token);
	nbits = bits_mod.ceilLog2Nonzero(cfg.split_exponent - cfg.msb_in_token + 1);
	try writer.write(nbits, cfg.lsb_in_token);
}

pub fn encodeUintConfigs(configs: []const HybridUintConfig, writer: anytype, log_alpha_size: u5) !void {
	for (configs) |cfg| {
		try encodeUintConfig(cfg, writer, log_alpha_size);
	}
}

/// Encodes a compact variable-length integer in the range [0..255].
/// Mirrors libjxl's histogram-header format so small counts stay very cheap to write.
pub fn storeVarLenUint8(value: u8, writer: anytype) !void {
	if (value == 0) {
		try writer.write(1, 0);
		return;
	}

	try writer.write(1, 1);
	const nbits = bits_mod.floorLog2Nonzero(value);
	try writer.write(3, nbits);
	if (nbits != 0) {
		try writer.write(nbits, value - (@as(u8, 1) << @intCast(nbits)));
	}
}

/// Encodes a compact variable-length integer in the range [0..65535].
/// This is the wider companion to `storeVarLenUint8` for histogram alphabet sizes.
pub fn storeVarLenUint16(value: u16, writer: anytype) !void {
	if (value == 0) {
		try writer.write(1, 0);
		return;
	}

	try writer.write(1, 1);
	const nbits = bits_mod.floorLog2Nonzero(value);
	try writer.write(4, nbits);
	if (nbits != 0) {
		try writer.write(nbits, value - (@as(u16, 1) << @intCast(nbits)));
	}
}

/// Emits the smallest histogram bundle `decodeHistograms` can read: one
/// context, ANS mode, one uint config, and a degenerate single-symbol histogram.
pub fn writeSingleContextDegenerateHistogram(
	degenerate_symbol: u8,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(log_alpha_size >= 5 and log_alpha_size <= 8);
	try writer.write(1, 0); // LZ77 disabled
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfig(uint_config, writer, log_alpha_size);

	try writer.write(1, 1); // histogram simple_code = true
	try writer.write(1, 0); // num_symbols = 1
	try storeVarLenUint8(degenerate_symbol, writer);
}

/// Emits the smallest non-degenerate histogram bundle `decodeHistograms` can
/// read: one context, ANS mode, one uint config, and a simple two-symbol code.
pub fn writeSingleContextTwoSymbolHistogram(
	symbol0: u8,
	symbol1: u8,
	count0: u16,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(symbol0 != symbol1);
	std.debug.assert(log_alpha_size >= 5 and log_alpha_size <= 8);
	std.debug.assert(count0 > 0 and count0 < params.ans_tab_size);
	try writer.write(1, 0); // LZ77 disabled
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfig(uint_config, writer, log_alpha_size);

	try writer.write(1, 1); // histogram simple_code = true
	try writer.write(1, 1); // num_symbols = 2
	try storeVarLenUint8(symbol0, writer);
	try storeVarLenUint8(symbol1, writer);
	try writer.write(params.ans_log_tab_size, count0);
}

const testing = std.testing;

test "encodeUintConfigs round-trips a mixed config set" {
	const log_alpha_size: u5 = 8;
	const original = [_]HybridUintConfig{
		HybridUintConfig.init(0, 0, 0),
		HybridUintConfig.init(3, 1, 0),
		HybridUintConfig.init(4, 2, 1),
		HybridUintConfig.init(5, 1, 2),
		HybridUintConfig.init(log_alpha_size, 0, 0),
	};

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try encodeUintConfigs(&original, &writer, log_alpha_size);
	try writer.zeroPadToByte();

	var decoded: [original.len]HybridUintConfig = undefined;
	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try dec_ans.decodeUintConfigs(log_alpha_size, &decoded, &reader);
	try reader.close();

	for (original, decoded) |want, got| {
		try testing.expectEqual(want.split_exponent, got.split_exponent);
		try testing.expectEqual(want.msb_in_token, got.msb_in_token);
		try testing.expectEqual(want.lsb_in_token, got.lsb_in_token);
	}
}

test "encodeUintConfig omits msb/lsb fields at max split exponent" {
	const log_alpha_size: u5 = 6;
	const original = [_]HybridUintConfig{
		HybridUintConfig.init(log_alpha_size, 0, 0),
		HybridUintConfig.init(2, 1, 0),
	};

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try encodeUintConfigs(&original, &writer, log_alpha_size);
	try writer.zeroPadToByte();

	var decoded: [original.len]HybridUintConfig = undefined;
	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try dec_ans.decodeUintConfigs(log_alpha_size, &decoded, &reader);
	try reader.close();

	try testing.expectEqual(original[0].split_exponent, decoded[0].split_exponent);
	try testing.expectEqual(original[1].split_exponent, decoded[1].split_exponent);
	try testing.expectEqual(original[1].msb_in_token, decoded[1].msb_in_token);
	try testing.expectEqual(original[1].lsb_in_token, decoded[1].lsb_in_token);
}

test "encodeUintConfigs exhaustively round-trips valid configs through decoder" {
	inline for (5..9) |log_alpha_size_usize| {
		const log_alpha_size: u5 = @intCast(log_alpha_size_usize);
		var original: std.ArrayList(HybridUintConfig) = .{};
		defer original.deinit(testing.allocator);

		for (0..log_alpha_size) |split_exponent_usize| {
			const split_exponent: u32 = @intCast(split_exponent_usize);
			for (0..split_exponent + 1) |msb_in_token_usize| {
				const msb_in_token: u32 = @intCast(msb_in_token_usize);
				for (0..(split_exponent - msb_in_token) + 1) |lsb_in_token_usize| {
					const lsb_in_token: u32 = @intCast(lsb_in_token_usize);
					try original.append(testing.allocator, HybridUintConfig.init(split_exponent, msb_in_token, lsb_in_token));
				}
			}
		}
		try original.append(testing.allocator, HybridUintConfig.init(log_alpha_size, 0, 0));

		var writer = BitWriter.init(testing.allocator);
		defer writer.deinit();
		try encodeUintConfigs(original.items, &writer, log_alpha_size);
		try writer.zeroPadToByte();

		const decoded = try testing.allocator.alloc(HybridUintConfig, original.items.len);
		defer testing.allocator.free(decoded);
		var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
		try dec_ans.decodeUintConfigs(log_alpha_size, decoded, &reader);
		try reader.close();

		for (original.items, decoded) |want, got| {
			try testing.expectEqual(want.split_exponent, got.split_exponent);
			try testing.expectEqual(want.msb_in_token, got.msb_in_token);
			try testing.expectEqual(want.lsb_in_token, got.lsb_in_token);
		}
	}
}

test "storeVarLenUint8 exhaustively round-trips through decoder helper" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	for (0..256) |value| {
		try storeVarLenUint8(@intCast(value), &writer);
	}
	try writer.zeroPadToByte();

	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	for (0..256) |value| {
		try testing.expectEqual(@as(u32, @intCast(value)), dec_ans.decodeVarLenUint8(&reader));
	}
	try reader.close();
}

test "storeVarLenUint16 exhaustively round-trips through decoder helper" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	for (0..65536) |value| {
		try storeVarLenUint16(@intCast(value), &writer);
	}
	try writer.zeroPadToByte();

	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	for (0..65536) |value| {
		try testing.expectEqual(@as(u32, @intCast(value)), dec_ans.decodeVarLenUint16(&reader));
	}
	try reader.close();
}

test "writeSingleContextDegenerateHistogram round-trips through decodeHistograms" {
	const allocator = testing.allocator;
	const want_cfg = HybridUintConfig.init(5, 0, 0);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleContextDegenerateHistogram(5, want_cfg, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, 1, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 1), context_map.len);
	try testing.expectEqual(@as(u8, 0), context_map[0]);
	try testing.expect(!code.use_prefix_code);
	try testing.expectEqual(@as(u5, 5), code.log_alpha_size);
	try testing.expectEqual(@as(usize, 1), code.uint_config.len);
	try testing.expectEqual(want_cfg.split_exponent, code.uint_config[0].split_exponent);
	try testing.expectEqual(want_cfg.msb_in_token, code.uint_config[0].msb_in_token);
	try testing.expectEqual(want_cfg.lsb_in_token, code.uint_config[0].lsb_in_token);
	try testing.expectEqual(@as(usize, 1), code.degenerate_symbols.len);
	try testing.expectEqual(@as(i32, 5), code.degenerate_symbols[0]);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSingleContextTwoSymbolHistogram round-trips exact recovered counts through decodeHistograms" {
	const allocator = testing.allocator;
	const want_cfg = HybridUintConfig.init(5, 0, 0);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleContextTwoSymbolHistogram(0, 5, 2048, want_cfg, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, 1, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 1), context_map.len);
	try testing.expectEqual(@as(u8, 0), context_map[0]);
	try testing.expect(!code.use_prefix_code);
	try testing.expectEqual(@as(u5, 5), code.log_alpha_size);
	try testing.expectEqual(@as(i32, -1), code.degenerate_symbols[0]);

	var recovered = [_]usize{0} ** 6;
	const table = code.alias_tables[0 .. (@as(usize, 1) << code.log_alpha_size)];
	const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
	const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
	for (0..params.ans_tab_size) |i| {
		const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
		recovered[sym.value] += 1;
	}

	try testing.expectEqual(@as(usize, 2048), recovered[0]);
	try testing.expectEqual(@as(usize, 2048), recovered[5]);
	try testing.expectEqual(@as(usize, 0), recovered[1]);
	try testing.expectEqual(@as(usize, 0), recovered[2]);
	try testing.expectEqual(@as(usize, 0), recovered[3]);
	try testing.expectEqual(@as(usize, 0), recovered[4]);
	try br.jumpToByteBoundary();
	try br.close();
}

test "SizeWriter matches BitWriter bit count for varlen integers" {
	var bit_writer = BitWriter.init(testing.allocator);
	defer bit_writer.deinit();
	var size_writer = SizeWriter{};

	for (0..256) |value| {
		try storeVarLenUint8(@intCast(value), &bit_writer);
		try storeVarLenUint8(@intCast(value), &size_writer);
	}
	for (0..1024) |value| {
		try storeVarLenUint16(@intCast(value), &bit_writer);
		try storeVarLenUint16(@intCast(value), &size_writer);
	}

	try testing.expectEqual(bit_writer.bitsWritten(), size_writer.size);
}

test "SizeWriter matches BitWriter bit count for uint configs" {
	const log_alpha_size: u5 = 8;
	const configs = [_]HybridUintConfig{
		HybridUintConfig.init(0, 0, 0),
		HybridUintConfig.init(3, 1, 0),
		HybridUintConfig.init(4, 2, 1),
		HybridUintConfig.init(5, 1, 2),
		HybridUintConfig.init(log_alpha_size, 0, 0),
	};

	var bit_writer = BitWriter.init(testing.allocator);
	defer bit_writer.deinit();
	var size_writer = SizeWriter{};

	try encodeUintConfigs(&configs, &bit_writer, log_alpha_size);
	try encodeUintConfigs(&configs, &size_writer, log_alpha_size);

	try testing.expectEqual(bit_writer.bitsWritten(), size_writer.size);
}

fn putSymbolReference(state: u32, info: ANSEncSymbolInfo) struct { state: u32, bits: u32, nbits: u8 } {
	const renorm_shift: u6 = 32 - @as(u6, params.ans_log_tab_size);
	var next_state = state;
	var bits: u32 = 0;
	var nbits: u8 = 0;
	if ((next_state >> renorm_shift) >= info.freq) {
		bits = next_state & 0xffff;
		next_state >>= 16;
		nbits = 16;
	}
	const v: u32 = next_state / info.freq;
	const offset = info.reverse_map[next_state - v * info.freq];
	next_state = (v << params.ans_log_tab_size) + offset;
	return .{ .state = next_state, .bits = bits, .nbits = nbits };
}

test "Token.init defaults to non-LZ77 token" {
	const token = Token.init(7, 11);
	try testing.expect(!token.is_lz77_length);
	try testing.expectEqual(@as(u32, 7), token.context);
	try testing.expectEqual(@as(u32, 11), token.value);
}

test "ANSCoder putSymbol matches reference division path" {
	const allocator = testing.allocator;
	const counts = [_]i32{ 2048, 1024, 1024 };
	const info = try buildANSEncSymbolInfoTable(allocator, &counts, 2);
	defer freeANSEncSymbolInfoTable(allocator, info);

	var coder = ANSCoder{};
	const sequence = [_]usize{ 0, 1, 2, 0, 2, 1, 0, 0, 2, 1, 2, 0, 1, 1, 2, 0 };
	var reference_state: u32 = params.ans_signature << 16;

	for (sequence) |symbol| {
		const reference = putSymbolReference(reference_state, info[symbol]);
		const got = coder.putSymbol(&info[symbol]);
		try testing.expectEqual(reference.bits, got.bits);
		try testing.expectEqual(reference.nbits, got.nbits);
		reference_state = reference.state;
		try testing.expectEqual(reference_state, coder.getState());
	}
}

test "buildANSEncSymbolInfoTable creates a valid empty-stream fallback symbol" {
	const allocator = testing.allocator;
	const info = try buildANSEncSymbolInfoTable(allocator, &.{}, 0);
	defer freeANSEncSymbolInfoTable(allocator, info);

	try testing.expectEqual(@as(usize, 1), info.len);
	try testing.expectEqual(@as(u16, @intCast(params.ans_tab_size)), info[0].freq);
	try testing.expectEqual(@as(usize, params.ans_tab_size), info[0].reverse_map.len);
}

fn buildSingleHistogramCode(
	allocator: std.mem.Allocator,
	counts: []const i32,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
) !dec_ans.ANSCode {
	var code = dec_ans.ANSCode.init(allocator);
	errdefer code.deinit();

	code.use_prefix_code = false;
	code.log_alpha_size = log_alpha_size;
	code.alias_tables = try allocator.alloc(AliasTable.Entry, @as(usize, 1) << log_alpha_size);
	try ans_common.initAliasTable(counts, params.ans_log_tab_size, log_alpha_size, code.alias_tables.ptr);
	code.uint_config = try allocator.alloc(HybridUintConfig, 1);
	code.uint_config[0] = uint_config;
	return code;
}

test "writeSingleHistogramTokens round-trips empty stream" {
	const allocator = testing.allocator;
	const uint_config = HybridUintConfig.init(0, 0, 0);
	const log_alpha_size: u5 = 5;
	const info = try buildANSEncSymbolInfoTable(allocator, &.{}, log_alpha_size);
	defer freeANSEncSymbolInfoTable(allocator, info);
	var code = try buildSingleHistogramCode(allocator, &.{}, uint_config, log_alpha_size);
	defer code.deinit();

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeSingleHistogramTokens(&.{}, info, uint_config, &writer));
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSingleHistogramTokens round-trips direct-token stream through ANSSymbolReader" {
	const allocator = testing.allocator;
	const counts = [_]i32{ 2048, 1024, 512, 512 };
	const log_alpha_size: u5 = 5;
	const uint_config = HybridUintConfig.init(2, 0, 0);
	const info = try buildANSEncSymbolInfoTable(allocator, &counts, log_alpha_size);
	defer freeANSEncSymbolInfoTable(allocator, info);
	var code = try buildSingleHistogramCode(allocator, &counts, uint_config, log_alpha_size);
	defer code.deinit();

	const tokens = [_]Token{
		Token.init(0, 0),
		Token.init(0, 1),
		Token.init(0, 2),
		Token.init(0, 3),
		Token.init(0, 0),
		Token.init(0, 2),
		Token.init(0, 1),
		Token.init(0, 3),
		Token.init(0, 0),
		Token.init(0, 0),
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 0), try writeSingleHistogramTokens(&tokens, info, uint_config, &writer));
	try writer.zeroPadToByte();

	const context_map = [_]u8{0};
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();

	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(0, &br, &context_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSingleHistogramTokens round-trips extra-bit stream through ANSSymbolReader" {
	const allocator = testing.allocator;
	const counts = [_]i32{ 2048, 1024, 512, 512 };
	const log_alpha_size: u5 = 5;
	const uint_config = HybridUintConfig.init(1, 0, 0);
	const info = try buildANSEncSymbolInfoTable(allocator, &counts, log_alpha_size);
	defer freeANSEncSymbolInfoTable(allocator, info);
	var code = try buildSingleHistogramCode(allocator, &counts, uint_config, log_alpha_size);
	defer code.deinit();

	const tokens = [_]Token{
		Token.init(0, 0),
		Token.init(0, 1),
		Token.init(0, 2),
		Token.init(0, 3),
		Token.init(0, 4),
		Token.init(0, 3),
		Token.init(0, 2),
		Token.init(0, 1),
		Token.init(0, 4),
		Token.init(0, 0),
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try testing.expectEqual(@as(usize, 8), try writeSingleHistogramTokens(&tokens, info, uint_config, &writer));
	try writer.zeroPadToByte();

	const context_map = [_]u8{0};
	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();

	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(0, &br, &context_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}
