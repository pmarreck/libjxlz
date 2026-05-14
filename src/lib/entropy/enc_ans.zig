// Encoder-side ANS helpers.
// Starts with the smallest real entropy-writing slice: HybridUintConfig encoding.

const std = @import("std");
const params = @import("ans_params.zig");
const ans_common = @import("ans_common.zig");
const AliasTable = ans_common.AliasTable;
const enc_context_map = @import("enc_context_map.zig");
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

pub const Histogram = struct {
	counts: std.ArrayList(i32) = .empty,
	total_count: usize = 0,
	entropy: f64 = 0,

	/// Grows symbol counts in the same rounded, sparse-friendly way as upstream's
	/// encoder histogram builder so later clustering can share the same shape/cost basis.
	pub fn add(self: *Histogram, allocator: std.mem.Allocator, symbol: usize) !void {
		if (self.counts.items.len <= symbol) {
			try self.ensureCapacity(allocator, symbol + 1);
		}
		self.counts.items[symbol] += 1;
		self.total_count += 1;
	}

	pub fn ensureCapacity(self: *Histogram, allocator: std.mem.Allocator, length: usize) !void {
		const rounded = std.mem.alignForward(usize, length, 8);
		if (rounded <= self.counts.items.len) return;
		const old_len = self.counts.items.len;
		try self.counts.resize(allocator, rounded);
		@memset(self.counts.items[old_len..], 0);
	}

	pub fn addHistogram(self: *Histogram, allocator: std.mem.Allocator, other: *const Histogram) !void {
		if (other.counts.items.len > self.counts.items.len) {
			try self.ensureCapacity(allocator, other.counts.items.len);
		}
		for (other.counts.items, 0..) |count, i| {
			self.counts.items[i] += count;
		}
		self.total_count += other.total_count;
	}

	pub fn alphabetSize(self: *const Histogram) usize {
		var i = self.counts.items.len;
		while (i > 0) {
			i -= 1;
			if (self.counts.items[i] != 0) return i + 1;
		}
		return 0;
	}

	pub fn maxSymbol(self: *const Histogram) usize {
		if (self.total_count == 0) return 0;
		var i = self.counts.items.len;
		while (i > 1) {
			i -= 1;
			if (self.counts.items[i] != 0) return i;
		}
		return 0;
	}

	/// Computes the raw data entropy in bits for this histogram,
	/// matching the `count * -log2(p)` basis upstream uses for clustering.
	pub fn shannonEntropy(self: *Histogram) f64 {
		self.entropy = 0;
		if (self.total_count == 0) return 0;

		const total_f: f64 = @floatFromInt(self.total_count);
		for (self.counts.items) |count| {
			if (count == 0) continue;
			const count_f: f64 = @floatFromInt(count);
			self.entropy += count_f * std.math.log2(total_f / count_f);
		}
		return self.entropy;
	}

	/// Estimates how many extra data bits result from coding `a` and `b`
	/// with one merged histogram instead of two separate ones.
	pub fn distance(a: *Histogram, b: *Histogram, allocator: std.mem.Allocator) !f64 {
		if (a.total_count == 0 or b.total_count == 0) return 0;

		var merged = Histogram{};
		defer merged.deinit(allocator);
		try merged.addHistogram(allocator, a);
		try merged.addHistogram(allocator, b);
		return merged.shannonEntropy() - a.shannonEntropy() - b.shannonEntropy();
	}

	pub fn deinit(self: *Histogram, allocator: std.mem.Allocator) void {
		self.counts.deinit(allocator);
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
	out: []ReversedChunk,
	out_len: *usize,
	allbits: *u64,
	numallbits: *usize,
	bits: u64,
	nbits: usize,
) !void {
	if (nbits == 0) return;
	std.debug.assert(bits >> @intCast(nbits) == 0);
	if (numallbits.* + nbits > BitWriter.kMaxBitsPerCall) {
		out[out_len.*] = .{
			.bits = allbits.*,
			.nbits = @intCast(numallbits.*),
		};
		out_len.* += 1;
		allbits.* = 0;
		numallbits.* = 0;
	}
	allbits.* <<= @intCast(nbits);
	allbits.* |= bits;
	numallbits.* += nbits;
}

const ReversedChunk = struct {
	bits: u64,
	nbits: u8,
};

pub fn writeSingleHistogramTokens(
	tokens: []const Token,
	info: []const ANSEncSymbolInfo,
	uint_config: HybridUintConfig,
	writer: *BitWriter,
) !usize {
	const out = try writer.allocator.alloc(ReversedChunk, tokens.len * 2);
	defer writer.allocator.free(out);
	var out_len: usize = 0;

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
		try addReversedBits(out, &out_len, &allbits, &numallbits, encoded.bits, encoded.nbits);
		num_extra_bits += encoded.nbits;

		const ans_bits = ans.putSymbol(&info[encoded.token]);
		try addReversedBits(out, &out_len, &allbits, &numallbits, ans_bits.bits, ans_bits.nbits);
	}

	var pending_bits: usize = 32 + numallbits;
	for (out[0..out_len]) |chunk| {
		pending_bits += chunk.nbits;
	}
	try writer.ensureUnusedCapacityBits(pending_bits);
	try writer.write(32, ans.getState());
	try writer.write(numallbits, allbits);
	var chunk_index = out_len;
	while (chunk_index > 0) {
		chunk_index -= 1;
		try writer.write(out[chunk_index].nbits, out[chunk_index].bits);
	}
	return num_extra_bits;
}

