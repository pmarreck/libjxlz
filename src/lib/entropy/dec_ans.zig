// ANS decoder: ANSCode, ANSSymbolReader, DecodeHistograms.
// Transliterated from lib/jxl/dec_ans.h and lib/jxl/dec_ans.cc

const std = @import("std");
const params = @import("ans_params.zig");
const ans_common = @import("ans_common.zig");
const AliasTable = ans_common.AliasTable;
const huffman_mod = @import("huffman.zig");
const HuffmanCode = huffman_mod.HuffmanCode;
const HuffmanDecodingData = huffman_mod.HuffmanDecodingData;
const HybridUintConfig = @import("hybrid_uint.zig").HybridUintConfig;
const bits_mod = @import("../base/bits.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;

// ── LZ77 Constants ──

pub const window_size: usize = 1 << 20;
const window_mask: usize = window_size - 1;
pub const num_special_distances: usize = 120;

pub const special_distances = [num_special_distances][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },  .{ -1, 2 },
    .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },  .{ 1, 3 },  .{ -1, 3 },
    .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },  .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },
    .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 }, .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 },
    .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },  .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },
    .{ 1, 5 },  .{ -1, 5 }, .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 },
    .{ 4, 4 },  .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },  .{ -6, 2 },
    .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 }, .{ 6, 3 },  .{ -6, 3 },
    .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },  .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 },
    .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 }, .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 },
    .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },  .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 },
    .{ 8, 0 },  .{ 4, 7 },  .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },
    .{ -6, 6 }, .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },  .{ 8, 7 },
};

pub fn specialDistance(index: usize, multiplier: i32) i32 {
    const dist = @as(i32, special_distances[index][0]) +
        multiplier * @as(i32, special_distances[index][1]);
    return if (dist > 1) dist else 1;
}

// ── LZ77Params ──

pub const LZ77Params = struct {
    enabled: bool = false,
    min_symbol: u32 = 224,
    min_length: u32 = 3,
    length_uint_config: HybridUintConfig = HybridUintConfig.initZero(),
    nonserialized_distance_context: usize = 0,

    /// Read LZ77 params from bitstream (matching Bundle::Read for LZ77Params).
    pub fn readFromBitStream(br: *BitReader) LZ77Params {
        br.refill();
        const enabled = br.readBits(1) != 0;
        if (!enabled) {
            return .{};
        }
        br.refill();
        // min_symbol: U32(Val(224), Val(512), Val(4096), BitsOffset(15, 8))
        const sel0 = br.readBits(2);
        const min_symbol: u32 = switch (sel0) {
            0 => 224,
            1 => 512,
            2 => 4096,
            3 => @as(u32, @intCast(br.readBits(15))) + 8,
            else => unreachable,
        };
        br.refill();
        // min_length: U32(Val(3), Val(4), BitsOffset(2, 5), BitsOffset(8, 9))
        const sel1 = br.readBits(2);
        const min_length: u32 = switch (sel1) {
            0 => 3,
            1 => 4,
            2 => @as(u32, @intCast(br.readBits(2))) + 5,
            3 => @as(u32, @intCast(br.readBits(8))) + 9,
            else => unreachable,
        };
        return .{
            .enabled = true,
            .min_symbol = min_symbol,
            .min_length = min_length,
        };
    }
};

// ── ANSCode ──

