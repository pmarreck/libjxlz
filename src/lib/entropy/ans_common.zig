// ANS common types and functions.
// Transliterated from lib/jxl/ans_common.h and lib/jxl/ans_common.cc

const std = @import("std");
const params = @import("ans_params.zig");
const status_mod = @import("../base/status.zig");
const JxlError = status_mod.JxlError;

/// Returns the precision (number of bits) that should be used to store
/// a histogram count such that Log2Floor(count) == logcount.
pub fn getPopulationCountPrecision(logcount: u32, shift: u32) u32 {
    // C++: std::min<int>(logcount, (int)shift - (int)((ANS_LOG_TAB_SIZE - logcount) >> 1))
    const signed_shift: i32 = @intCast(shift);
    const signed_logcount: i32 = @intCast(logcount);
    const ans_log: u32 = @as(u32, params.ans_log_tab_size);
    const r = @min(
        signed_logcount,
        signed_shift - @as(i32, @intCast((ans_log -| logcount) >> 1)),
    );
    if (r < 0) return 0;
    return @intCast(r);
}

/// Returns a histogram where the counts are positive, differ by at most 1,
/// and add up to total_count. The bigger counts (if any) are at the beginning.
pub fn createFlatHistogram(allocator: std.mem.Allocator, length: usize, total_count: usize) ![]i32 {
    std.debug.assert(length > 0);
    std.debug.assert(length <= total_count);
    const count: i32 = @intCast(total_count / length);
    const result = try allocator.alloc(i32, length);
    @memset(result, count);
    const rem_counts = total_count % length;
    for (0..rem_counts) |i| {
        result[i] += 1;
    }
    return result;
}

/// An alias table implements a mapping from the [0, ANS_TAB_SIZE) range into
/// the [0, ANS_MAX_ALPHABET_SIZE) range.
pub const AliasTable = struct {
    pub const Symbol = struct {
        value: usize,
        offset: usize,
        freq: usize,
    };

    /// Working set size matters here (~64 tables x 256 entries).
    /// Packed for cache efficiency.
    pub const Entry = packed struct {
        cutoff: u8,
        right_value: u8,
        freq0: u16,
        offsets1: u16,
        freq1_xor_freq0: u16,
    };

    /// Looks up a value in the alias table, returning the symbol, offset, and frequency.
    pub fn lookup(table: [*]const Entry, value: usize, log_entry_size: usize, entry_size_minus_1: usize) Symbol {
        const i = value >> @intCast(log_entry_size);
        const pos = value & entry_size_minus_1;
        const entry = table[i];
        const cutoff: usize = entry.cutoff;
        const right_value: usize = entry.right_value;
        const freq0: usize = entry.freq0;

        const greater = pos >= cutoff;

        const offsets1_or_0: usize = if (greater) entry.offsets1 else 0;
        const freq1_xor_freq0_or_0: usize = if (greater) entry.freq1_xor_freq0 else 0;

        return .{
            .value = if (greater) right_value else i,
            .offset = offsets1_or_0 + pos,
            .freq = freq0 ^ freq1_xor_freq0_or_0,
        };
    }
};

/// Computes an alias table for a given distribution.
pub fn initAliasTable(
    distribution_in: []const i32,
    log_range: u5,
    log_alpha_size: u5,
    a: [*]AliasTable.Entry,
) JxlError!void {
    const range: u32 = @as(u32, 1) << log_range;
    const table_size: u32 = @as(u32, 1) << log_alpha_size;
    if (table_size > range) return error.GenericError;

    // Trim trailing zeros and handle empty distributions.
    var dist_len: usize = distribution_in.len;
    while (dist_len > 0 and distribution_in[dist_len - 1] == 0) {
        dist_len -= 1;
    }

    // Use a local copy to add placeholder if needed.
    // We'll work with a stack-allocated buffer for reasonable sizes,
    // or fallback to the input slice.
    var placeholder: [1]i32 = .{@intCast(range)};
    const distribution: []const i32 = if (dist_len == 0) &placeholder else distribution_in[0..dist_len];
    dist_len = distribution.len;

    if (dist_len > table_size) return error.GenericError;

    const entry_size: u32 = range >> log_alpha_size;

    // Check for single-symbol distribution.
    var single_symbol: i32 = -1;
    var sum: i32 = 0;
    for (distribution, 0..) |v, sym| {
        sum += v;
        if (v == @as(i32, @intCast(params.ans_tab_size))) {
            if (single_symbol != -1) return error.GenericError;
            single_symbol = @intCast(sym);
        }
    }
    if (@as(u32, @intCast(sum)) != range) return error.GenericError;

    if (single_symbol != -1) {
        const sym: u8 = @intCast(single_symbol);
        for (0..table_size) |i| {
            a[i] = .{
                .right_value = sym,
                .cutoff = 0,
                .offsets1 = @intCast(entry_size * @as(u32, @intCast(i))),
                .freq0 = 0,
                .freq1_xor_freq0 = params.ans_tab_size,
            };
        }
        return;
    }

    // Use allocator for cutoffs and stacks since table_size can be up to 256.
    var cutoffs: [256]u32 = undefined;
    var underfull: [256]u32 = undefined;
    var overfull: [256]u32 = undefined;
    var under_count: usize = 0;
    var over_count: usize = 0;

    // Initialize entries.
    for (0..dist_len) |i| {
        const c: u32 = @intCast(distribution[i]);
        cutoffs[i] = c;
        if (c > entry_size) {
            overfull[over_count] = @intCast(i);
            over_count += 1;
        } else if (c < entry_size) {
            underfull[under_count] = @intCast(i);
            under_count += 1;
        }
    }
    for (dist_len..table_size) |i| {
        cutoffs[i] = 0;
        underfull[under_count] = @intCast(i);
        under_count += 1;
    }

    // Reassign overflow/underflow values.
    while (over_count > 0) {
        over_count -= 1;
        const overfull_i = overfull[over_count];
        if (under_count == 0) return error.GenericError;
        under_count -= 1;
        const underfull_i = underfull[under_count];
        const underfull_by = entry_size - cutoffs[underfull_i];
        cutoffs[overfull_i] -= underfull_by;
        a[underfull_i].right_value = @intCast(overfull_i);
        a[underfull_i].offsets1 = @intCast(cutoffs[overfull_i]);
        if (cutoffs[overfull_i] < entry_size) {
            underfull[under_count] = overfull_i;
            under_count += 1;
        } else if (cutoffs[overfull_i] > entry_size) {
            overfull[over_count] = overfull_i;
            over_count += 1;
        }
    }

    for (0..table_size) |i| {
        if (cutoffs[i] == entry_size) {
            a[i].right_value = @intCast(i);
            a[i].offsets1 = 0;
            a[i].cutoff = 0;
        } else {
            a[i].offsets1 -= @intCast(cutoffs[i]);
            a[i].cutoff = @intCast(cutoffs[i]);
        }
        const freq0: u16 = if (i < dist_len) @intCast(distribution[i]) else 0;
        const rv_idx: usize = a[i].right_value;
        const freq1: u16 = if (rv_idx < dist_len) @intCast(distribution[rv_idx]) else 0;
        a[i].freq0 = freq0;
        a[i].freq1_xor_freq0 = freq1 ^ freq0;
    }
}