/// Writes a token stream whose symbols can draw from different histogram
/// tables, with the histogram chosen by `context_map[token.context]`.
pub fn writeContextualHistogramTokens(
	tokens: []const Token,
	infos: []const []const ANSEncSymbolInfo,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	writer: *BitWriter,
) !usize {
	if (infos.len == 0 or infos.len != uint_configs.len) return error.GenericError;

	const out = try writer.allocator.alloc(ReversedChunk, tokens.len * 2);
	defer writer.allocator.free(out);
	var out_len: usize = 0;

	var allbits: u64 = 0;
	var numallbits: usize = 0;
	var num_extra_bits: usize = 0;
	var ans = ANSCoder{};

	var i = tokens.len;
	while (i > 0) {
		i -= 1;
		const token = tokens[i];
		if (token.is_lz77_length or token.context >= context_map.len) return error.GenericError;

		const hist_idx = context_map[token.context];
		if (hist_idx >= infos.len) return error.GenericError;

		const cfg = uint_configs[hist_idx];
		const info = infos[hist_idx];
		const encoded = cfg.encode(token.value);
		if (encoded.token >= info.len) return error.GenericError;
		try addReversedBits(out, &out_len, &allbits, &numallbits, encoded.bits, encoded.nbits);
		num_extra_bits += encoded.nbits;

		const ans_bits = ans.putSymbol(&info[encoded.token]);
		try addReversedBits(out, &out_len, &allbits, &numallbits, ans_bits.bits, ans_bits.nbits);
	}

	var pending_bits: usize = 32 + numallbits;
	for (out[0..out_len]) |chunk| {
		pending_bits += chunk.nbits;
	}
	try writer.ensureUnusedCapacityBits(pending_bits);
	try writer.write(32, ans.getState());
	try writer.write(numallbits, allbits);
	var chunk_index = out_len;
	while (chunk_index > 0) {
		chunk_index -= 1;
		try writer.write(out[chunk_index].nbits, out[chunk_index].bits);
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

/// Emits a one-context ANS histogram bundle using the decoder's flat-histogram
/// branch, which spreads counts across a contiguous alphabet deterministically.
pub fn writeSingleContextFlatHistogram(
	alphabet_size: u16,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(alphabet_size > 0);
	std.debug.assert(alphabet_size <= (@as(u16, 1) << @as(u4, @intCast(log_alpha_size))));
	std.debug.assert(log_alpha_size >= 5 and log_alpha_size <= 8);
	try writer.write(1, 0); // LZ77 disabled
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfig(uint_config, writer, log_alpha_size);

	try writer.write(1, 0); // histogram simple_code = false
	try writer.write(1, 1); // is_flat = true
	try storeVarLenUint8(@intCast(alphabet_size - 1), writer);
}

/// Emits a multi-context histogram bundle where every context maps to
/// histogram 0, matching the narrow global-tree shape the encoder uses today.
pub fn writeAllZeroContextMapFlatHistogram(
	num_contexts: usize,
	alphabet_size: u16,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(num_contexts > 0);
	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeSimpleAllZeroContextMap(num_contexts, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfig(uint_config, writer, log_alpha_size);

	try writer.write(1, 0); // histogram simple_code = false
	try writer.write(1, 1); // is_flat = true
	try storeVarLenUint8(@intCast(alphabet_size - 1), writer);
}

/// Emits a simple direct-entry context map followed by one flat histogram per
/// referenced histogram ID, which is the next step beyond the all-zero shortcut.
pub fn writeSimpleContextMapFlatHistograms(
	context_map: []const u8,
	num_histograms: usize,
	alphabet_sizes: []const u16,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	std.debug.assert(alphabet_sizes.len == num_histograms);
	std.debug.assert(uint_configs.len == num_histograms);

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeSimpleContextMap(context_map, num_histograms, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfigs(uint_configs, writer, log_alpha_size);

	for (alphabet_sizes) |alphabet_size| {
		try writer.write(1, 0); // histogram simple_code = false
		try writer.write(1, 1); // is_flat = true
		try storeVarLenUint8(@intCast(alphabet_size - 1), writer);
	}
}

/// Emits a context map using the best currently-supported encoding choice
/// (simple direct, raw ANS, or MTF+ANS), then one flat histogram per emitted histogram id.
pub fn writeContextMapFlatHistograms(
	allocator: std.mem.Allocator,
	context_map: []const u8,
	num_histograms: usize,
	alphabet_sizes: []const u16,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	std.debug.assert(alphabet_sizes.len == num_histograms);
	std.debug.assert(uint_configs.len == num_histograms);

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeContextMap(allocator, context_map, num_histograms, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfigs(uint_configs, writer, log_alpha_size);

	for (alphabet_sizes) |alphabet_size| {
		try writer.write(1, 0); // histogram simple_code = false
		try writer.write(1, 1); // is_flat = true
		try storeVarLenUint8(@intCast(alphabet_size - 1), writer);
	}
}

const kMaxNumSymbolsForSmallCode = 2;
const kBitWidthLengths = [_]u8{
	5, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 6, 7, 7,
};
const kBitWidthSymbols = [_]u8{
	17, 11, 15, 3, 9, 7, 4, 2, 5, 6, 0, 33, 1, 65,
};
const kMinReps: u8 = 5;
const kRepCode: usize = params.ans_log_tab_size + 1;
const kExactHistogramShift: u32 = params.ans_log_tab_size - 1;
const kExactHistogramMethod: u32 = kExactHistogramShift + 1;

fn trimmedAlphabetSizeForCounts(comptime T: type, counts: []const T) usize {
	var alphabet_size = counts.len;
	while (alphabet_size > 0 and counts[alphabet_size - 1] == 0) {
		alphabet_size -= 1;
	}
	return alphabet_size;
}

fn isFlatHistogram(counts: []const i32) bool {
	const alphabet_size = trimmedAlphabetSizeForCounts(i32, counts);
	if (alphabet_size == 0) return false;
	const base: i32 = @intCast(params.ans_tab_size / alphabet_size);
	const rem = params.ans_tab_size % alphabet_size;
	for (counts[0..alphabet_size], 0..) |count, i| {
		const want = base + @as(i32, @intCast(@intFromBool(i < rem)));
		if (count != want) return false;
	}
	return true;
}

fn chooseOmitPosition(counts: []const i32) usize {
	var omit_pos: usize = 0;
	var max_count: i32 = 0;
	for (counts, 0..) |count, i| {
		if (count > max_count) {
			max_count = count;
			omit_pos = i;
		}
	}
	return omit_pos;
}

/// Normalizes raw token frequencies into an ANS table population of 4096 while
/// preserving symbol support and leaving the largest bin to absorb rounding error.
pub fn normalizeHistogramCounts(
	allocator: std.mem.Allocator,
	raw_counts: []const u32,
) ![]i32 {
	const alphabet_size = trimmedAlphabetSizeForCounts(u32, raw_counts);
	if (alphabet_size == 0 or alphabet_size > params.ans_max_alphabet_size) return error.GenericError;

	var total: u64 = 0;
	var remainder_pos: usize = 0;
	var max_freq: u32 = 0;
	var num_symbols: usize = 0;
	for (raw_counts[0..alphabet_size], 0..) |count, i| {
		total += count;
		if (count > 0) {
			num_symbols += 1;
			if (count > max_freq) {
				max_freq = count;
				remainder_pos = i;
			}
		}
	}
	if (total == 0) return error.GenericError;

	const normalized = try allocator.alloc(i32, alphabet_size);
	@memset(normalized, 0);
	if (num_symbols == 1) {
		normalized[remainder_pos] = @intCast(params.ans_tab_size);
		return normalized;
	}

	var sum_others: usize = 0;
	for (raw_counts[0..alphabet_size], 0..) |count, i| {
		if (count == 0 or i == remainder_pos) continue;
		var normalized_count: usize = @intCast((@as(u64, count) * params.ans_tab_size + total / 2) / total);
		if (normalized_count == 0) normalized_count = 1;
		if (normalized_count >= params.ans_tab_size) normalized_count = params.ans_tab_size - 1;
		normalized[i] = @intCast(normalized_count);
		sum_others += normalized_count;
	}

	while (sum_others >= params.ans_tab_size) {
		var best_index: ?usize = null;
		var best_count: i32 = 0;
		for (normalized, 0..) |count, i| {
			if (i == remainder_pos or count <= 1) continue;
			if (count > best_count) {
				best_count = count;
				best_index = i;
			}
		}
		if (best_index == null) return error.GenericError;
		normalized[best_index.?] -= 1;
		sum_others -= 1;
	}

	normalized[remainder_pos] = @intCast(params.ans_tab_size - sum_others);
	if (normalized[remainder_pos] <= 0) return error.GenericError;
	return normalized;
}

fn writeHistogramMethod(method: u32, writer: anytype) !void {
	const upper_bound_log = bits_mod.floorLog2Nonzero(@as(u32, params.ans_log_tab_size) + 1);
	const log = bits_mod.floorLog2Nonzero(@as(u32, method));
	try writer.write(log, (@as(u32, 1) << @intCast(log)) - 1);
	if (log != upper_bound_log) try writer.write(1, 0);
	try writer.write(log, ((@as(u32, 1) << @intCast(log)) - 1) & method);
}

fn writeNormalizedHistogramBody(normalized_counts: []const i32, writer: anytype) !void {
	const alphabet_size = trimmedAlphabetSizeForCounts(i32, normalized_counts);
	if (alphabet_size == 0 or alphabet_size > params.ans_max_alphabet_size) return error.GenericError;

	var num_symbols: usize = 0;
	var symbols: [kMaxNumSymbolsForSmallCode]u8 = undefined;
	for (normalized_counts[0..alphabet_size], 0..) |count, i| {
		if (count > 0) {
			if (num_symbols < kMaxNumSymbolsForSmallCode) symbols[num_symbols] = @intCast(i);
			num_symbols += 1;
		}
	}
	if (num_symbols == 0) return error.GenericError;

	if (num_symbols <= kMaxNumSymbolsForSmallCode) {
		try writer.write(1, 1); // small tree
		if (num_symbols == 1) {
			try writer.write(1, 0);
			try storeVarLenUint8(symbols[0], writer);
			return;
		}

		try writer.write(1, 1);
		try storeVarLenUint8(symbols[0], writer);
		try storeVarLenUint8(symbols[1], writer);
		try writer.write(params.ans_log_tab_size, @as(u32, @intCast(normalized_counts[symbols[0]])));
		return;
	}

	if (isFlatHistogram(normalized_counts[0..alphabet_size])) {
		try writer.write(1, 0); // non-small tree
		try writer.write(1, 1); // flat histogram
		try storeVarLenUint8(@intCast(alphabet_size - 1), writer);
		return;
	}

	try writer.write(1, 0); // non-small tree
	try writer.write(1, 0); // non-flat histogram
	try writeHistogramMethod(kExactHistogramMethod, writer);
	try storeVarLenUint8(@intCast(alphabet_size - 3), writer);

	const omit_pos = chooseOmitPosition(normalized_counts[0..alphabet_size]);
	var same = [_]u8{0} ** params.ans_max_alphabet_size;
	var last: usize = 0;
	var i: usize = 1;
	while (i <= alphabet_size) : (i += 1) {
		if (i == alphabet_size or i == omit_pos or i == omit_pos + 1 or normalized_counts[i] != normalized_counts[last]) {
			same[last] = @intCast(i - last);
			last = i;
		}
	}

	var bit_width = [_]u8{0} ** params.ans_max_alphabet_size;
	var omit_width: u8 = 10;
	for (normalized_counts[0..alphabet_size], 0..) |count, idx| {
		if (idx == omit_pos or count == 0) continue;
		bit_width[idx] = @intCast(bits_mod.floorLog2Nonzero(@as(u32, @intCast(count))) + 1);
		const candidate = bit_width[idx] + @as(u8, @intCast(@intFromBool(idx < omit_pos)));
		if (candidate > omit_width) omit_width = candidate;
	}
	bit_width[omit_pos] = omit_width;

	i = 0;
	while (i < alphabet_size) : (i += 1) {
		try writer.write(kBitWidthLengths[bit_width[i]], kBitWidthSymbols[bit_width[i]]);
		if (same[i] >= kMinReps) {
			try writer.write(kBitWidthLengths[kRepCode], kBitWidthSymbols[kRepCode]);
			try storeVarLenUint8(same[i] - kMinReps, writer);
			i += same[i] - 1;
		}
	}

	i = 0;
	while (i < alphabet_size) : (i += 1) {
		if (bit_width[i] > 1 and i != omit_pos) {
			const bitcount = ans_common.getPopulationCountPrecision(bit_width[i] - 1, kExactHistogramShift);
			const drop_bits = (bit_width[i] - 1) - bitcount;
			const count: u32 = @intCast(normalized_counts[i]);
			try writer.write(bitcount, (count >> @intCast(drop_bits)) - (@as(u32, 1) << @intCast(bitcount)));
		}
		if (same[i] >= kMinReps) {
			i += same[i] - 1;
		}
	}
}

/// Emits a one-context histogram bundle from already-normalized ANS counts,
/// selecting the compact flat/small/general representation that the decoder reads.
pub fn writeSingleContextNormalizedHistogram(
	normalized_counts: []const i32,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	const alphabet_size = trimmedAlphabetSizeForCounts(i32, normalized_counts);
	if (alphabet_size == 0 or alphabet_size > (@as(usize, 1) << @intCast(log_alpha_size))) return error.GenericError;

	try writer.write(1, 0); // LZ77 disabled
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfig(uint_config, writer, log_alpha_size);
	try writeNormalizedHistogramBody(normalized_counts, writer);
}

/// Emits a simple direct-entry context map followed by one exact histogram per
/// histogram ID, using pre-normalized counts instead of placeholder flats.
pub fn writeSimpleContextMapNormalizedHistograms(
	context_map: []const u8,
	num_histograms: usize,
	normalized_counts: []const []const i32,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	std.debug.assert(normalized_counts.len == num_histograms);
	std.debug.assert(uint_configs.len == num_histograms);

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeSimpleContextMap(context_map, num_histograms, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfigs(uint_configs, writer, log_alpha_size);

	for (normalized_counts) |counts| {
		try writeNormalizedHistogramBody(counts, writer);
	}
}

/// Emits a context map using the best currently-supported encoding choice
/// (simple direct, raw ANS, or MTF+ANS), then one exact histogram per emitted histogram id.
pub fn writeContextMapNormalizedHistograms(
	allocator: std.mem.Allocator,
	context_map: []const u8,
	num_histograms: usize,
	normalized_counts: []const []const i32,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
	writer: *BitWriter,
) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	std.debug.assert(normalized_counts.len == num_histograms);
	std.debug.assert(uint_configs.len == num_histograms);

	try writer.write(1, 0); // LZ77 disabled
	try enc_context_map.writeContextMap(allocator, context_map, num_histograms, writer);
	try writer.write(1, 0); // use_prefix_code = false (ANS mode)
	try writer.write(2, log_alpha_size - 5);
	try encodeUintConfigs(uint_configs, writer, log_alpha_size);

	for (normalized_counts) |counts| {
		try writeNormalizedHistogramBody(counts, writer);
	}
}

pub const ContextualHistogramBundle = struct {
	context_map: []u8,
	normalized_counts: [][]i32,
	infos: [][]ANSEncSymbolInfo,
	uint_configs: []HybridUintConfig,

	pub fn deinit(self: *ContextualHistogramBundle, allocator: std.mem.Allocator) void {
		allocator.free(self.context_map);
		for (self.normalized_counts) |counts| {
			allocator.free(counts);
		}
		allocator.free(self.normalized_counts);
		for (self.infos) |info| {
			freeANSEncSymbolInfoTable(allocator, info);
		}
		allocator.free(self.infos);
		allocator.free(self.uint_configs);
	}
};

test "reassignHistogramSeeds moves a histogram to the closest surviving seed" {
	const allocator = testing.allocator;

	const raw0 = [_]u32{ 20, 0 };
	const raw1 = [_]u32{ 0, 20 };
	const raw2 = [_]u32{ 0, 20 };

	var originals = [_]Histogram{
		try histogramFromRawCounts(allocator, &raw0),
		try histogramFromRawCounts(allocator, &raw1),
		try histogramFromRawCounts(allocator, &raw2),
	};
	defer for (&originals) |*hist| hist.deinit(allocator);

	var seeds = [_]RawHistogramCluster{
		.{ .hist = Histogram{} },
		.{ .hist = try histogramFromRawCounts(allocator, &raw2) },
	};
	defer {
		seeds[0].deinit(allocator);
		seeds[1].deinit(allocator);
	}
	try seeds[0].hist.addHistogram(allocator, &originals[0]);
	try seeds[0].hist.addHistogram(allocator, &originals[1]);
	seeds[0].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[0].hist);
	seeds[1].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[1].hist);

	const assignments = try reassignHistogramsToSeeds(
		allocator,
		&originals,
		&seeds,
	);
	defer allocator.free(assignments);

	try testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 1 }, assignments);
}

test "reassignHistogramSeeds avoids zero-probability coding seeds" {
	const allocator = testing.allocator;

	const raw_actual = [_]u32{ 9, 1 };
	const raw_bad = [_]u32{ 100, 0 };
	const raw_good = [_]u32{ 5, 5 };

	var originals = [_]Histogram{
		try histogramFromRawCounts(allocator, &raw_actual),
	};
	defer for (&originals) |*hist| hist.deinit(allocator);

	var seeds = [_]RawHistogramCluster{
		.{
			.hist = try histogramFromRawCounts(allocator, &raw_bad),
		},
		.{
			.hist = try histogramFromRawCounts(allocator, &raw_good),
		},
	};
	defer {
		seeds[0].deinit(allocator);
		seeds[1].deinit(allocator);
	}
	seeds[0].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[0].hist);
	seeds[1].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[1].hist);

	const assignments = try reassignHistogramsToSeeds(
		allocator,
		&originals,
		&seeds,
	);
	defer allocator.free(assignments);

	try testing.expectEqualSlices(usize, &[_]usize{1}, assignments);
}