pub const ANSCode = struct {
    alias_tables: []AliasTable.Entry,
    huffman_data: []HuffmanDecodingData,
    uint_config: []HybridUintConfig,
    degenerate_symbols: []i32,
    use_prefix_code: bool,
    log_alpha_size: u5,
    lz77: LZ77Params,
    max_num_bits: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ANSCode {
        return .{
            .alias_tables = &.{},
            .huffman_data = &.{},
            .uint_config = &.{},
            .degenerate_symbols = &.{},
            .use_prefix_code = false,
            .log_alpha_size = 0,
            .lz77 = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ANSCode) void {
        if (self.alias_tables.len > 0) self.allocator.free(self.alias_tables);
        for (self.huffman_data) |*hd| {
            var h = hd.*;
            h.deinit();
        }
        if (self.huffman_data.len > 0) self.allocator.free(self.huffman_data);
        if (self.uint_config.len > 0) self.allocator.free(self.uint_config);
        if (self.degenerate_symbols.len > 0) self.allocator.free(self.degenerate_symbols);
    }

    pub fn updateMaxNumBits(self: *ANSCode, ctx: usize, symbol: usize) void {
        var cfg = &self.uint_config[ctx];
        var sym = symbol;
        if (self.lz77.enabled and self.lz77.nonserialized_distance_context != ctx and
            sym >= self.lz77.min_symbol)
        {
            sym -= self.lz77.min_symbol;
            cfg = &self.lz77.length_uint_config;
        }
        const split_token = cfg.split_token;
        const msb_in_token = cfg.msb_in_token;
        const lsb_in_token = cfg.lsb_in_token;
        const split_exponent = cfg.split_exponent;
        if (sym < split_token) {
            self.max_num_bits = @max(self.max_num_bits, split_exponent);
            return;
        }
        const n_extra_bits = split_exponent - (msb_in_token + lsb_in_token) +
            ((sym - split_token) >> @intCast(msb_in_token + lsb_in_token));
        const total_bits = msb_in_token + lsb_in_token + n_extra_bits + 1;
        self.max_num_bits = @max(self.max_num_bits, total_bits);
    }
};

// ── Histogram reading helpers ──

/// Decodes a number in the range [0..255], by reading 1 - 11 bits.
fn decodeVarLenUint8(br: *BitReader) u32 {
    if (br.readBits(1) != 0) {
        const nbits: u5 = @intCast(br.readBits(3));
        if (nbits == 0) {
            return 1;
        }
        return @as(u32, @intCast(br.readBits(nbits))) + (@as(u32, 1) << nbits);
    }
    return 0;
}

/// Decodes a number in the range [0..65535], by reading 1 - 21 bits.
fn decodeVarLenUint16(br: *BitReader) u32 {
    if (br.readBits(1) != 0) {
        const nbits: u5 = @intCast(br.readBits(4));
        if (nbits == 0) {
            return 1;
        }
        return @as(u32, @intCast(br.readBits(nbits))) + (@as(u32, 1) << nbits);
    }
    return 0;
}

/// Reads a histogram from the bitstream.
fn readHistogram(
    allocator: std.mem.Allocator,
    precision_bits: u5,
    br: *BitReader,
) JxlError![]i32 {
    const range: u32 = @as(u32, 1) << precision_bits;
    const simple_code = br.readBits(1);

    if (simple_code == 1) {
        var symbols: [2]u32 = .{ 0, 0 };
        var max_symbol: u32 = 0;
        const num_symbols = br.readBits(1) + 1;
        for (0..num_symbols) |i| {
            symbols[i] = decodeVarLenUint8(br);
            if (symbols[i] > max_symbol) max_symbol = symbols[i];
        }
        const counts = try allocator.alloc(i32, max_symbol + 1);
        @memset(counts, 0);
        if (num_symbols == 1) {
            counts[symbols[0]] = @intCast(range);
        } else {
            if (symbols[0] == symbols[1]) {
                allocator.free(counts);
                return error.GenericError;
            }
            counts[symbols[0]] = @intCast(br.readBits(precision_bits));
            counts[symbols[1]] = @as(i32, @intCast(range)) - counts[symbols[0]];
        }
        return counts;
    }

    // Non-simple code
    const is_flat = br.readBits(1);
    if (is_flat == 1) {
        const alphabet_size = decodeVarLenUint8(br) + 1;
        if (alphabet_size > range) return error.GenericError;
        return ans_common.createFlatHistogram(allocator, alphabet_size, range);
    }

    // Full histogram
    const upper_bound_log = bits_mod.floorLog2Nonzero(@as(u32, params.ans_log_tab_size + 1));
    var log: u32 = 0;
    while (log < upper_bound_log) : (log += 1) {
        if (br.readBits(1) == 0) break;
    }
    const shift: u32 = (@as(u32, @intCast(br.readBits(@intCast(log)))) | (@as(u32, 1) << @intCast(log))) - 1;
    if (shift > params.ans_log_tab_size + 1) return error.GenericError;

    const length = decodeVarLenUint8(br) + 3;
    const counts = try allocator.alloc(i32, length);
    @memset(counts, 0);
    errdefer allocator.free(counts);

    // Hardcoded Huffman table for reading logcounts.
    const huff = [128][2]u8{
        .{ 3, 10 }, .{ 7, 12 }, .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 5, 0 },  .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 6, 11 }, .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 5, 0 },  .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 7, 13 }, .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 5, 0 },  .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 6, 11 }, .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
        .{ 3, 10 }, .{ 5, 0 },  .{ 3, 7 }, .{ 4, 3 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 5 },
        .{ 3, 10 }, .{ 4, 4 },  .{ 3, 7 }, .{ 4, 1 }, .{ 3, 6 }, .{ 3, 8 }, .{ 3, 9 }, .{ 4, 2 },
    };

    var logcounts = try allocator.alloc(i32, length);
    defer allocator.free(logcounts);
    @memset(logcounts, 0);

    var same = try allocator.alloc(i32, length);
    defer allocator.free(same);
    @memset(same, 0);

    var omit_log: i32 = -1;
    var omit_pos: i32 = -1;
    {
        var i: usize = 0;
        while (i < length) : (i += 1) {
            br.refill();
            const idx = br.peekFixedBits(7);
            br.consume(huff[idx][0]);
            logcounts[i] = @as(i32, huff[idx][1]) - 1;
            if (logcounts[i] == @as(i32, params.ans_log_tab_size)) {
                const rle_length = decodeVarLenUint8(br);
                same[i] = @intCast(rle_length + 5);
                i += rle_length + 3;
                continue;
            }
            if (logcounts[i] > omit_log) {
                omit_log = logcounts[i];
                omit_pos = @intCast(i);
            }
        }
    }

    if (omit_pos < 0) return error.GenericError;
    if (@as(usize, @intCast(omit_pos)) + 1 < length and
        logcounts[@intCast(@as(usize, @intCast(omit_pos)) + 1)] == @as(i32, params.ans_log_tab_size))
    {
        return error.GenericError;
    }

    var prev: i32 = 0;
    var numsame: i32 = 0;
    var total_count: i32 = 0;
    for (0..length) |i| {
        if (same[i] != 0) {
            numsame = same[i] - 1;
            prev = if (i > 0) counts[i - 1] else 0;
        }
        if (numsame > 0) {
            counts[i] = prev;
            numsame -= 1;
        } else {
            const code = logcounts[i];
            if (i == @as(usize, @intCast(omit_pos)) or code < 0) {
                continue;
            } else if (shift == 0 or code == 0) {
                counts[i] = @as(i32, 1) << @intCast(code);
            } else {
                const bitcount = ans_common.getPopulationCountPrecision(@intCast(code), shift);
                counts[i] = (@as(i32, 1) << @intCast(code)) +
                    @as(i32, @intCast(br.readBits(@intCast(bitcount)))) << @intCast(@as(u32, @intCast(code)) - bitcount);
            }
        }
        total_count += counts[i];
    }
    counts[@intCast(omit_pos)] = @as(i32, @intCast(range)) - total_count;
    if (counts[@intCast(omit_pos)] <= 0) return error.GenericError;

    return counts;
}