// ── Tests ──

const testing = std.testing;

test "getPopulationCountPrecision basic values" {
    // When logcount is 0, result should be 0
    try testing.expectEqual(@as(u32, 0), getPopulationCountPrecision(0, 0));

    // Some known cases from the C++ implementation
    // getPopulationCountPrecision(0, 3) = min(0, 3 - (12-0)>>1) = min(0, 3-6) = min(0,-3) -> 0
    try testing.expectEqual(@as(u32, 0), getPopulationCountPrecision(0, 3));
    // getPopulationCountPrecision(1, 3) = min(1, 3 - (12-1)>>1) = min(1, 3-5) = min(1,-2) -> 0
    try testing.expectEqual(@as(u32, 0), getPopulationCountPrecision(1, 3));
    // getPopulationCountPrecision(10, 12) = min(10, 12 - (12-10)>>1) = min(10, 12-1) = 10
    try testing.expectEqual(@as(u32, 10), getPopulationCountPrecision(10, 12));
    // getPopulationCountPrecision(5, 7) = min(5, 7 - (12-5)>>1) = min(5, 7-3) = min(5,4) = 4
    try testing.expectEqual(@as(u32, 4), getPopulationCountPrecision(5, 7));
}

test "createFlatHistogram" {
    const allocator = testing.allocator;

    // Equal distribution
    const hist = try createFlatHistogram(allocator, 4, 16);
    defer allocator.free(hist);
    for (hist) |c| {
        try testing.expectEqual(@as(i32, 4), c);
    }

    // Unequal distribution: 10 / 3 = 3 rem 1
    const hist2 = try createFlatHistogram(allocator, 3, 10);
    defer allocator.free(hist2);
    try testing.expectEqual(@as(i32, 4), hist2[0]); // first gets extra
    try testing.expectEqual(@as(i32, 3), hist2[1]);
    try testing.expectEqual(@as(i32, 3), hist2[2]);

    // Sum must equal total_count
    var sum: i32 = 0;
    for (hist2) |c| sum += c;
    try testing.expectEqual(@as(i32, 10), sum);
}

test "AliasTable.Entry is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(AliasTable.Entry));
}

test "initAliasTable single symbol" {
    var table: [4]AliasTable.Entry = undefined;
    // Distribution: symbol 0 has all the weight
    const dist = [_]i32{4096};
    try initAliasTable(&dist, 12, 2, &table);

    // All entries should map to symbol 0
    for (0..4) |i| {
        const sym = AliasTable.lookup(&table, i * 1024 + 500, 10, 1023);
        try testing.expectEqual(@as(usize, 0), sym.value);
        try testing.expectEqual(@as(usize, params.ans_tab_size), sym.freq);
    }
}

test "initAliasTable two symbols" {
    var table: [4]AliasTable.Entry = undefined;
    // Distribution: symbol 0 has 2048, symbol 1 has 2048
    const dist = [_]i32{ 2048, 2048 };
    try initAliasTable(&dist, 12, 2, &table);

    // Verify that lookups across the full range produce correct frequencies
    var count0: usize = 0;
    var count1: usize = 0;
    for (0..params.ans_tab_size) |v| {
        const sym = AliasTable.lookup(&table, v, 10, 1023);
        if (sym.value == 0) count0 += 1 else count1 += 1;
    }
    try testing.expectEqual(@as(usize, 2048), count0);
    try testing.expectEqual(@as(usize, 2048), count1);
}

test "initAliasTable empty distribution gets placeholder" {
    var table: [4]AliasTable.Entry = undefined;
    const dist = [_]i32{};
    try initAliasTable(&dist, 12, 2, &table);

    // Should create a valid table with placeholder symbol 0
    const sym = AliasTable.lookup(&table, 0, 10, 1023);
    try testing.expectEqual(@as(usize, 0), sym.value);
}