test "fastClusterHistogramSeeds chooses largest then farthest seed and assigns middles" {
	const allocator = testing.allocator;

	const raw0 = [_]u32{ 30, 0 };
	const raw1 = [_]u32{ 0, 30 };
	const raw2 = [_]u32{ 14, 16 };

	var originals = [_]Histogram{
		try histogramFromRawCounts(allocator, &raw0),
		try histogramFromRawCounts(allocator, &raw1),
		try histogramFromRawCounts(allocator, &raw2),
	};
	defer for (&originals) |*hist| hist.deinit(allocator);

	var clustered = try fastClusterHistogramSeeds(
		allocator,
		&originals,
	);
	defer clustered.deinit(allocator);

	try testing.expectEqual(@as(usize, 2), clustered.seeds.len);
	try testing.expectEqualSlices(usize, &[_]usize{ 0, 1 }, clustered.seed_sources);
	try testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 1 }, clustered.assignments);
}

test "fastClusterHistogramSeeds merges identical raw histograms" {
	const allocator = testing.allocator;

	const raw0 = [_]u32{ 30, 0, 7 };
	const raw1 = [_]u32{ 30, 0, 7 };

	var originals = [_]Histogram{
		try histogramFromRawCounts(allocator, &raw0),
		try histogramFromRawCounts(allocator, &raw1),
	};
	defer for (&originals) |*hist| hist.deinit(allocator);

	var clustered = try fastClusterHistogramSeeds(
		allocator,
		&originals,
	);
	defer clustered.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), clustered.seeds.len);
	try testing.expectEqualSlices(usize, &[_]usize{ 0 }, clustered.seed_sources);
	try testing.expectEqualSlices(usize, &[_]usize{ 0, 0 }, clustered.assignments);
}

test "reassignHistogramSeeds prefers the lower-KL coding seed" {
	const allocator = testing.allocator;

	const raw_actual = [_]u32{ 2, 1, 2, 2, 4, 1 };
	const raw_seed0 = [_]u32{ 4, 3, 1, 1, 1, 2 };
	const raw_seed1 = [_]u32{ 1, 3, 2, 3, 1, 2 };

	var originals = [_]Histogram{
		try histogramFromRawCounts(allocator, &raw_actual),
	};
	defer originals[0].deinit(allocator);

	var seeds = [_]RawHistogramCluster{
		.{ .hist = try histogramFromRawCounts(allocator, &raw_seed0) },
		.{ .hist = try histogramFromRawCounts(allocator, &raw_seed1) },
	};
	defer {
		seeds[0].deinit(allocator);
		seeds[1].deinit(allocator);
	}
	seeds[0].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[0].hist);
	seeds[1].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[1].hist);

	const assignments = try reassignHistogramsToSeeds(allocator, &originals, &seeds);
	defer allocator.free(assignments);

	try testing.expect(histogramKLDivergence(&originals[0], &seeds[1].hist) <
		histogramKLDivergence(&originals[0], &seeds[0].hist));
	try testing.expectEqualSlices(usize, &[_]usize{1}, assignments);
}

