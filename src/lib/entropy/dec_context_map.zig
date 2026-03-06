// Context map decoder.
// Transliterated from lib/jxl/dec_context_map.h and lib/jxl/dec_context_map.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const inverse_mtf = @import("inverse_mtf.zig");

const max_clusters: usize = 256;

fn verifyContextMap(context_map: []const u8, num_htrees: usize) JxlError!void {
    var have_htree = [_]bool{false} ** max_clusters;
    var num_found: usize = 0;
    for (context_map) |htree| {
        if (htree >= num_htrees) return error.GenericError;
        if (!have_htree[htree]) {
            have_htree[htree] = true;
            num_found += 1;
        }
    }
    if (num_found != num_htrees) return error.GenericError;
}

/// Decodes the context map from the bitstream.
/// On entry, context_map must already be sized to the number of context IDs.
/// On return, *num_htrees is set to the number of distinct histogram IDs.
pub fn decodeContextMap(
    context_map: []u8,
    num_htrees: *usize,
    br: *BitReader,
) JxlError!void {
    const is_simple = br.readBits(1) != 0;
    if (is_simple) {
        const bits_per_entry: u5 = @intCast(br.readBits(2));
        if (bits_per_entry != 0) {
            for (context_map) |*entry| {
                entry.* = @intCast(br.readBits(bits_per_entry));
            }
        } else {
            @memset(context_map, 0);
        }
    } else {
        const use_mtf = br.readBits(1) != 0;
        // For the non-simple case, we need a full ANS reader to decode the
        // context map entries. This creates a circular dependency with dec_ans.
        // For now, we expose this as a separate path that will be wired up
        // from DecodeHistograms.
        // TODO: Wire up the ANS-based context map decoding path.
        _ = use_mtf;
        return error.Unsupported;
    }

    // Compute num_htrees = max + 1
    var max_val: u8 = 0;
    for (context_map) |v| {
        if (v > max_val) max_val = v;
    }
    num_htrees.* = @as(usize, max_val) + 1;
    try verifyContextMap(context_map, num_htrees.*);
}

// ── Tests ──

const testing = std.testing;

test "verifyContextMap valid" {
    const map = [_]u8{ 0, 1, 0, 1 };
    try verifyContextMap(&map, 2);
}

test "verifyContextMap invalid index" {
    const map = [_]u8{ 0, 3, 0, 1 };
    try testing.expectError(error.GenericError, verifyContextMap(&map, 2));
}

test "verifyContextMap incomplete" {
    const map = [_]u8{ 0, 0, 0, 0 };
    try testing.expectError(error.GenericError, verifyContextMap(&map, 2));
}

test "decodeContextMap simple all zeros" {
    // is_simple=1, bits_per_entry=0
    // Binary: bit0=1 (simple), bits1-2=00 (0 bits per entry)
    var data = [_]u8{ 0b00000001, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var num_htrees: usize = 0;

    try decodeContextMap(&map, &num_htrees, &br);
    try testing.expectEqual(@as(usize, 1), num_htrees);
    for (map) |v| {
        try testing.expectEqual(@as(u8, 0), v);
    }
}

test "decodeContextMap simple with bits" {
    // is_simple=1, bits_per_entry=1 (2 bits: 01)
    // Then 4 entries each 1 bit: 0,1,0,1 = bits 3,4,5,6 = 0101
    // Byte: bit0=1, bit1-2=01, bit3=0, bit4=1, bit5=0, bit6=1
    // = 0b_0101_0011 = 0x53
    var data = [_]u8{ 0b01010011, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    var map = [_]u8{ 0, 0, 0, 0 };
    var num_htrees: usize = 0;

    try decodeContextMap(&map, &num_htrees, &br);
    try testing.expectEqual(@as(usize, 2), num_htrees);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1 }, &map);
}
