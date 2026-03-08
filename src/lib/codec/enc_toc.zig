// Encoder-side TOC helpers.
// Starts with the simplest form: no permutation, raw section sizes.

const std = @import("std");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const toc = @import("toc.zig");

fn writeTocSize(size: u32, writer: *BitWriter) !void {
	if (size < 1024) {
		try writer.write(2, 0);
		try writer.write(10, size);
		return;
	}
	if (size < 17408) {
		try writer.write(2, 1);
		try writer.write(14, size - 1024);
		return;
	}
	if (size < 4211712) {
		try writer.write(2, 2);
		try writer.write(22, size - 17408);
		return;
	}
	try writer.write(2, 3);
	try writer.write(30, size - 4211712);
}

/// Emits a TOC in the decoder's simplest accepted form: no permutation, byte
/// aligned before and after the section-size array.
pub fn writeSimpleToc(section_sizes: []const u32, writer: *BitWriter) !void {
	std.debug.assert(section_sizes.len > 0);
	try writer.write(1, 0); // no permutation
	try writer.zeroPadToByte();
	for (section_sizes) |size| {
		try writeTocSize(size, writer);
	}
	try writer.zeroPadToByte();
}

const testing = std.testing;

test "writeSimpleToc round-trips a single section through readToc" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleToc(&[_]u32{13}, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	const entries = try toc.readToc(allocator, 1, &br);
	defer allocator.free(entries);
	try testing.expectEqual(@as(u32, 13), entries[0].size);
	try testing.expectEqual(@as(usize, 0), entries[0].id);
	try br.close();
}

test "writeSimpleToc round-trips multiple section sizes through readToc" {
	const allocator = testing.allocator;
	const sizes = [_]u32{ 0, 17, 1024, 17408, 4211712 };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleToc(&sizes, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	const entries = try toc.readToc(allocator, sizes.len, &br);
	defer allocator.free(entries);

	for (sizes, entries, 0..) |want_size, entry, i| {
		try testing.expectEqual(want_size, entry.size);
		try testing.expectEqual(i, entry.id);
	}
	try br.close();
}