const FastClusterResult = struct {
	assignments: []usize,
	seeds: []RawHistogramCluster,
	seed_sources: []usize,

	fn deinit(self: *FastClusterResult, allocator: std.mem.Allocator) void {
		allocator.free(self.assignments);
		for (self.seeds) |*seed| seed.deinit(allocator);
		allocator.free(self.seeds);
		allocator.free(self.seed_sources);
	}
};

/// Copies a sparse histogram so clustering/reassignment can keep original
/// logical histograms intact while mutating separate seed/cluster state.
fn cloneHistogram(allocator: std.mem.Allocator, src: *const Histogram) !Histogram {
	var hist = Histogram{};
	errdefer hist.deinit(allocator);
	if (src.counts.items.len == 0) return hist;
	try hist.ensureCapacity(allocator, src.counts.items.len);
	@memcpy(hist.counts.items[0..src.counts.items.len], src.counts.items);
	hist.total_count = src.total_count;
	hist.entropy = src.entropy;
	return hist;
}

/// Rebuilds the sparse rounded histogram shape used by the clustering code
/// from raw token frequencies so later merge decisions share one cost basis.
fn histogramFromRawCounts(allocator: std.mem.Allocator, raw_counts: []const u32) !Histogram {
	var hist = Histogram{};
	errdefer hist.deinit(allocator);

	const alphabet_size = trimmedAlphabetSizeForCounts(u32, raw_counts);
	if (alphabet_size == 0) return hist;

	try hist.ensureCapacity(allocator, alphabet_size);
	for (raw_counts[0..alphabet_size], 0..) |count, i| {
		hist.counts.items[i] = @intCast(count);
		hist.total_count += count;
	}
	return hist;
}

/// Converts a raw histogram into the exact normalized ANS population form the
/// current encoder emits, including the degenerate single-symbol fallback.
fn normalizeHistogramForEmission(
	allocator: std.mem.Allocator,
	hist: *const Histogram,
) ![]i32 {
	if (hist.total_count == 0) {
		const degenerate = try allocator.alloc(i32, 1);
		degenerate[0] = @intCast(params.ans_tab_size);
		return degenerate;
	}

	const alphabet_size = trimmedAlphabetSizeForCounts(i32, hist.counts.items);
	const raw_counts = try allocator.alloc(u32, alphabet_size);
	defer allocator.free(raw_counts);
	for (0..alphabet_size) |i| {
		raw_counts[i] = @intCast(hist.counts.items[i]);
	}
	return normalizeHistogramCounts(allocator, raw_counts);
}

/// Estimates the emitted cost of one histogram in the current exact-histogram
/// encoder path: Shannon data bits plus the actual serialized histogram body.
fn estimateHistogramEmissionCost(
	allocator: std.mem.Allocator,
	hist: *Histogram,
	uint_config: HybridUintConfig,
	log_alpha_size: u5,
) !f64 {
	const normalized_counts = try normalizeHistogramForEmission(allocator, hist);
	defer allocator.free(normalized_counts);

	var size = SizeWriter{};
	try encodeUintConfig(uint_config, &size, log_alpha_size);
	try writeNormalizedHistogramBody(normalized_counts, &size);

	return hist.shannonEntropy() + @as(f64, @floatFromInt(size.size));
}

fn histogramEntropyValue(hist: *const Histogram) f64 {
	if (hist.total_count == 0) return 0;

	const total_f: f64 = @floatFromInt(hist.total_count);
	var total: f64 = 0;
	for (hist.counts.items) |count| {
		if (count == 0) continue;
		const count_f: f64 = @floatFromInt(count);
		total += count_f * std.math.log2(total_f / count_f);
	}
	return total;
}

/// Scores how costly it is to code an actual histogram with another histogram's
/// symbol probabilities, matching the encoder clustering KL-divergence heuristic.
fn histogramKLDivergence(actual: *const Histogram, coding: *const Histogram) f64 {
	if (actual.total_count == 0) return 0;
	if (coding.total_count == 0) return std.math.inf(f64);

	const coding_total: f64 = @floatFromInt(coding.total_count);
	var total: f64 = 0;
	for (actual.counts.items, 0..) |count, i| {
		if (count == 0) continue;
		const coding_count: i32 = if (i < coding.counts.items.len) coding.counts.items[i] else 0;
		if (coding_count == 0) return std.math.inf(f64);
		const count_f: f64 = @floatFromInt(count);
		const coding_count_f: f64 = @floatFromInt(coding_count);
		total += count_f * std.math.log2(coding_total / coding_count_f);
	}
	return total - histogramEntropyValue(actual);
}

/// Approximates the cost of one raw-value histogram before `HybridUintConfig`
/// choice, matching the population-only surface upstream clusters first.
fn estimateRawHistogramPopulationCost(
	allocator: std.mem.Allocator,
	hist: *Histogram,
) !f64 {
	if (hist.total_count == 0) return 0;
	if (hist.alphabetSize() > params.ans_max_alphabet_size) {
		return hist.shannonEntropy();
	}

	const normalized_counts = try normalizeHistogramForEmission(allocator, hist);
	defer allocator.free(normalized_counts);

	var size = SizeWriter{};
	try writeNormalizedHistogramBody(normalized_counts, &size);

	return hist.shannonEntropy() + @as(f64, @floatFromInt(size.size));
}

const kMinDistanceForDistinct: f64 = 48.0;

const RawHistogramCluster = struct {
	hist: Histogram = .{},
	cost: f64 = 0,
	active: bool = true,

	fn deinit(self: *RawHistogramCluster, allocator: std.mem.Allocator) void {
		self.hist.deinit(allocator);
	}
};

/// Chooses a small set of initial histogram seeds by repeatedly taking the
/// farthest histogram from the current raw-value seed set, then aggregates all
/// logical histograms onto their nearest seed.
fn fastClusterHistogramSeeds(
	allocator: std.mem.Allocator,
	original_histograms: []Histogram,
) !FastClusterResult {
	if (original_histograms.len == 0) return error.GenericError;

	const assignments = try allocator.alloc(usize, original_histograms.len);
	errdefer allocator.free(assignments);
	@memset(assignments, std.math.maxInt(usize));

	const dists = try allocator.alloc(f64, original_histograms.len);
	defer allocator.free(dists);
	for (dists) |*dist| dist.* = std.math.inf(f64);

	const seed_sources_buf = try allocator.alloc(usize, original_histograms.len);
	defer allocator.free(seed_sources_buf);
	var num_seeds: usize = 0;

	var largest_idx: usize = 0;
	for (1..original_histograms.len) |hist_idx| {
		if (original_histograms[hist_idx].total_count > original_histograms[largest_idx].total_count) {
			largest_idx = hist_idx;
		}
	}

	while (num_seeds < original_histograms.len) {
		seed_sources_buf[num_seeds] = largest_idx;
		assignments[largest_idx] = num_seeds;
		dists[largest_idx] = 0;
		num_seeds += 1;

		var next_idx: ?usize = null;
		var next_dist: f64 = 0;
		for (0..original_histograms.len) |hist_idx| {
			if (dists[hist_idx] == 0) continue;
			const dist = try Histogram.distance(&original_histograms[hist_idx], &original_histograms[largest_idx], allocator);
			dists[hist_idx] = @min(dists[hist_idx], dist);
		}
		for (0..original_histograms.len) |hist_idx| {
			if (dists[hist_idx] > next_dist) {
				next_dist = dists[hist_idx];
				next_idx = hist_idx;
			}
		}
		if (next_idx == null) break;
		if (std.math.isFinite(next_dist) and next_dist < kMinDistanceForDistinct) break;
		largest_idx = next_idx.?;
	}

	const seeds = try allocator.alloc(RawHistogramCluster, num_seeds);
	errdefer {
		for (seeds[0..num_seeds]) |*seed| seed.deinit(allocator);
		allocator.free(seeds);
	}
	const seed_sources = try allocator.alloc(usize, num_seeds);
	errdefer allocator.free(seed_sources);

	for (0..num_seeds) |seed_idx| {
		const source_idx = seed_sources_buf[seed_idx];
		seed_sources[seed_idx] = source_idx;
		seeds[seed_idx] = .{
			.hist = try cloneHistogram(allocator, &original_histograms[source_idx]),
			.cost = 0,
			.active = true,
		};
	}

	for (0..original_histograms.len) |hist_idx| {
		if (assignments[hist_idx] != std.math.maxInt(usize)) continue;
		var best_seed: ?usize = null;
		var best_dist = std.math.inf(f64);
		for (0..num_seeds) |seed_idx| {
			const dist = try Histogram.distance(&original_histograms[hist_idx], &seeds[seed_idx].hist, allocator);
			if (best_seed == null or dist < best_dist) {
				best_seed = seed_idx;
				best_dist = dist;
			}
		}
		if (best_seed == null) return error.GenericError;
		assignments[hist_idx] = best_seed.?;
		try seeds[best_seed.?].hist.addHistogram(allocator, &original_histograms[hist_idx]);
	}

	for (0..num_seeds) |seed_idx| {
		seeds[seed_idx].cost = try estimateRawHistogramPopulationCost(allocator, &seeds[seed_idx].hist);
	}

	return .{
		.assignments = assignments,
		.seeds = seeds,
		.seed_sources = seed_sources,
	};
}

