// Encoder-side context-map helpers.
// Starts with the smallest multi-context slice: simple all-zero maps.

const std = @import("std");
const bits = @import("../base/bits.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const dec_context_map = @import("dec_context_map.zig");

/// Emits the simple all-zero context-map form, which assigns every context to
/// histogram 0 without invoking the recursive histogram-coded path.
pub fn writeSimpleAllZeroContextMap(num_contexts: usize, writer: *BitWriter) !void {
	std.debug.assert(num_contexts > 0);
	try writer.write(1, 1); // is_simple = true
	try writer.write(2, 0); // bits_per_entry = 0 => all histogram ids are zero
}

/// Emits the direct-entry simple context-map form for small histogram counts,
/// avoiding the heavier ANS/MTF path while still allowing multiple histograms.
pub fn writeSimpleContextMap(context_map: []const u8, num_histograms: usize, writer: *BitWriter) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	if (num_histograms == 1) return writeSimpleAllZeroContextMap(context_map.len, writer);

	const bits_per_entry = bits.ceilLog2Nonzero(num_histograms);
	std.debug.assert(bits_per_entry > 0 and bits_per_entry < 4);

	try writer.write(1, 1); // is_simple = true
	try writer.write(2, bits_per_entry);
	for (context_map) |entry| {
		std.debug.assert(entry < num_histograms);
		try writer.write(bits_per_entry, entry);
	}
}

const testing = std.testing;

test "writeSimpleAllZeroContextMap round-trips through decodeContextMap" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleAllZeroContextMap(6, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	var num_htrees: usize = 0;
	try dec_context_map.decodeContextMap(&map, &num_htrees, &br);
	try testing.expectEqual(@as(usize, 1), num_htrees);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, &map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSimpleContextMap round-trips explicit histogram ids" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMap(&[_]u8{ 0, 1, 0, 1, 1, 0 }, 2, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	var num_htrees: usize = 0;
	try dec_context_map.decodeContextMap(&map, &num_htrees, &br);
	try testing.expectEqual(@as(usize, 2), num_htrees);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1, 1, 0 }, &map);
	try br.jumpToByteBoundary();
	try br.close();
}