/// Decode HybridUintConfig from bitstream.
pub fn decodeUintConfig(log_alpha_size: u5, br: *BitReader) JxlError!HybridUintConfig {
    br.refill();
    const split_exponent: u32 = @intCast(br.readBits(
        bits_mod.ceilLog2Nonzero(@as(u32, @as(u32, log_alpha_size) + 1)),
    ));
    var msb_in_token: u32 = 0;
    var lsb_in_token: u32 = 0;
    if (split_exponent != log_alpha_size) {
        const nbits1 = bits_mod.ceilLog2Nonzero(split_exponent + 1);
        msb_in_token = @intCast(br.readBits(nbits1));
        if (msb_in_token > split_exponent) return error.GenericError;
        const nbits2 = bits_mod.ceilLog2Nonzero(split_exponent - msb_in_token + 1);
        lsb_in_token = @intCast(br.readBits(nbits2));
    }
    if (lsb_in_token + msb_in_token > split_exponent) return error.GenericError;
    return HybridUintConfig.init(split_exponent, msb_in_token, lsb_in_token);
}

/// Decode multiple HybridUintConfigs from bitstream.
pub fn decodeUintConfigs(log_alpha_size: u5, configs: []HybridUintConfig, br: *BitReader) JxlError!void {
    for (configs) |*cfg| {
        cfg.* = try decodeUintConfig(log_alpha_size, br);
    }
}