const HistogramMergeCandidate = struct {
	first: usize,
	second: usize,
	delta: f64,
};

/// Reassigns original logical histograms onto a fixed set of surviving seed
/// clusters, using KL divergence so coding support and shape both matter.
fn reassignHistogramsToSeeds(
	allocator: std.mem.Allocator,
	original_histograms: []const Histogram,
	seeds: []const RawHistogramCluster,
) ![]usize {
	const assignments = try allocator.alloc(usize, original_histograms.len);
	errdefer allocator.free(assignments);

	for (original_histograms, 0..) |*hist, hist_idx| {
		var best_seed: ?usize = null;
		var best_cost: f64 = 0;
		for (seeds, 0..) |*seed, seed_idx| {
			if (!seed.active) continue;
			const cost = histogramKLDivergence(hist, &seed.hist);
			if (best_seed == null or cost < best_cost) {
				best_seed = seed_idx;
				best_cost = cost;
			}
		}
		if (best_seed == null) return error.GenericError;
		assignments[hist_idx] = best_seed.?;
	}

	return assignments;
}

/// Finds the cheapest beneficial pairwise merge among the currently-active
/// histogram clusters, using the raw population-cost model.
fn findBestHistogramMerge(
	allocator: std.mem.Allocator,
	clusters: []const RawHistogramCluster,
) !?HistogramMergeCandidate {
	var best: ?HistogramMergeCandidate = null;
	for (clusters, 0..) |*first, first_idx| {
		if (!first.active) continue;
		for (clusters[first_idx + 1 ..], first_idx + 1..) |*second, second_idx| {
			if (!second.active) continue;

			var merged = Histogram{};
			defer merged.deinit(allocator);
			try merged.addHistogram(allocator, &first.hist);
			try merged.addHistogram(allocator, &second.hist);
			const merged_cost = try estimateRawHistogramPopulationCost(allocator, &merged);
			const delta = merged_cost - first.cost - second.cost;
			if (delta >= 0) continue;
			if (best == null or delta < best.?.delta) {
				best = .{
					.first = first_idx,
					.second = second_idx,
					.delta = delta,
				};
			}
		}
	}
	return best;
}

