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
	counts: std.ArrayList(i32) = .{},
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

fn hybridUintConfigEql(a: HybridUintConfig, b: HybridUintConfig) bool {
	return a.split_exponent == b.split_exponent and
		a.msb_in_token == b.msb_in_token and
		a.lsb_in_token == b.lsb_in_token;
}

/// Builds exact histograms for an already-chosen context map, then coalesces
/// byte-identical ANS tables so multiple contexts can share one emitted histogram.
pub fn buildContextualHistogramBundle(
	allocator: std.mem.Allocator,
	tokens: []const Token,
	context_map: []const u8,
	uint_configs: []const HybridUintConfig,
	log_alpha_size: u5,
) !ContextualHistogramBundle {
	if (context_map.len == 0 or uint_configs.len == 0) return error.GenericError;

	const num_histograms = uint_configs.len;
	const max_tokens = try allocator.alloc(u32, num_histograms);
	defer allocator.free(max_tokens);
	@memset(max_tokens, 0);

	const used_hist = try allocator.alloc(bool, num_histograms);
	defer allocator.free(used_hist);
	@memset(used_hist, false);

	for (tokens) |token| {
		if (token.is_lz77_length or token.context >= context_map.len) return error.GenericError;
		const hist_idx = context_map[token.context];
		if (hist_idx >= num_histograms) return error.GenericError;
		const encoded = uint_configs[hist_idx].encode(token.value);
		max_tokens[hist_idx] = @max(max_tokens[hist_idx], encoded.token);
		used_hist[hist_idx] = true;
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
		const len: usize = if (used_hist[hist_idx]) @as(usize, max_tokens[hist_idx]) + 1 else 1;
		raw_counts[hist_idx] = try allocator.alloc(u32, len);
		@memset(raw_counts[hist_idx], 0);
	}

	for (tokens) |token| {
		const hist_idx = context_map[token.context];
		const encoded = uint_configs[hist_idx].encode(token.value);
		raw_counts[hist_idx][encoded.token] += 1;
	}

	const normalized_per_hist = try allocator.alloc([]i32, num_histograms);
	defer allocator.free(normalized_per_hist);
	const infos_per_hist = try allocator.alloc([]ANSEncSymbolInfo, num_histograms);
	defer allocator.free(infos_per_hist);
	for (0..num_histograms) |hist_idx| {
		normalized_per_hist[hist_idx] = &.{};
		infos_per_hist[hist_idx] = &.{};
	}
	defer {
		for (normalized_per_hist) |counts| {
			if (counts.len != 0) allocator.free(counts);
		}
		for (infos_per_hist) |info| {
			if (info.len != 0) freeANSEncSymbolInfoTable(allocator, info);
		}
	}

	for (0..num_histograms) |hist_idx| {
		if (!used_hist[hist_idx]) {
			const degenerate = try allocator.alloc(i32, 1);
			degenerate[0] = @intCast(params.ans_tab_size);
			normalized_per_hist[hist_idx] = degenerate;
		} else {
			normalized_per_hist[hist_idx] = try normalizeHistogramCounts(allocator, raw_counts[hist_idx]);
		}
		infos_per_hist[hist_idx] = try buildANSEncSymbolInfoTable(
			allocator,
			normalized_per_hist[hist_idx],
			log_alpha_size,
		);
	}

	const histogram_to_cluster = try allocator.alloc(usize, num_histograms);
	defer allocator.free(histogram_to_cluster);
	const cluster_representative = try allocator.alloc(usize, num_histograms);
	defer allocator.free(cluster_representative);

	var num_clusters: usize = 0;
	for (0..num_histograms) |hist_idx| {
		var found_cluster: ?usize = null;
		for (0..num_clusters) |cluster_idx| {
			const rep_idx = cluster_representative[cluster_idx];
			if (!hybridUintConfigEql(uint_configs[rep_idx], uint_configs[hist_idx])) continue;
			if (!std.mem.eql(i32, normalized_per_hist[rep_idx], normalized_per_hist[hist_idx])) continue;
			found_cluster = cluster_idx;
			break;
		}
		if (found_cluster) |cluster_idx| {
			histogram_to_cluster[hist_idx] = cluster_idx;
		} else {
			histogram_to_cluster[hist_idx] = num_clusters;
			cluster_representative[num_clusters] = hist_idx;
			num_clusters += 1;
		}
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

	for (0..num_clusters) |cluster_idx| {
		const rep_idx = cluster_representative[cluster_idx];
		bundle.normalized_counts[cluster_idx] = normalized_per_hist[rep_idx];
		normalized_per_hist[rep_idx] = &.{};
		bundle.infos[cluster_idx] = infos_per_hist[rep_idx];
		infos_per_hist[rep_idx] = &.{};
		bundle.uint_configs[cluster_idx] = uint_configs[rep_idx];
	}
	for (context_map, 0..) |hist_idx, ctx_idx| {
		bundle.context_map[ctx_idx] = @intCast(histogram_to_cluster[hist_idx]);
	}

	return bundle;
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
	try testing.expectEqual(@as(usize, 0), try writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	));
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
	try testing.expectEqual(@as(usize, 0), try writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	));
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