// ── ANSSymbolReader ──

pub const ANSSymbolReader = struct {
    alias_tables: [*]const AliasTable.Entry,
    huffman_data: []const HuffmanDecodingData,
    use_prefix_code: bool,
    state: u32 = params.ans_signature << 16,
    configs: []const HybridUintConfig,
    log_alpha_size: u5 = 0,
    log_entry_size: u5 = 0,
    entry_size_minus_1: u32 = 0,

    // LZ77 state
    lz77_window: ?[]u32 = null,
    num_decoded: u32 = 0,
    num_to_copy: u32 = 0,
    copy_pos: u32 = 0,
    lz77_ctx: u32 = 0,
    lz77_min_length: u32 = 0,
    lz77_threshold: u32 = 1 << 20,
    lz77_length_uint: HybridUintConfig = HybridUintConfig.initDefault(),
    special_distances_cache: [num_special_distances]u32 = .{0} ** num_special_distances,
    num_special_distances_cached: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn create(
        code: *const ANSCode,
        br: *BitReader,
        distance_multiplier: usize,
        allocator: std.mem.Allocator,
    ) !ANSSymbolReader {
        var self = ANSSymbolReader{
            .alias_tables = if (code.alias_tables.len > 0) code.alias_tables.ptr else undefined_entry_ptr,
            .huffman_data = code.huffman_data,
            .use_prefix_code = code.use_prefix_code,
            .configs = code.uint_config,
            .allocator = allocator,
        };

        if (!code.use_prefix_code) {
            self.state = @intCast(br.readBits(32));
            self.log_alpha_size = code.log_alpha_size;
            self.log_entry_size = @intCast(@as(u32, params.ans_log_tab_size) - @as(u32, code.log_alpha_size));
            self.entry_size_minus_1 = (@as(u32, 1) << self.log_entry_size) - 1;
        } else {
            self.state = params.ans_signature << 16;
        }

        if (code.lz77.enabled) {
            self.lz77_window = try allocator.alloc(u32, window_size);
            @memset(self.lz77_window.?, 0);
            self.lz77_ctx = @intCast(code.lz77.nonserialized_distance_context);
            self.lz77_length_uint = code.lz77.length_uint_config;
            self.lz77_threshold = code.lz77.min_symbol;
            self.lz77_min_length = code.lz77.min_length;
            self.num_special_distances_cached = if (distance_multiplier == 0) 0 else num_special_distances;
            for (0..self.num_special_distances_cached) |i| {
                self.special_distances_cache[i] = @intCast(specialDistance(i, @intCast(distance_multiplier)));
            }
        }

        return self;
    }

    pub fn deinit(self: *ANSSymbolReader) void {
        if (self.lz77_window) |w| {
            self.allocator.free(w);
            self.lz77_window = null;
        }
    }

    const undefined_entry_ptr: [*]const AliasTable.Entry = @ptrFromInt(0x1);

    pub fn readSymbolANSWithoutRefill(self: *ANSSymbolReader, histo_idx: usize, br: *BitReader) usize {
        const res = self.state & params.ans_tab_mask;
        const table = self.alias_tables + (histo_idx << self.log_alpha_size);
        const symbol = AliasTable.lookup(table, res, self.log_entry_size, self.entry_size_minus_1);
        self.state = @intCast(@as(u64, symbol.freq) * @as(u64, self.state >> params.ans_log_tab_size) + symbol.offset);

        // Branchless normalization
        const new_state = (self.state << 16) | @as(u32, @intCast(br.peekFixedBits(16)));
        const normalize = self.state < (1 << 16);
        self.state = if (normalize) new_state else self.state;
        br.consume(if (normalize) 16 else 0);

        return symbol.value;
    }

    pub fn readSymbolHuffWithoutRefill(self: *ANSSymbolReader, histo_idx: usize, br: *BitReader) usize {
        return self.huffman_data[histo_idx].readSymbol(br);
    }

    pub fn readSymbolWithoutRefill(self: *ANSSymbolReader, histo_idx: usize, br: *BitReader) usize {
        if (self.use_prefix_code) {
            return self.readSymbolHuffWithoutRefill(histo_idx, br);
        }
        return self.readSymbolANSWithoutRefill(histo_idx, br);
    }

    pub fn readSymbol(self: *ANSSymbolReader, histo_idx: usize, br: *BitReader) usize {
        br.refill();
        return self.readSymbolWithoutRefill(histo_idx, br);
    }

    fn readHybridUintConfigValue(config: HybridUintConfig, token: usize, br: *BitReader) u32 {
        if (token < config.split_token) return @intCast(token);
        var nbits: u32 = config.split_exponent - (config.msb_in_token + config.lsb_in_token) +
            @as(u32, @intCast((token - config.split_token) >> @intCast(config.msb_in_token + config.lsb_in_token)));
        nbits &= 31;
        const low: u32 = @intCast(token & ((@as(usize, 1) << @intCast(config.lsb_in_token)) - 1));
        const shifted_token = token >> @intCast(config.lsb_in_token);
        const bits_val: u32 = @intCast(br.peekBits(nbits));
        br.consume(nbits);
        const msb_mask: u32 = (@as(u32, 1) << @intCast(config.msb_in_token)) - 1;
        return (((@as(u32, 1) << @intCast(config.msb_in_token)) |
            @as(u32, @intCast(shifted_token & msb_mask))) << @intCast(nbits) | bits_val) <<
            @intCast(config.lsb_in_token) | low;
    }

    /// Read a hybrid uint using LZ77 if enabled.
    pub fn readHybridUintClustered(self: *ANSSymbolReader, ctx: usize, br: *BitReader, uses_lz77: bool) usize {
        if (uses_lz77) {
            if (self.num_to_copy > 0) {
                const ret = self.lz77_window.?[self.copy_pos & window_mask];
                self.copy_pos +%= 1;
                self.num_to_copy -= 1;
                self.lz77_window.?[self.num_decoded & window_mask] = ret;
                self.num_decoded +%= 1;
                return ret;
            }
        }

        br.refill();
        const token = self.readSymbolWithoutRefill(ctx, br);
        if (uses_lz77) {
            if (token >= self.lz77_threshold) {
                self.num_to_copy = readHybridUintConfigValue(
                    self.lz77_length_uint,
                    token - self.lz77_threshold,
                    br,
                ) + self.lz77_min_length;
                br.refill();
                const d_token = self.readSymbolWithoutRefill(self.lz77_ctx, br);
                var distance: usize = readHybridUintConfigValue(self.configs[self.lz77_ctx], d_token, br);
                if (distance < self.num_special_distances_cached) {
                    distance = self.special_distances_cache[distance];
                } else {
                    distance = distance + 1 - self.num_special_distances_cached;
                }
                if (distance > self.num_decoded) distance = self.num_decoded;
                if (distance > window_size) distance = window_size;
                self.copy_pos = self.num_decoded -% @as(u32, @intCast(distance));
                if (distance == 0) {
                    const to_fill = @min(self.num_to_copy, window_size);
                    @memset(self.lz77_window.?[0..to_fill], 0);
                }
                if (self.num_to_copy < self.lz77_min_length) return 0;

                const ret = self.lz77_window.?[self.copy_pos & window_mask];
                self.copy_pos +%= 1;
                self.num_to_copy -= 1;
                self.lz77_window.?[self.num_decoded & window_mask] = ret;
                self.num_decoded +%= 1;
                return ret;
            }
        }
        const ret: usize = readHybridUintConfigValue(self.configs[ctx], token, br);
        if (uses_lz77) {
            if (self.lz77_window) |w| {
                w[self.num_decoded & window_mask] = @intCast(ret);
                self.num_decoded +%= 1;
            }
        }
        return ret;
    }

    pub fn readHybridUint(self: *ANSSymbolReader, ctx: usize, br: *BitReader, context_map: []const u8) usize {
        return self.readHybridUintClustered(context_map[ctx], br, true);
    }

    pub fn checkANSFinalState(self: *const ANSSymbolReader) bool {
        return self.state == (params.ans_signature << 16);
    }
};