/// Builds exact histograms for an already-chosen context map by clustering raw
/// token values first, then choosing emitted `HybridUintConfig`s per cluster.
pub fn buildContextualHistogramBundle(
	allocator: std.mem.Allocator,
	tokens: []const Token,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !ContextualHistogramBundle {
	if (context_map.len == 0 or uint_configs.len == 0) return error.GenericError;

	const num_histograms = uint_configs.len;
	const max_values = try allocator.alloc(u32, num_histograms);
	defer allocator.free(max_values);
	@memset(max_values, 0);

	for (tokens) |token| {
		if (token.is_lz77_length or token.context >= context_map.len) return error.GenericError;
		const hist_idx = context_map[token.context];
		if (hist_idx >= num_histograms) return error.GenericError;
		max_values[hist_idx] = @max(max_values[hist_idx], token.value);
	}

	const raw_counts = try allocator.alloc([]u32, num_histograms);
	for (0..num_histograms) |hist_idx| {
		raw_counts[hist_idx] = &.{};
	}
	defer {
		for (raw_counts) |counts| allocator.free(counts);
		allocator.free(raw_counts);
	}
	for (0..num_histograms) |hist_idx| {
		const len: usize = if (max_values[hist_idx] == 0) 1 else @as(usize, max_values[hist_idx]) + 1;
		raw_counts[hist_idx] = try allocator.alloc(u32, len);
		@memset(raw_counts[hist_idx], 0);
	}

	for (tokens) |token| {
		const hist_idx = context_map[token.context];
		raw_counts[hist_idx][token.value] += 1;
	}

	const original_histograms = try allocator.alloc(Histogram, num_histograms);
	defer {
		for (original_histograms) |*hist| hist.deinit(allocator);
		allocator.free(original_histograms);
	}
	for (0..num_histograms) |hist_idx| {
		original_histograms[hist_idx] = try histogramFromRawCounts(allocator, raw_counts[hist_idx]);
	}

	var fast_clustered = try fastClusterHistogramSeeds(
		allocator,
		original_histograms,
	);
	defer fast_clustered.deinit(allocator);

	const clusters = try allocator.alloc(RawHistogramCluster, fast_clustered.seeds.len);
	defer {
		for (clusters) |*cluster| cluster.deinit(allocator);
		allocator.free(clusters);
	}
	for (0..fast_clustered.seeds.len) |seed_idx| {
		clusters[seed_idx] = .{
			.hist = try cloneHistogram(allocator, &fast_clustered.seeds[seed_idx].hist),
		};
		clusters[seed_idx].cost = fast_clustered.seeds[seed_idx].cost;
	}

	const histogram_to_representative = try allocator.dupe(usize, fast_clustered.assignments);
	defer allocator.free(histogram_to_representative);

	while (try findBestHistogramMerge(allocator, clusters)) |merge| {
		try clusters[merge.first].hist.addHistogram(allocator, &clusters[merge.second].hist);
		clusters[merge.first].cost = try estimateRawHistogramPopulationCost(allocator, &clusters[merge.first].hist);
		clusters[merge.second].deinit(allocator);
		clusters[merge.second].hist = .{};
		clusters[merge.second].active = false;
		clusters[merge.second].cost = 0;

		for (histogram_to_representative) |*rep_idx| {
			if (rep_idx.* == merge.second) rep_idx.* = merge.first;
		}
	}

	const representative_to_seed = try allocator.alloc(usize, clusters.len);
	defer allocator.free(representative_to_seed);
	@memset(representative_to_seed, std.math.maxInt(usize));
	const seed_representatives = try allocator.alloc(usize, clusters.len);
	defer allocator.free(seed_representatives);

	var num_seeds: usize = 0;
	for (0..original_histograms.len) |hist_idx| {
		const rep_idx = histogram_to_representative[hist_idx];
		if (representative_to_seed[rep_idx] == std.math.maxInt(usize)) {
			representative_to_seed[rep_idx] = num_seeds;
			seed_representatives[num_seeds] = rep_idx;
			num_seeds += 1;
		}
	}

	const seeds = try allocator.alloc(RawHistogramCluster, num_seeds);
	defer {
		for (seeds) |*seed| seed.deinit(allocator);
		allocator.free(seeds);
	}
	for (0..num_seeds) |seed_idx| {
		const rep_idx = seed_representatives[seed_idx];
		seeds[seed_idx] = .{
			.hist = try cloneHistogram(allocator, &clusters[rep_idx].hist),
			.cost = clusters[rep_idx].cost,
			.active = true,
		};
	}

	const reassigned_seeds = try reassignHistogramsToSeeds(
		allocator,
		original_histograms,
		seeds,
	);
	defer allocator.free(reassigned_seeds);

	const rebuilt_clusters = try allocator.alloc(RawHistogramCluster, num_seeds);
	defer {
		for (rebuilt_clusters) |*cluster| cluster.deinit(allocator);
		allocator.free(rebuilt_clusters);
	}
	for (0..num_seeds) |seed_idx| {
		rebuilt_clusters[seed_idx] = .{
			.hist = Histogram{},
			.cost = 0,
			.active = false,
		};
	}
	for (0..num_histograms) |hist_idx| {
		const seed_idx = reassigned_seeds[hist_idx];
		try rebuilt_clusters[seed_idx].hist.addHistogram(allocator, &original_histograms[hist_idx]);
		rebuilt_clusters[seed_idx].active = true;
	}
	for (0..num_seeds) |seed_idx| {
		if (!rebuilt_clusters[seed_idx].active) continue;
		rebuilt_clusters[seed_idx].cost = try estimateRawHistogramPopulationCost(allocator, &rebuilt_clusters[seed_idx].hist);
	}

	const seed_to_cluster = try allocator.alloc(usize, num_seeds);
	defer allocator.free(seed_to_cluster);
	@memset(seed_to_cluster, std.math.maxInt(usize));

	var num_clusters: usize = 0;
	for (0..num_seeds) |seed_idx| {
		if (!rebuilt_clusters[seed_idx].active) continue;
		seed_to_cluster[seed_idx] = num_clusters;
		num_clusters += 1;
	}
	if (num_clusters == 0 or num_clusters > std.math.maxInt(u8) + 1) return error.GenericError;

	var bundle = ContextualHistogramBundle{
		.context_map = try allocator.alloc(u8, context_map.len),
		.normalized_counts = try allocator.alloc([]i32, num_clusters),
		.infos = try allocator.alloc([]ANSEncSymbolInfo, num_clusters),
		.uint_configs = try allocator.alloc(HybridUintConfig, num_clusters),
	};
	errdefer {
		allocator.free(bundle.context_map);
		for (bundle.normalized_counts[0..num_clusters]) |counts| {
			if (counts.len != 0) allocator.free(counts);
		}
		allocator.free(bundle.normalized_counts);
		for (bundle.infos[0..num_clusters]) |info| {
			if (info.len != 0) freeANSEncSymbolInfoTable(allocator, info);
		}
		allocator.free(bundle.infos);
		allocator.free(bundle.uint_configs);
	}
	for (0..num_clusters) |cluster_idx| {
		bundle.normalized_counts[cluster_idx] = &.{};
		bundle.infos[cluster_idx] = &.{};
	}

	const filled_clusters = try allocator.alloc(bool, num_clusters);
	defer allocator.free(filled_clusters);
	@memset(filled_clusters, false);

	const cluster_values = try allocator.alloc(std.ArrayList(u32), num_clusters);
	defer {
		for (cluster_values) |*values| values.deinit(allocator);
		allocator.free(cluster_values);
	}
	for (cluster_values) |*values| values.* = .empty;

	for (tokens) |token| {
		if (token.is_lz77_length or token.context >= context_map.len) return error.GenericError;
		const hist_idx = context_map[token.context];
		if (hist_idx >= num_histograms) return error.GenericError;
		const seed_idx = reassigned_seeds[hist_idx];
		if (seed_idx >= num_seeds) return error.GenericError;
		const cluster_idx = seed_to_cluster[seed_idx];
		if (cluster_idx >= num_clusters) return error.GenericError;
		try cluster_values[cluster_idx].append(allocator, token.value);
	}

	for (0..num_seeds) |seed_idx| {
		if (!rebuilt_clusters[seed_idx].active) continue;
		const cluster_idx = seed_to_cluster[seed_idx];
		if (filled_clusters[cluster_idx]) continue;

		const chosen_cfg = try chooseBestUintConfigForValues(
			allocator,
			cluster_values[cluster_idx].items,
			log_alpha_size,
		);
		var encoded_counts = (try buildEncodedValueCounts(
			allocator,
			cluster_values[cluster_idx].items,
			chosen_cfg,
			log_alpha_size,
		)) orelse return error.GenericError;
		defer encoded_counts.deinit(allocator);
		var encoded_hist = try histogramFromRawCounts(allocator, encoded_counts.counts);
		defer encoded_hist.deinit(allocator);

		bundle.normalized_counts[cluster_idx] = try normalizeHistogramForEmission(
			allocator,
			&encoded_hist,
		);
		bundle.infos[cluster_idx] = try buildANSEncSymbolInfoTable(
			allocator,
			bundle.normalized_counts[cluster_idx],
			log_alpha_size,
		);
		bundle.uint_configs[cluster_idx] = chosen_cfg;
		filled_clusters[cluster_idx] = true;
	}
	for (context_map, 0..) |hist_idx, ctx_idx| {
		bundle.context_map[ctx_idx] = @intCast(seed_to_cluster[reassigned_seeds[hist_idx]]);
	}

	return bundle;
}

const testing = std.testing;

const adaptive_uint_config_candidates = [_]HybridUintConfig{
	HybridUintConfig.init(4, 2, 0),
	HybridUintConfig.init(4, 1, 2),
	HybridUintConfig.init(0, 0, 0),
	HybridUintConfig.init(2, 0, 1),
	HybridUintConfig.init(8, 0, 0),
};

const EncodedValueCounts = struct {
	counts: []u32,
	extra_bits: usize,

	fn deinit(self: *EncodedValueCounts, allocator: std.mem.Allocator) void {
		allocator.free(self.counts);
	}
};

fn buildEncodedValueCounts(
	allocator: std.mem.Allocator,
	values: []const u32,
	cfg: HybridUintConfig,
	log_alpha_size: u5,
) !?EncodedValueCounts {
	if (cfg.split_exponent > log_alpha_size) return null;
	if (values.len == 0) {
		const counts = try allocator.alloc(u32, 1);
		counts[0] = 0;
		return .{
			.counts = counts,
			.extra_bits = 0,
		};
	}

	var max_token: u32 = 0;
	var extra_bits: usize = 0;
	for (values) |value| {
		const encoded = cfg.encode(value);
		max_token = @max(max_token, encoded.token);
		extra_bits += encoded.nbits;
	}
	if (max_token >= (@as(u32, 1) << @intCast(log_alpha_size))) return null;

	const raw_counts = try allocator.alloc(u32, @as(usize, max_token) + 1);
	@memset(raw_counts, 0);
	for (values) |value| {
		const encoded = cfg.encode(value);
		raw_counts[encoded.token] += 1;
	}

	return .{
		.counts = raw_counts,
		.extra_bits = extra_bits,
	};
}

fn estimateUintConfigCostForValues(
	allocator: std.mem.Allocator,
	values: []const u32,
	cfg: HybridUintConfig,
	log_alpha_size: u5,
) !?f64 {
	var encoded_counts = (try buildEncodedValueCounts(allocator, values, cfg, log_alpha_size)) orelse return null;
	defer encoded_counts.deinit(allocator);

	var hist = try histogramFromRawCounts(allocator, encoded_counts.counts);
	defer hist.deinit(allocator);

	var size = SizeWriter{};
	try encodeUintConfig(cfg, &size, log_alpha_size);
	return try estimateHistogramEmissionCost(allocator, &hist, cfg, log_alpha_size) +
		@as(f64, @floatFromInt(encoded_counts.extra_bits + size.size));
}

pub fn chooseBestUintConfigForValues(
	allocator: std.mem.Allocator,
	values: []const u32,
	log_alpha_size: u5,
) !HybridUintConfig {
	var best_cfg: ?HybridUintConfig = null;
	var best_cost: f64 = std.math.inf(f64);
	for (adaptive_uint_config_candidates) |cfg| {
		const maybe_cost = try estimateUintConfigCostForValues(allocator, values, cfg, log_alpha_size);
		const cost = maybe_cost orelse continue;
		if (cost < best_cost) {
			best_cost = cost;
			best_cfg = cfg;
		}
	}
	return best_cfg orelse error.GenericError;
}

fn bruteForceBestUintConfigForValues(
	allocator: std.mem.Allocator,
	values: []const u32,
	log_alpha_size: u5,
) !HybridUintConfig {
	var best_cfg: ?HybridUintConfig = null;
	var best_cost: f64 = std.math.inf(f64);
	for (adaptive_uint_config_candidates) |cfg| {
		const maybe_cost = try estimateUintConfigCostForValues(allocator, values, cfg, log_alpha_size);
		const cost = maybe_cost orelse continue;
		if (cost < best_cost) {
			best_cost = cost;
			best_cfg = cfg;
		}
	}
	return best_cfg orelse error.GenericError;
}

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
		var original: std.ArrayList(HybridUintConfig) = .empty;
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

test "writeSingleContextFlatHistogram round-trips recovered flat counts through decodeHistograms" {
	const allocator = testing.allocator;
	const want_cfg = HybridUintConfig.init(5, 0, 0);
	const want_counts = try ans_common.createFlatHistogram(allocator, 5, params.ans_tab_size);
	defer allocator.free(want_counts);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleContextFlatHistogram(5, want_cfg, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, 1, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 1), context_map.len);
	try testing.expectEqual(@as(u8, 0), context_map[0]);
	try testing.expectEqual(@as(i32, -1), code.degenerate_symbols[0]);

	const table = code.alias_tables[0 .. (@as(usize, 1) << code.log_alpha_size)];
	const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
	const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
	var recovered = [_]usize{0} ** 5;
	for (0..params.ans_tab_size) |i| {
		const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
		recovered[sym.value] += 1;
	}

	for (want_counts, 0..) |want, i| {
		try testing.expectEqual(@as(usize, @intCast(want)), recovered[i]);
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSingleContextNormalizedHistogram round-trips recovered non-flat counts through decodeHistograms" {
	const allocator = testing.allocator;
	const want_cfg = HybridUintConfig.init(5, 0, 0);
	const raw_counts = [_]u32{ 100, 30, 7, 3, 1, 0 };
	const want_counts = try normalizeHistogramCounts(allocator, &raw_counts);
	defer allocator.free(want_counts);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSingleContextNormalizedHistogram(want_counts, want_cfg, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, 1, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 1), context_map.len);
	try testing.expectEqual(@as(u8, 0), context_map[0]);
	try testing.expectEqual(@as(i32, -1), code.degenerate_symbols[0]);

	const table = code.alias_tables[0 .. (@as(usize, 1) << code.log_alpha_size)];
	const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
	const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
	const recovered = try allocator.alloc(usize, want_counts.len);
	defer allocator.free(recovered);
	@memset(recovered, 0);
	for (0..params.ans_tab_size) |i| {
		const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
		recovered[sym.value] += 1;
	}
	for (want_counts, 0..) |want, i| {
		try testing.expectEqual(@as(usize, @intCast(want)), recovered[i]);
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeAllZeroContextMapFlatHistogram round-trips through decodeHistograms" {
	const allocator = testing.allocator;
	const want_cfg = HybridUintConfig.init(5, 0, 0);
	const want_counts = try ans_common.createFlatHistogram(allocator, 5, params.ans_tab_size);
	defer allocator.free(want_counts);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeAllZeroContextMapFlatHistogram(6, 5, want_cfg, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, 6, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 6), context_map.len);
	for (context_map) |ctx| try testing.expectEqual(@as(u8, 0), ctx);
	try testing.expectEqual(@as(i32, -1), code.degenerate_symbols[0]);

	const table = code.alias_tables[0 .. (@as(usize, 1) << code.log_alpha_size)];
	const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
	const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
	var recovered = [_]usize{0} ** 5;
	for (0..params.ans_tab_size) |i| {
		const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
		recovered[sym.value] += 1;
	}

	for (want_counts, 0..) |want, i| {
		try testing.expectEqual(@as(usize, @intCast(want)), recovered[i]);
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSimpleContextMapFlatHistograms round-trips exact context map and counts" {
	const allocator = testing.allocator;
	const want_cfgs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const want_counts0 = try ans_common.createFlatHistogram(allocator, 5, params.ans_tab_size);
	defer allocator.free(want_counts0);
	const want_counts1 = try ans_common.createFlatHistogram(allocator, 3, params.ans_tab_size);
	defer allocator.free(want_counts1);
	const want_ctx_map = [_]u8{ 0, 1, 0, 1, 1, 0 };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapFlatHistograms(&want_ctx_map, 2, &[_]u16{ 5, 3 }, &want_cfgs, 5, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, want_ctx_map.len, &code);
	defer allocator.free(context_map);

	try testing.expectEqualSlices(u8, &want_ctx_map, context_map);
	try testing.expectEqual(@as(usize, 2), code.uint_config.len);

	inline for (0..2) |hist_idx| {
		const want_counts = if (hist_idx == 0) want_counts0 else want_counts1;
		const alphabet_size = want_counts.len;
		const table_begin = hist_idx * (@as(usize, 1) << code.log_alpha_size);
		const table = code.alias_tables[table_begin .. table_begin + (@as(usize, 1) << code.log_alpha_size)];
		const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
		const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
		const recovered = try allocator.alloc(usize, alphabet_size);
		defer allocator.free(recovered);
		@memset(recovered, 0);
		for (0..params.ans_tab_size) |i| {
			const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
			recovered[sym.value] += 1;
		}
		for (want_counts, 0..) |want, i| {
			try testing.expectEqual(@as(usize, @intCast(want)), recovered[i]);
		}
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSimpleContextMapNormalizedHistograms round-trips exact non-flat context map and counts" {
	const allocator = testing.allocator;
	const want_cfgs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const raw_counts0 = [_]u32{ 100, 30, 7, 3, 1, 0 };
	const raw_counts1 = [_]u32{ 0, 5, 1, 40, 2, 1 };
	const want_counts0 = try normalizeHistogramCounts(allocator, &raw_counts0);
	defer allocator.free(want_counts0);
	const want_counts1 = try normalizeHistogramCounts(allocator, &raw_counts1);
	defer allocator.free(want_counts1);
	const want_ctx_map = [_]u8{ 0, 1, 0, 1, 1, 0 };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapNormalizedHistograms(
		&want_ctx_map,
		2,
		&[_][]const i32{ want_counts0, want_counts1 },
		&want_cfgs,
		5,
		&writer,
	);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, want_ctx_map.len, &code);
	defer allocator.free(context_map);

	try testing.expectEqualSlices(u8, &want_ctx_map, context_map);
	try testing.expectEqual(@as(usize, 2), code.uint_config.len);

	inline for (0..2) |hist_idx| {
		const want_counts = if (hist_idx == 0) want_counts0 else want_counts1;
		const table_begin = hist_idx * (@as(usize, 1) << code.log_alpha_size);
		const table = code.alias_tables[table_begin .. table_begin + (@as(usize, 1) << code.log_alpha_size)];
		const log_entry_size = params.ans_log_tab_size - code.log_alpha_size;
		const entry_size_minus_1 = (@as(usize, 1) << log_entry_size) - 1;
		const recovered = try allocator.alloc(usize, want_counts.len);
		defer allocator.free(recovered);
		@memset(recovered, 0);
		for (0..params.ans_tab_size) |i| {
			const sym = AliasTable.lookup(table.ptr, i, log_entry_size, entry_size_minus_1);
			recovered[sym.value] += 1;
		}
		for (want_counts, 0..) |want, i| {
			try testing.expectEqual(@as(usize, @intCast(want)), recovered[i]);
		}
	}
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeContextMapNormalizedHistograms round-trips a non-simple 9-histogram context map" {
	const allocator = testing.allocator;
	const want_ctx_map = [_]u8{
		0, 1, 2, 3, 4, 5, 6, 7, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
	};
	const want_cfgs = [_]HybridUintConfig{HybridUintConfig.init(5, 0, 0)} ** 9;
	const raw_histograms = [_][6]u32{
		.{ 50, 3, 1, 0, 0, 0 },
		.{ 40, 8, 2, 0, 0, 0 },
		.{ 32, 9, 1, 1, 0, 0 },
		.{ 31, 10, 2, 1, 0, 0 },
		.{ 28, 11, 3, 1, 0, 0 },
		.{ 25, 12, 4, 1, 0, 0 },
		.{ 23, 12, 5, 2, 0, 0 },
		.{ 20, 13, 6, 2, 1, 0 },
		.{ 18, 14, 7, 3, 1, 0 },
	};

	var want_counts = try allocator.alloc([]i32, raw_histograms.len);
	defer {
		for (want_counts) |counts| allocator.free(counts);
		allocator.free(want_counts);
	}
	for (raw_histograms, 0..) |raw, i| {
		want_counts[i] = try normalizeHistogramCounts(allocator, &raw);
	}

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeContextMapNormalizedHistograms(
		allocator,
		&want_ctx_map,
		want_counts.len,
		want_counts,
		&want_cfgs,
		5,
		&writer,
	);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, want_ctx_map.len, &code);
	defer allocator.free(context_map);

	try testing.expectEqual(@as(usize, 9), code.uint_config.len);
	try testing.expectEqualSlices(u8, &want_ctx_map, context_map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeContextualHistogramTokens round-trips a two-histogram stream through ANSSymbolReader" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const alphabet_sizes = [_]u16{ 16, 16 };

	const counts0 = try ans_common.createFlatHistogram(allocator, alphabet_sizes[0], params.ans_tab_size);
	defer allocator.free(counts0);
	const counts1 = try ans_common.createFlatHistogram(allocator, alphabet_sizes[1], params.ans_tab_size);
	defer allocator.free(counts1);
	const info0 = try buildANSEncSymbolInfoTable(allocator, counts0, 5);
	defer freeANSEncSymbolInfoTable(allocator, info0);
	const info1 = try buildANSEncSymbolInfoTable(allocator, counts1, 5);
	defer freeANSEncSymbolInfoTable(allocator, info1);
	const infos = [_][]const ANSEncSymbolInfo{ info0, info1 };
	const tokens = [_]Token{
		Token.init(0, 3),
		Token.init(1, 5),
		Token.init(0, 7),
		Token.init(1, 2),
		Token.init(1, 15),
		Token.init(0, 1),
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapFlatHistograms(&ctx_map, 2, &alphabet_sizes, &uint_configs, 5, &writer);
	try testing.expectEqual(@as(usize, 0), try writeContextualHistogramTokens(&tokens, &infos, &ctx_map, &uint_configs, &writer));
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const decoded_ctx_map = try dec_ans.decodeHistograms(allocator, &br, ctx_map.len, &code);
	defer allocator.free(decoded_ctx_map);
	try testing.expectEqualSlices(u8, &ctx_map, decoded_ctx_map);

	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(token.context, &br, decoded_ctx_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "buildContextualHistogramBundle writes exact non-flat histograms for a token stream" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const tokens = [_]Token{
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 7),
		Token.init(0, 7),
		Token.init(0, 1),
		Token.init(0, 1),
		Token.init(1, 2),
		Token.init(1, 2),
		Token.init(1, 2),
		Token.init(1, 2),
		Token.init(1, 15),
		Token.init(1, 15),
		Token.init(1, 5),
	};

	var bundle = try buildContextualHistogramBundle(allocator, &tokens, &ctx_map, &uint_configs, 5);
	defer bundle.deinit(allocator);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		5,
		&writer,
	);
	_ = try writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const decoded_ctx_map = try dec_ans.decodeHistograms(allocator, &br, ctx_map.len, &code);
	defer allocator.free(decoded_ctx_map);
	try testing.expectEqualSlices(u8, bundle.context_map, decoded_ctx_map);

	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(token.context, &br, decoded_ctx_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "buildContextualHistogramBundle clusters identical histograms" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const tokens = [_]Token{
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 7),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 7),
	};

	var bundle = try buildContextualHistogramBundle(allocator, &tokens, &ctx_map, &uint_configs, 5);
	defer bundle.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), bundle.normalized_counts.len);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, bundle.context_map);
	try testing.expectEqual(@as(usize, 1), bundle.infos.len);
	try testing.expectEqual(@as(usize, 1), bundle.uint_configs.len);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		5,
		&writer,
	);
	_ = try writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const decoded_ctx_map = try dec_ans.decodeHistograms(allocator, &br, ctx_map.len, &code);
	defer allocator.free(decoded_ctx_map);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, decoded_ctx_map);

	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(token.context, &br, decoded_ctx_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "buildContextualHistogramBundle can merge identical raw values across input uint configs" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(8, 0, 0),
		HybridUintConfig.init(0, 0, 0),
	};
	const tokens = [_]Token{
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 7),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 7),
	};

	var bundle = try buildContextualHistogramBundle(allocator, &tokens, &ctx_map, &uint_configs, 8);
	defer bundle.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), bundle.normalized_counts.len);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, bundle.context_map);
}

