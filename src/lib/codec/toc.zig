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

pub const kPermutationContexts: usize = 8;
pub const kMaxPermutationSize: usize = 65536;

test "coefficient permutation contexts follow hybrid token bands" {
	// lib/jxl/coeff_order.cc uses the token from HybridUintConfig(0,0,0),
	// capped at context 7. Exhaust all coefficient ranks through DCT256.
	const bands = [_]struct { start: u32, end: u32, context: usize }{
		.{ .start = 0, .end = 1, .context = 0 },
		.{ .start = 1, .end = 2, .context = 1 },
		.{ .start = 2, .end = 4, .context = 2 },
		.{ .start = 4, .end = 8, .context = 3 },
		.{ .start = 8, .end = 16, .context = 4 },
		.{ .start = 16, .end = 32, .context = 5 },
		.{ .start = 32, .end = 64, .context = 6 },
		.{ .start = 64, .end = 65537, .context = 7 },
	};
	for (bands) |band| {
		for (band.start..band.end) |value|
			try std.testing.expectEqual(band.context, coeffOrderContext(@intCast(value)));
	}
	try std.testing.expectEqual(@as(usize, 7), coeffOrderContext(std.math.maxInt(u32)));
}

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
    const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
    return @min(HybridUintConfig.initZero().encode(val).token, kPermutationContexts - 1);
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

/// Read one permutation from a borrowed entropy stream. A null destination
/// consumes and validates an unused order. The stream owner checks final ANS
/// state after its last permutation. Complexity: O(size log size), or O(size)
/// with no allocation when discarding.
pub fn readPermutation(allocator: std.mem.Allocator, skip: usize, size: usize,
	output: ?[]u32, br: *BitReader, reader: *ANSSymbolReader,
	context_map: []const u8) JxlError!void
{
	if (size == 0 or size > kMaxPermutationSize or skip > size or
		context_map.len != kPermutationContexts) return error.GenericError;
	if (output) |dest| if (dest.len != size) return error.GenericError;
	const count = reader.readHybridUint(coeffOrderContext(@intCast(size)), br, context_map);
	if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
	if (count > size - skip) return error.GenericError;
	const lehmer: []u32 = if (output != null) try allocator.alloc(u32, size) else &.{};
	defer allocator.free(lehmer);
	@memset(lehmer, 0);
	var last: u32 = 0;
	for (skip..skip + count) |i| {
		const rank = reader.readHybridUint(coeffOrderContext(last), br, context_map);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (rank >= size - i) return error.GenericError;
		last = @intCast(rank);
		if (output != null) lehmer[i] = last;
	}
	if (output) |dest| {
		const padded_n = @as(usize, 1) << @intCast(bits.ceilLog2Nonzero(size));
		const temp = try allocator.alloc(u32, padded_n);
		defer allocator.free(temp);
		try decodeLehmerCode(lehmer, temp, size, dest);
	}
}

/// Decode a standalone ANS permutation, as used by the TOC.
pub fn decodePermutation(allocator: std.mem.Allocator, skip: usize, size: usize, br: *BitReader) JxlError![]u32 {
	if (size == 0 or size > kMaxPermutationSize or skip > size) return error.GenericError;
	var code = ANSCode.init(allocator);
	defer code.deinit();
	const contexts = try dec_ans.decodeHistograms(allocator, br, kPermutationContexts, &code);
	defer allocator.free(contexts);
	var reader = try ANSSymbolReader.create(&code, br, 0, allocator);
	defer reader.deinit();
	const permutation = try allocator.alloc(u32, size);
	errdefer allocator.free(permutation);
	try readPermutation(allocator, skip, size, permutation, br, &reader, contexts);
	if (!reader.checkANSFinalState()) return error.GenericError;
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
    try testing.expectEqual(@as(usize, 3), coeffOrderContext(5));
    try testing.expectEqual(@as(usize, 3), coeffOrderContext(7));
    try testing.expectEqual(@as(usize, 7), coeffOrderContext(100)); // clamped
}