// ── DecodeHistograms ──

const dec_context_map = @import("dec_context_map.zig");

/// Top-level function: reads LZ77 params, context map, uint configs,
/// and per-histogram ANS/Huffman codes into an ANSCode.
/// Returns the context map (caller must free).
pub fn decodeHistograms(
    allocator: std.mem.Allocator,
    br: *BitReader,
    num_contexts_in: usize,
    code: *ANSCode,
) JxlError![]u8 {
    var num_contexts = num_contexts_in;

    // Read LZ77 params
    code.lz77 = LZ77Params.readFromBitStream(br);
    if (code.lz77.enabled) {
        num_contexts += 1;
        code.lz77.length_uint_config = decodeUintConfig(8, br) catch return error.GenericError;
    }

    // Read context map
    const context_map = try allocator.alloc(u8, num_contexts);
    errdefer allocator.free(context_map);

    var num_histograms: usize = 1;
    if (num_contexts > 1) {
        dec_context_map.decodeContextMap(context_map, &num_histograms, br) catch return error.GenericError;
    } else {
        @memset(context_map, 0);
    }

    // Distance context is the last entry
    code.lz77.nonserialized_distance_context = context_map[num_contexts - 1];

    // Prefix code flag
    code.use_prefix_code = br.readBits(1) != 0;
    if (code.use_prefix_code) {
        code.log_alpha_size = params.prefix_max_bits;
    } else {
        code.log_alpha_size = @intCast(@as(u32, @intCast(br.readBits(2))) + 5);
    }

    // Read uint configs (one per histogram)
    const uint_configs = try allocator.alloc(HybridUintConfig, num_histograms);
    errdefer allocator.free(uint_configs);
    decodeUintConfigs(code.log_alpha_size, uint_configs, br) catch return error.GenericError;
    code.uint_config = uint_configs;

    // Read per-histogram codes
    const degenerate_syms = try allocator.alloc(i32, num_histograms);
    errdefer allocator.free(degenerate_syms);
    @memset(degenerate_syms, -1);
    code.degenerate_symbols = degenerate_syms;

    const max_alphabet_size: usize = @as(usize, 1) << code.log_alpha_size;

    if (code.use_prefix_code) {
        // Huffman mode
        const huff_data = try allocator.alloc(HuffmanDecodingData, num_histograms);
        errdefer allocator.free(huff_data);
        for (huff_data) |*hd| {
            hd.* = HuffmanDecodingData.init(allocator);
        }

        // Read alphabet sizes
        var alphabet_sizes = try allocator.alloc(u16, num_histograms);
        defer allocator.free(alphabet_sizes);
        for (0..num_histograms) |c| {
            br.refill();
            alphabet_sizes[c] = @intCast(decodeVarLenUint16(br) + 1);
            if (@as(usize, alphabet_sizes[c]) > max_alphabet_size) {
                return error.GenericError;
            }
        }

        // Read Huffman tables
        for (0..num_histograms) |c| {
            if (alphabet_sizes[c] > 1) {
                const ok = huff_data[c].readFromBitStream(alphabet_sizes[c], br) catch return error.GenericError;
                if (!ok) return error.GenericError;
            }
            // UpdateMaxNumBits for Huffman symbols
            for (huff_data[c].table) |h| {
                if (h.bits <= huffman_mod.huffman_table_bits) {
                    code.updateMaxNumBits(c, h.value);
                }
            }
        }
        code.huffman_data = huff_data;
    } else {
        // ANS mode
        const table_size = num_histograms * (@as(usize, 1) << code.log_alpha_size);
        const alias_tables = try allocator.alloc(AliasTable.Entry, table_size);
        errdefer allocator.free(alias_tables);

        for (0..num_histograms) |c| {
            br.refill();
            var counts = readHistogram(allocator, params.ans_log_tab_size, br) catch return error.GenericError;
            defer allocator.free(counts);

            if (counts.len > max_alphabet_size) return error.GenericError;

            // Trim trailing zeros
            var trim_len = counts.len;
            while (trim_len > 0 and counts[trim_len - 1] == 0) {
                trim_len -= 1;
            }

            // UpdateMaxNumBits for non-zero symbols
            for (0..trim_len) |s| {
                if (counts[s] != 0) {
                    code.updateMaxNumBits(c, s);
                }
            }

            // Compute degenerate symbol
            const degen: i32 = if (trim_len == 0) 0 else @intCast(trim_len - 1);
            var is_degen = true;
            for (0..@as(usize, @intCast(if (degen >= 0) degen else 0))) |s| {
                if (counts[s] != 0) {
                    is_degen = false;
                    break;
                }
            }
            degenerate_syms[c] = if (is_degen) degen else -1;

            // Init alias table for this histogram
            const offset = c * (@as(usize, 1) << code.log_alpha_size);
            ans_common.initAliasTable(
                counts[0..trim_len],
                params.ans_log_tab_size,
                code.log_alpha_size,
                alias_tables.ptr + offset,
            ) catch return error.GenericError;
        }
        code.alias_tables = alias_tables;
    }

    return context_map;
}