test "buildContextualHistogramBundle merges near-identical histograms when emitted cost drops" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	const tokens = [_]Token{
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 3),
		Token.init(0, 7),
		Token.init(0, 7),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 3),
		Token.init(1, 7),
		Token.init(1, 7),
		Token.init(1, 7),
	};

	var bundle = try buildContextualHistogramBundle(allocator, &tokens, &ctx_map, &uint_configs, 5);
	defer bundle.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), bundle.normalized_counts.len);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, bundle.context_map);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		5,
		&writer,
	);
	_ = try writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const decoded_ctx_map = try dec_ans.decodeHistograms(allocator, &br, ctx_map.len, &code);
	defer allocator.free(decoded_ctx_map);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, decoded_ctx_map);

	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	for (tokens) |token| {
		try testing.expectEqual(@as(usize, token.value), reader.readHybridUint(token.context, &br, decoded_ctx_map));
	}
	try testing.expect(reader.checkANSFinalState());
	try br.jumpToByteBoundary();
	try br.close();
}

test "buildContextualHistogramBundle keeps distinct histograms separate when merge cost rises" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.init(5, 0, 0),
		HybridUintConfig.init(5, 0, 0),
	};
	var tokens: std.ArrayList(Token) = .empty;
	defer tokens.deinit(allocator);
	for (0..30) |_| {
		try tokens.append(allocator, Token.init(0, 3));
		try tokens.append(allocator, Token.init(1, 7));
	}

	var bundle = try buildContextualHistogramBundle(allocator, tokens.items, &ctx_map, &uint_configs, 5);
	defer bundle.deinit(allocator);

	try testing.expectEqual(@as(usize, 2), bundle.normalized_counts.len);
	try testing.expectEqualSlices(u8, &ctx_map, bundle.context_map);
}

