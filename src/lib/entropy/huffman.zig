// Huffman table building and decoding.
// Transliterated from lib/jxl/huffman_table.h, lib/jxl/huffman_table.cc,
// lib/jxl/dec_huffman.h, lib/jxl/dec_huffman.cc

const std = @import("std");
const params = @import("ans_params.zig");
const bits_mod = @import("../base/bits.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;

pub const huffman_table_bits: u5 = 8;

pub const HuffmanCode = struct {
    bits: u8,
    value: u16,
};

// ── BuildHuffmanTable ──

/// Returns reverse(reverse(key, len) + 1, len).
fn getNextKey(key: u32, len: u5) u32 {
    var step: u32 = @as(u32, 1) << @intCast(len - 1);
    const k = key;
    while (k & step != 0) {
        step >>= 1;
    }
    return (k & (step -% 1)) + step;
}

/// Stores code in table[0], table[step], table[2*step], ..., table[end-step].
fn replicateValue(table: [*]HuffmanCode, step: u32, end_val: u32, code: HuffmanCode) void {
    var e = end_val;
    while (e > 0) {
        e -= step;
        table[e] = code;
    }
}

/// Returns the table width of the next 2nd level table.
fn nextTableBitSize(count: *[params.prefix_max_bits + 1]u16, len: usize, root_bits: u5) usize {
    var left: usize = @as(usize, 1) << @intCast(len - @as(usize, root_bits));
    var l = len;
    while (l < params.prefix_max_bits) {
        if (left <= count[l]) break;
        left -= count[l];
        l += 1;
        left <<= 1;
    }
    return l - @as(usize, root_bits);
}

/// Builds a Huffman lookup table. Returns 0 on error, otherwise the table size.
pub fn buildHuffmanTable(
    root_table: [*]HuffmanCode,
    root_bits: u5,
    code_lengths: []const u8,
    count: *[params.prefix_max_bits + 1]u16,
) u32 {
    const code_lengths_size = code_lengths.len;
    if (code_lengths_size > @as(usize, 1) << params.prefix_max_bits) return 0;

    // Generate offsets and find max_length.
    var offset: [params.prefix_max_bits + 1]u16 = undefined;
    var max_length: usize = 1;
    {
        var sum: u16 = 0;
        for (1..params.prefix_max_bits + 1) |len| {
            offset[len] = sum;
            if (count[len] != 0) {
                sum += count[len];
                max_length = len;
            }
        }
    }

    // Sort symbols by length.
    var sorted_storage: [params.prefix_max_alphabet_size]u16 = undefined;
    const sorted = sorted_storage[0..code_lengths_size];
    for (0..code_lengths_size) |symbol| {
        if (code_lengths[symbol] != 0) {
            sorted[offset[code_lengths[symbol]]] = @intCast(symbol);
            offset[code_lengths[symbol]] += 1;
        }
    }

    var table = root_table;
    var table_bits: usize = root_bits;
    var table_size: u32 = @as(u32, 1) << @intCast(table_bits);
    var total_size: u32 = table_size;

    // Special case: only one value.
    if (offset[params.prefix_max_bits] == 1) {
        const code = HuffmanCode{ .bits = 0, .value = sorted[0] };
        for (0..total_size) |key| {
            table[key] = code;
        }
        return total_size;
    }

    // Fill in root table.
    if (table_bits > max_length) {
        table_bits = max_length;
        table_size = @as(u32, 1) << @intCast(table_bits);
    }

    var key: u32 = 0;
    var symbol: usize = 0;
    var code_bits: u8 = 1;
    var step: u32 = 2;
    while (true) {
        while (count[code_bits] != 0) {
            count[code_bits] -= 1;
            const code = HuffmanCode{ .bits = code_bits, .value = sorted[symbol] };
            symbol += 1;
            replicateValue(table + key, step, table_size, code);
            key = getNextKey(key, @intCast(code_bits));
        }
        step <<= 1;
        code_bits += 1;
        if (code_bits > @as(u8, @intCast(table_bits))) break;
    }

    // Replicate if root_bits != table_bits.
    while (total_size != table_size) {
        @memcpy(
            @as([*]HuffmanCode, @ptrCast(table + table_size))[0..table_size],
            @as([*]const HuffmanCode, @ptrCast(table))[0..table_size],
        );
        table_size <<= 1;
    }

    // Fill in 2nd level tables.
    const mask: u32 = total_size - 1;
    var low: i32 = -1;
    var len: usize = @as(usize, root_bits) + 1;
    step = 2;
    while (len <= max_length) : ({
        len += 1;
        step <<= 1;
    }) {
        while (count[@intCast(len)] != 0) {
            count[@intCast(len)] -= 1;
            if (@as(i32, @intCast(key & mask)) != low) {
                table = root_table + total_size;
                table_bits = nextTableBitSize(count, len, root_bits);
                table_size = @as(u32, 1) << @intCast(table_bits);
                total_size += table_size;
                low = @intCast(key & mask);
                root_table[@intCast(@as(u32, @intCast(low)))].bits = @intCast(table_bits + root_bits);
                root_table[@intCast(@as(u32, @intCast(low)))].value =
                    @intCast(@intFromPtr(table) / @sizeOf(HuffmanCode) -
                    @intFromPtr(root_table) / @sizeOf(HuffmanCode) -
                    @as(usize, @intCast(@as(u32, @intCast(low)))));
            }
            const code = HuffmanCode{
                .bits = @intCast(len - root_bits),
                .value = sorted[symbol],
            };
            symbol += 1;
            replicateValue(table + (key >> root_bits), step, table_size, code);
            key = getNextKey(key, @intCast(len));
        }
    }

    return total_size;
}

// ── HuffmanDecodingData ──

const code_length_codes: usize = 18;
const code_length_code_order = [code_length_codes]u8{
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};
const default_code_length: u8 = 8;
const code_length_repeat_code: u8 = 16;

pub const HuffmanDecodingData = struct {
    table: []HuffmanCode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HuffmanDecodingData {
        return .{
            .table = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HuffmanDecodingData) void {
        if (self.table.len > 0) {
            self.allocator.free(self.table);
            self.table = &.{};
        }
    }

    /// Reads a Huffman code from the bitstream.
    pub fn readSymbol(self: *const HuffmanDecodingData, br: *BitReader) u16 {
        const table_ptr: [*]const HuffmanCode = self.table.ptr;
        var t = table_ptr + br.peekBits(huffman_table_bits);
        var n_bits: usize = t[0].bits;
        if (n_bits > huffman_table_bits) {
            br.consume(huffman_table_bits);
            n_bits -= huffman_table_bits;
            t = table_ptr + t[0].value;
            t = t + br.peekBits(n_bits);
        }
        br.consume(t[0].bits);
        return t[0].value;
    }

    /// Reads Huffman code from bitstream and populates the decoding table.
    pub fn readFromBitStream(self: *HuffmanDecodingData, alphabet_size: usize, br: *BitReader) !bool {
        if (alphabet_size > @as(usize, 1) << params.prefix_max_bits) return false;

        const simple_code_or_skip: u32 = @intCast(br.readBits(2));
        if (simple_code_or_skip == 1) {
            self.table = try self.allocator.alloc(HuffmanCode, @as(usize, 1) << huffman_table_bits);
            return readSimpleCode(alphabet_size, br, self.table.ptr);
        }

        const code_lengths = try self.allocator.alloc(u8, alphabet_size);
        defer self.allocator.free(code_lengths);
        @memset(code_lengths, 0);

        var code_length_code_lengths_buf: [code_length_codes]u8 = .{0} ** code_length_codes;
        var space: i32 = 32;
        var num_codes: u32 = 0;

        // Static Huffman code for the code length code lengths.
        const huff = [16]HuffmanCode{
            .{ .bits = 2, .value = 0 }, .{ .bits = 2, .value = 4 },
            .{ .bits = 2, .value = 3 }, .{ .bits = 3, .value = 2 },
            .{ .bits = 2, .value = 0 }, .{ .bits = 2, .value = 4 },
            .{ .bits = 2, .value = 3 }, .{ .bits = 4, .value = 1 },
            .{ .bits = 2, .value = 0 }, .{ .bits = 2, .value = 4 },
            .{ .bits = 2, .value = 3 }, .{ .bits = 3, .value = 2 },
            .{ .bits = 2, .value = 0 }, .{ .bits = 2, .value = 4 },
            .{ .bits = 2, .value = 3 }, .{ .bits = 4, .value = 5 },
        };

        var i: usize = simple_code_or_skip;
        while (i < code_length_codes and space > 0) : (i += 1) {
            const code_len_idx = code_length_code_order[i];
            br.refill();
            const p = &huff[br.peekFixedBits(4)];
            br.consume(p.bits);
            const v: u8 = @intCast(p.value);
            code_length_code_lengths_buf[code_len_idx] = v;
            if (v != 0) {
                space -= @intCast(@as(u32, 32) >> @intCast(v));
                num_codes += 1;
            }
        }

        if (!((num_codes == 1 or space == 0) and
            readHuffmanCodeLengths(&code_length_code_lengths_buf, @intCast(alphabet_size), code_lengths, br)))
        {
            return false;
        }

        var counts: [16]u16 = .{0} ** 16;
        for (code_lengths) |cl| {
            counts[cl] += 1;
        }

        const alloc_size = alphabet_size + 376;
        self.table = try self.allocator.alloc(HuffmanCode, alloc_size);
        const table_size = buildHuffmanTable(
            self.table.ptr,
            huffman_table_bits,
            code_lengths,
            &counts,
        );
        if (table_size == 0) {
            self.allocator.free(self.table);
            self.table = &.{};
            return false;
        }
        self.table = self.allocator.realloc(self.table, table_size) catch self.table;
        return true;
    }
};

fn readHuffmanCodeLengths(
    code_length_code_lengths: *const [code_length_codes]u8,
    num_symbols: i32,
    code_lengths: []u8,
    br: *BitReader,
) bool {
    var symbol: i32 = 0;
    var prev_code_len: u8 = default_code_length;
    var repeat: i32 = 0;
    var repeat_code_len: u8 = 0;
    var space: i32 = 32768;
    var table: [32]HuffmanCode = undefined;

    var counts: [16]u16 = .{0} ** 16;
    for (0..code_length_codes) |ci| {
        counts[code_length_code_lengths[ci]] += 1;
    }
    if (buildHuffmanTable(&table, 5, code_length_code_lengths, &counts) == 0) {
        return false;
    }

    while (symbol < num_symbols and space > 0) {
        br.refill();
        const p = &table[br.peekFixedBits(5)];
        br.consume(p.bits);
        const code_len: u8 = @intCast(p.value);
        if (code_len < code_length_repeat_code) {
            repeat = 0;
            code_lengths[@intCast(symbol)] = code_len;
            symbol += 1;
            if (code_len != 0) {
                prev_code_len = code_len;
                space -= @intCast(@as(u32, 32768) >> @intCast(code_len));
            }
        } else {
            const extra_bits: u5 = @intCast(code_len - 14);
            var new_len: u8 = 0;
            if (code_len == code_length_repeat_code) {
                new_len = prev_code_len;
            }
            if (repeat_code_len != new_len) {
                repeat = 0;
                repeat_code_len = new_len;
            }
            const old_repeat = repeat;
            if (repeat > 0) {
                repeat -= 2;
                repeat = repeat << extra_bits;
            }
            repeat += @as(i32, @intCast(br.readBits(extra_bits))) + 3;
            const repeat_delta = repeat - old_repeat;
            if (symbol + repeat_delta > num_symbols) {
                return false;
            }
            const start: usize = @intCast(symbol);
            const end: usize = @intCast(symbol + repeat_delta);
            @memset(code_lengths[start..end], repeat_code_len);
            symbol += repeat_delta;
            if (repeat_code_len != 0) {
                space -= repeat_delta * @as(i32, @intCast(@as(u32, 1) << @intCast(@as(u5, 15) - @as(u5, @intCast(repeat_code_len)))));
            }
        }
    }
    if (space != 0) {
        return false;
    }
    const sym_usize: usize = @intCast(symbol);
    const num_sym_usize: usize = @intCast(num_symbols);
    @memset(code_lengths[sym_usize..num_sym_usize], 0);
    return true;
}

fn readSimpleCode(alphabet_size: usize, br: *BitReader, table: [*]HuffmanCode) bool {
    const max_bits: u5 = if (alphabet_size > 1)
        @intCast(bits_mod.floorLog2Nonzero(@as(u32, @intCast(alphabet_size - 1))) + 1)
    else
        0;

    var num_symbols: usize = br.readBits(2) + 1;

    var symbols: [4]u16 = .{ 0, 0, 0, 0 };
    for (0..num_symbols) |i| {
        symbols[i] = @intCast(br.readBits(max_bits));
        if (symbols[i] >= alphabet_size) return false;
    }

    // Check for duplicates.
    for (0..num_symbols - 1) |i| {
        for (i + 1..num_symbols) |j| {
            if (symbols[i] == symbols[j]) return false;
        }
    }

    // 4 symbols have the option to encode as 5.
    if (num_symbols == 4) num_symbols += br.readBits(1);

    const goal_size: u32 = @as(u32, 1) << huffman_table_bits;

    var table_size: u32 = 1;
    switch (num_symbols) {
        1 => {
            table[0] = .{ .bits = 0, .value = symbols[0] };
        },
        2 => {
            if (symbols[0] > symbols[1]) std.mem.swap(u16, &symbols[0], &symbols[1]);
            table[0] = .{ .bits = 1, .value = symbols[0] };
            table[1] = .{ .bits = 1, .value = symbols[1] };
            table_size = 2;
        },
        3 => {
            if (symbols[1] > symbols[2]) std.mem.swap(u16, &symbols[1], &symbols[2]);
            table[0] = .{ .bits = 1, .value = symbols[0] };
            table[2] = .{ .bits = 1, .value = symbols[0] };
            table[1] = .{ .bits = 2, .value = symbols[1] };
            table[3] = .{ .bits = 2, .value = symbols[2] };
            table_size = 4;
        },
        4 => {
            // Sort 4 symbols.
            for (0..3) |i| {
                for (i + 1..4) |j| {
                    if (symbols[i] > symbols[j]) std.mem.swap(u16, &symbols[i], &symbols[j]);
                }
            }
            table[0] = .{ .bits = 2, .value = symbols[0] };
            table[2] = .{ .bits = 2, .value = symbols[1] };
            table[1] = .{ .bits = 2, .value = symbols[2] };
            table[3] = .{ .bits = 2, .value = symbols[3] };
            table_size = 4;
        },
        5 => {
            if (symbols[2] > symbols[3]) std.mem.swap(u16, &symbols[2], &symbols[3]);
            table[0] = .{ .bits = 1, .value = symbols[0] };
            table[1] = .{ .bits = 2, .value = symbols[1] };
            table[2] = .{ .bits = 1, .value = symbols[0] };
            table[3] = .{ .bits = 3, .value = symbols[2] };
            table[4] = .{ .bits = 1, .value = symbols[0] };
            table[5] = .{ .bits = 2, .value = symbols[1] };
            table[6] = .{ .bits = 1, .value = symbols[0] };
            table[7] = .{ .bits = 3, .value = symbols[3] };
            table_size = 8;
        },
        else => return false,
    }

    // Replicate to fill the table.
    while (table_size != goal_size) {
        const src = @as([*]const HuffmanCode, table)[0..table_size];
        const dst = @as([*]HuffmanCode, table + table_size)[0..table_size];
        @memcpy(dst, src);
        table_size <<= 1;
    }

    return true;
}

// ── Tests ──

const testing = std.testing;

test "HuffmanCode size" {
    // HuffmanCode should be 4 bytes (u8 + u16 with padding)
    try testing.expect(@sizeOf(HuffmanCode) <= 4);
}

test "buildHuffmanTable single symbol" {
    var table: [256]HuffmanCode = undefined;
    const code_lengths = [_]u8{ 0, 0, 1, 0 }; // Only symbol 2 has a code
    var counts = [_]u16{0} ** (params.prefix_max_bits + 1);
    for (code_lengths) |cl| counts[cl] += 1;

    const size = buildHuffmanTable(&table, huffman_table_bits, &code_lengths, &counts);
    try testing.expect(size > 0);
    // Single symbol: all entries should decode to symbol 2 with 0 bits
    try testing.expectEqual(@as(u16, 2), table[0].value);
    try testing.expectEqual(@as(u8, 0), table[0].bits);
}

test "buildHuffmanTable two symbols" {
    var table: [256]HuffmanCode = undefined;
    // Two symbols with 1-bit codes
    const code_lengths = [_]u8{ 1, 1 };
    var counts = [_]u16{0} ** (params.prefix_max_bits + 1);
    for (code_lengths) |cl| counts[cl] += 1;

    const size = buildHuffmanTable(&table, huffman_table_bits, &code_lengths, &counts);
    try testing.expect(size > 0);

    // Even indices should be symbol 0, odd should be symbol 1 (or vice versa)
    const v0 = table[0].value;
    const v1 = table[1].value;
    try testing.expect(v0 != v1);
    try testing.expect(v0 == 0 or v0 == 1);
    try testing.expect(v1 == 0 or v1 == 1);
}

test "readSimpleCode single symbol via BitReader" {
    // Construct a bitstream for simple code with 1 symbol
    // num_symbols - 1 = 0 (2 bits: 00)
    // symbol[0] = 0 (0 bits since alphabet_size = 1 => max_bits = 0)
    var data = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    var table: [256]HuffmanCode = undefined;

    const result = readSimpleCode(1, &br, &table);
    try testing.expect(result);
    try testing.expectEqual(@as(u16, 0), table[0].value);
    try testing.expectEqual(@as(u8, 0), table[0].bits);
}

test "getNextKey" {
    // Basic reversal increment
    try testing.expectEqual(@as(u32, 2), getNextKey(0, 2));
    try testing.expectEqual(@as(u32, 1), getNextKey(2, 2));
    try testing.expectEqual(@as(u32, 3), getNextKey(1, 2));
}