// ── Tests ──

const testing = std.testing;

test "specialDistance basic" {
    try testing.expectEqual(@as(i32, 1), specialDistance(0, 1));  // {0,1}: 0+1*1=1
    try testing.expectEqual(@as(i32, 1), specialDistance(1, 1));  // {1,0}: 1+1*0=1
    try testing.expectEqual(@as(i32, 2), specialDistance(2, 1));  // {1,1}: 1+1*1=2
    try testing.expectEqual(@as(i32, 1), specialDistance(3, 1));  // {-1,1}: -1+1*1=0 -> clamped to 1
    try testing.expectEqual(@as(i32, 2), specialDistance(0, 2));  // {0,1}: 0+2*1=2
}

test "decodeVarLenUint8 zero" {
    var data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = decodeVarLenUint8(&br);
    try testing.expectEqual(@as(u32, 0), result);
}

test "decodeVarLenUint8 one" {
    // bit 0 = 1 (flag), bits 1-3 = 000 (nbits=0) => result = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const result = decodeVarLenUint8(&br);
    try testing.expectEqual(@as(u32, 1), result);
}

test "LZ77Params disabled" {
    var data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const lz77 = LZ77Params.readFromBitStream(&br);
    try testing.expect(!lz77.enabled);
}

test "LZ77Params enabled defaults" {
    // bit 0 = 1 (enabled), bits 1-2 = 00 (min_symbol selector 0 = 224),
    // bits 3-4 = 00 (min_length selector 0 = 3)
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const lz77 = LZ77Params.readFromBitStream(&br);
    try testing.expect(lz77.enabled);
    try testing.expectEqual(@as(u32, 224), lz77.min_symbol);
    try testing.expectEqual(@as(u32, 3), lz77.min_length);
}

test "readHistogram simple single symbol" {
    const allocator = testing.allocator;
    // simple_code=1, num_symbols-1=0, symbol=0 (VarLenUint8: flag=0 => 0)
    // So: 1 bit (simple=1), 1 bit (num_symbols-1=0), 1 bit (varlen flag=0)
    // Binary: 1, 0, 0, ... = 0b001 = 0x01
    var data = [_]u8{ 0b00000101, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);

    const counts = try readHistogram(allocator, 12, &br);
    defer allocator.free(counts);

    // Single symbol 0 with full range
    try testing.expectEqual(@as(usize, 1), counts.len);
    try testing.expectEqual(@as(i32, 4096), counts[0]);
}

test "ANSCode init and deinit" {
    const allocator = testing.allocator;
    var code = ANSCode.init(allocator);
    defer code.deinit();
    try testing.expect(!code.use_prefix_code);
    try testing.expectEqual(@as(usize, 0), code.max_num_bits);
}