test "chooseBestUintConfigForValues matches brute-force emitted-cost minimum" {
	const allocator = testing.allocator;
	const values = [_]u32{ 0, 1, 2, 3, 4, 7, 15, 31, 63, 127, 255 };
	const expected = try bruteForceBestUintConfigForValues(allocator, &values, 8);
	const got = try chooseBestUintConfigForValues(allocator, &values, 8);

	try testing.expectEqual(expected.split_exponent, got.split_exponent);
	try testing.expectEqual(expected.msb_in_token, got.msb_in_token);
	try testing.expectEqual(expected.lsb_in_token, got.lsb_in_token);
}

test "buildContextualHistogramBundle chooses emitted uint config from clustered raw values" {
	const allocator = testing.allocator;
	const ctx_map = [_]u8{0};
	const input_uint_configs = [_]HybridUintConfig{HybridUintConfig.init(8, 0, 0)};

	var tokens: std.ArrayList(Token) = .empty;
	defer tokens.deinit(allocator);
	const adaptive_values = [_]u32{ 0, 1, 2, 3, 4, 7, 15, 31, 63, 127, 255 };
	for (adaptive_values) |value| {
		try tokens.append(allocator, Token.init(0, value));
	}

	const values = try allocator.alloc(u32, tokens.items.len);
	defer allocator.free(values);
	for (tokens.items, 0..) |token, i| values[i] = token.value;
	const expected = try bruteForceBestUintConfigForValues(allocator, values, 8);

	var bundle = try buildContextualHistogramBundle(allocator, tokens.items, &ctx_map, &input_uint_configs, 8);
	defer bundle.deinit(allocator);

	try testing.expectEqual(@as(usize, 1), bundle.uint_configs.len);
	try testing.expect(expected.split_exponent != input_uint_configs[0].split_exponent or
		expected.msb_in_token != input_uint_configs[0].msb_in_token or
		expected.lsb_in_token != input_uint_configs[0].lsb_in_token);
	try testing.expectEqual(expected.split_exponent, bundle.uint_configs[0].split_exponent);
	try testing.expectEqual(expected.msb_in_token, bundle.uint_configs[0].msb_in_token);
	try testing.expectEqual(expected.lsb_in_token, bundle.uint_configs[0].lsb_in_token);
}

test "Histogram tracks alphabet and max symbol with rounded growth" {
	const allocator = testing.allocator;
	var hist = Histogram{};
	defer hist.deinit(allocator);

	try hist.add(allocator, 0);
	try hist.add(allocator, 7);
	try hist.add(allocator, 3);

	try testing.expectEqual(@as(usize, 8), hist.counts.items.len);
	try testing.expectEqual(@as(usize, 8), hist.alphabetSize());
	try testing.expectEqual(@as(usize, 7), hist.maxSymbol());
	try testing.expectEqual(@as(usize, 3), hist.total_count);
}

test "Histogram shannonEntropy matches simple exact cases" {
	const allocator = testing.allocator;
	var hist = Histogram{};
	defer hist.deinit(allocator);

	try testing.expectEqual(@as(f64, 0), hist.shannonEntropy());

	try hist.add(allocator, 0);
	try hist.add(allocator, 0);
	try testing.expectEqual(@as(f64, 0), hist.shannonEntropy());

	try hist.add(allocator, 1);
	try hist.add(allocator, 1);
	try testing.expectApproxEqAbs(@as(f64, 4), hist.shannonEntropy(), 1e-9);
}

test "Histogram distance is zero for identical distributions and positive for disjoint ones" {
	const allocator = testing.allocator;
	var a = Histogram{};
	defer a.deinit(allocator);
	var b = Histogram{};
	defer b.deinit(allocator);
	var c = Histogram{};
	defer c.deinit(allocator);
	var d = Histogram{};
	defer d.deinit(allocator);

	try a.add(allocator, 0);
	try a.add(allocator, 0);
	try a.add(allocator, 1);
	try a.add(allocator, 1);
	try b.add(allocator, 0);
	try b.add(allocator, 0);
	try b.add(allocator, 1);
	try b.add(allocator, 1);

	try c.add(allocator, 0);
	try c.add(allocator, 0);
	try c.add(allocator, 0);
	try c.add(allocator, 0);
	try d.add(allocator, 1);
	try d.add(allocator, 1);
	try d.add(allocator, 1);
	try d.add(allocator, 1);

	try testing.expectApproxEqAbs(@as(f64, 0), try Histogram.distance(&a, &b, allocator), 1e-9);
	try testing.expectApproxEqAbs(@as(f64, 8), try Histogram.distance(&c, &d, allocator), 1e-9);
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
