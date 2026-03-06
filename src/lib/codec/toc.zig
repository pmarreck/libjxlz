// TOC (Table of Contents) reading: section sizes, permutation decoding.
// Transliterated from lib/jxl/toc.h/.cc, lib/jxl/coeff_order.cc, lib/jxl/lehmer_code.h

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");
const bits = @import("../base/bits.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const ANSCode = dec_ans.ANSCode;
const ANSSymbolReader = dec_ans.ANSSymbolReader;

// kTocDist: U32(Bits(10), BitsOffset(14,1024), BitsOffset(22,17408), BitsOffset(30,4211712))
const kTocDist = fc.U32Enc.init(fc.bits(10), fc.bitsOffset(14, 1024), fc.bitsOffset(22, 17408), fc.bitsOffset(30, 4211712));

const kPermutationContexts: usize = 8;

pub const TocEntry = struct {
    size: u32 = 0,
    id: usize = 0, // logical section ID
};

/// Compute TOC index for an AC group at (pass, group).
pub fn acGroupIndex(pass: usize, group: usize, num_groups: usize, num_dc_groups: usize) usize {
    return 2 + num_dc_groups + pass * num_groups + group;
}

/// Total number of TOC entries for a frame.
pub fn numTocEntries(num_groups: usize, num_dc_groups: usize, num_passes: usize) usize {
    if (num_groups == 1 and num_passes == 1) return 1;
    return acGroupIndex(0, 0, num_groups, num_dc_groups) + num_groups * num_passes;
}

/// Compute permutation context from value (matches CoeffOrderContext in C++).
fn coeffOrderContext(val: u32) usize {
    // HybridUintConfig(0,0,0).Encode gives token = val for small values
    // Then min(token, kPermutationContexts - 1)
    return @min(@as(usize, val), kPermutationContexts - 1);
}

/// Decode Lehmer code into permutation.
fn decodeLehmerCode(code: []const u32, temp: []u32, n: usize, permutation: []u32) JxlError!void {
    if (n == 0) return error.GenericError;

    const log2n = bits.ceilLog2Nonzero(n);
    const padded_n: usize = @as(usize, 1) << @intCast(log2n);

    // Initialize Fenwick tree
    for (0..padded_n) |i| {
        const ip1: u32 = @intCast(i + 1);
        temp[i] = ip1 & (~ip1 +% 1); // ValueOfLowest1Bit(i+1)
    }

    for (0..n) |i| {
        if (code[i] + @as(u32, @intCast(i)) >= n) return error.GenericError;
        var rank: u32 = code[i] + 1;

        // Extract i-th unused element via implicit order-statistics tree
        var bit: usize = padded_n;
        var next: usize = 0;
        for (0..log2n + 1) |_| {
            const cand = next + bit;
            if (cand < 1) return error.GenericError;
            bit >>= 1;
            if (cand - 1 < temp.len and temp[cand - 1] < rank) {
                next = cand;
                rank -= temp[cand - 1];
            }
        }

        permutation[i] = @intCast(next);

        // Mark as used
        next += 1;
        while (next <= padded_n) {
            if (next - 1 < temp.len) {
                temp[next - 1] -= 1;
            }
            next += next & (~next +% 1); // next += ValueOfLowest1Bit(next)
        }
    }
}

/// Decode a permutation from the bitstream using ANS-coded Lehmer codes.
pub fn decodePermutation(allocator: std.mem.Allocator, skip: usize, size: usize, br: *BitReader) JxlError![]u32 {
    // Read ANS histograms for permutation contexts
    var code = ANSCode.init(allocator);
    defer code.deinit();
    const ctx_map = dec_ans.decodeHistograms(allocator, br, kPermutationContexts, &code) catch return error.GenericError;
    defer allocator.free(ctx_map);

    var reader = ANSSymbolReader.create(&code, br, 0, allocator) catch return error.GenericError;
    defer reader.deinit();

    // Read Lehmer codes
    const lehmer = allocator.alloc(u32, size) catch return error.GenericError;
    defer allocator.free(lehmer);
    @memset(lehmer, 0);

    const end_val: u32 = @intCast(reader.readHybridUint(coeffOrderContext(@intCast(size)), br, ctx_map));
    const end = @as(usize, end_val) + skip;
    if (end > size) return error.GenericError;

    var last: u32 = 0;
    for (skip..end) |i| {
        lehmer[i] = @intCast(reader.readHybridUint(coeffOrderContext(last), br, ctx_map));
        last = lehmer[i];
        if (lehmer[i] >= size - i) return error.GenericError;
    }

    if (!reader.checkANSFinalState()) return error.GenericError;

    // Decode Lehmer code into permutation
    const padded_n: usize = @as(usize, 1) << @intCast(bits.ceilLog2Nonzero(size));
    const temp = allocator.alloc(u32, padded_n) catch return error.GenericError;
    defer allocator.free(temp);

    const permutation = allocator.alloc(u32, size) catch return error.GenericError;
    errdefer allocator.free(permutation);

    decodeLehmerCode(lehmer, temp, size, permutation) catch return error.GenericError;

    return permutation;
}

/// Read TOC (Table of Contents) from bitstream.
/// Returns array of TocEntry with size and logical ID.
pub fn readToc(allocator: std.mem.Allocator, toc_entries: usize, br: *BitReader) JxlError![]TocEntry {
    if (toc_entries > 65536) return error.GenericError;
    if (toc_entries == 0) return error.GenericError;

    // Read optional permutation
    var permutation: ?[]u32 = null;
    defer if (permutation) |p| allocator.free(p);

    if (br.readBits(1) == 1) {
        permutation = try decodePermutation(allocator, 0, toc_entries, br);
    }

    try br.jumpToByteBoundary();

    // Read section sizes
    const sizes = allocator.alloc(u32, toc_entries) catch return error.GenericError;
    defer allocator.free(sizes);

    for (0..toc_entries) |i| {
        sizes[i] = fc.U32Coder.read(kTocDist, br);
    }

    try br.jumpToByteBoundary();

    // Build TocEntry array
    const toc = allocator.alloc(TocEntry, toc_entries) catch return error.GenericError;
    errdefer allocator.free(toc);

    for (0..toc_entries) |i| {
        toc[i].size = sizes[i];
        const index: usize = if (permutation) |p| p[i] else i;
        if (index >= toc_entries) return error.GenericError;
        toc[index].id = i;
    }

    return toc;
}

/// Compute group offsets from TOC sizes. Returns offsets array and total size.
pub fn computeGroupOffsets(allocator: std.mem.Allocator, toc: []const TocEntry) !struct { offsets: []u64, total_size: u64 } {
    const offsets = try allocator.alloc(u64, toc.len);
    var offset: u64 = 0;
    for (0..toc.len) |i| {
        offsets[i] = offset;
        offset += toc[i].size;
    }
    return .{ .offsets = offsets, .total_size = offset };
}

// ── Tests ──

const testing = std.testing;

test "numTocEntries single group" {
    try testing.expectEqual(@as(usize, 1), numTocEntries(1, 1, 1));
}

test "numTocEntries multiple groups" {
    // 4 groups, 2 dc groups, 2 passes
    // = 2 + 2 + 0 * 4 + 0 + 4 * 2 = 12
    try testing.expectEqual(@as(usize, 12), numTocEntries(4, 2, 2));
}

test "acGroupIndex" {
    // pass=0, group=0, num_groups=4, num_dc_groups=2
    try testing.expectEqual(@as(usize, 4), acGroupIndex(0, 0, 4, 2));
    // pass=1, group=2
    try testing.expectEqual(@as(usize, 10), acGroupIndex(1, 2, 4, 2));
}

test "decodeLehmerCode identity" {
    // Lehmer code [0,0,0,0] = identity permutation
    const code = [_]u32{ 0, 0, 0, 0 };
    var temp: [4]u32 = undefined;
    var perm: [4]u32 = undefined;
    try decodeLehmerCode(&code, &temp, 4, &perm);
    try testing.expectEqual(@as(u32, 0), perm[0]);
    try testing.expectEqual(@as(u32, 1), perm[1]);
    try testing.expectEqual(@as(u32, 2), perm[2]);
    try testing.expectEqual(@as(u32, 3), perm[3]);
}

test "decodeLehmerCode reverse" {
    // Lehmer code [3,2,1,0] = reverse permutation [3,2,1,0]
    const code = [_]u32{ 3, 2, 1, 0 };
    var temp: [4]u32 = undefined;
    var perm: [4]u32 = undefined;
    try decodeLehmerCode(&code, &temp, 4, &perm);
    try testing.expectEqual(@as(u32, 3), perm[0]);
    try testing.expectEqual(@as(u32, 2), perm[1]);
    try testing.expectEqual(@as(u32, 1), perm[2]);
    try testing.expectEqual(@as(u32, 0), perm[3]);
}

test "coeffOrderContext" {
    try testing.expectEqual(@as(usize, 0), coeffOrderContext(0));
    try testing.expectEqual(@as(usize, 5), coeffOrderContext(5));
    try testing.expectEqual(@as(usize, 7), coeffOrderContext(7));
    try testing.expectEqual(@as(usize, 7), coeffOrderContext(100)); // clamped
}
