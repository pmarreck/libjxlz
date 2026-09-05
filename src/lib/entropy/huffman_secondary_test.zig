const std = @import("std");
const h = @import("huffman.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const fixture = @import("huffman_secondary_fixture.zig");
fn mix(hash: *u64, value: u32) void {
	hash.* ^= value;
	hash.* *%= 1099511628211;
}
test "long Huffman tables match upstream sizes and every entry" {
	inline for (0..9) |id| {
		const suffix = std.fmt.comptimePrint("{d}", .{id});
		const lengths = @field(fixture, "lengths_" ++ suffix);
		const table = try std.testing.allocator.alloc(h.HuffmanCode, 65536);
		defer std.testing.allocator.free(table);
		@memset(table, .{ .bits = 0, .value = 0 });
		var counts = [_]u16{0} ** 16;
		for (lengths) |length| counts[length] += 1;
		const size = h.buildHuffmanTable(table.ptr, 8, &lengths, &counts);
		try std.testing.expectEqual(@field(fixture, "size_" ++ suffix), size);
		var hash: u64 = 14695981039346656037;
		for (table[0..size]) |entry| {
			mix(&hash, entry.bits);
			mix(&hash, entry.value);
		}
		try std.testing.expectEqual(@field(fixture, "table_hash_" ++ suffix), hash);
	}
}
test "long Huffman symbols match upstream over all 15-bit lookaheads" {
	inline for (0..9) |id| {
		const suffix = std.fmt.comptimePrint("{d}", .{id});
		const lengths = @field(fixture, "lengths_" ++ suffix);
		const table = try std.testing.allocator.alloc(h.HuffmanCode, 65536);
		defer std.testing.allocator.free(table);
		@memset(table, .{ .bits = 0, .value = 0 });
		var counts = [_]u16{0} ** 16;
		for (lengths) |length| counts[length] += 1;
		const size = h.buildHuffmanTable(table.ptr, 8, &lengths, &counts);
		var code = h.HuffmanDecodingData{ .allocator = std.testing.allocator, .table = table[0..size] };
		var hash: u64 = 14695981039346656037;
		for (0..32768) |lookahead| {
			var data = [_]u8{0} ** 8;
			std.mem.writeInt(u16, data[0..2], @intCast(lookahead), .little);
			var br = BitReader.init(&data);
			mix(&hash, code.readSymbol(&br));
			mix(&hash, @intCast(br.totalBitsConsumed()));
		}
		try std.testing.expectEqual(@field(fixture, "decode_hash_" ++ suffix), hash);
	}
}
