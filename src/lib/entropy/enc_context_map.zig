// Encoder-side context-map helpers.
// Starts with the smallest multi-context slice: simple all-zero maps.

const std = @import("std");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const dec_context_map = @import("dec_context_map.zig");

/// Emits the simple all-zero context-map form, which assigns every context to
/// histogram 0 without invoking the recursive histogram-coded path.
pub fn writeSimpleAllZeroContextMap(num_contexts: usize, writer: *BitWriter) !void {
	std.debug.assert(num_contexts > 0);
	try writer.write(1, 1); // is_simple = true
	try writer.write(2, 0); // bits_per_entry = 0 => all histogram ids are zero
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
