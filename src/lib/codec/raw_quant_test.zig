const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const raw = @import("raw_quant.zig");
const fixture = @import("raw_quant_fixture.zig");
fn check(allocator: std.mem.Allocator, comptime first: usize, comptime end: usize) !void {
	inline for (first..end) |id| {
		const suffix = std.fmt.comptimePrint("{d}", .{id});
		const bytes = @field(fixture, "bytes_" ++ suffix);
		const width = @field(fixture, "width_" ++ suffix);
		const height = @field(fixture, "height_" ++ suffix);
		var br = jxl.base.bit_reader.BitReader.init(&bytes);
		const weights = try raw.decode(allocator, &br, .{ .width = width, .height = height });
		defer allocator.free(weights);
		try std.testing.expectEqual(@field(fixture, "bits_" ++ suffix), br.totalBitsConsumed());
		try std.testing.expectEqual(3 * width * height, weights.len);
		for (weights, 0..) |value, i| try std.testing.expectEqual(sf.div(sf.fromInt(8), sf.fromInt(@intCast(1 + (i * 13 + i / width * 7) % 251))), value);
	}
}
test "raw quant tables decode upstream modular streams at all 17 sizes" {
	try check(std.testing.allocator, 0, 17);
}
fn checkOne(allocator: std.mem.Allocator) !void {
	try check(allocator, 0, 1);
}
test "raw quant table allocation failures release partial state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkOne, .{});
}
test "raw quant tables reject zero negative entries and invalid denominators" {
	inline for (17..21) |id| {
		const bytes = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		var br = jxl.base.bit_reader.BitReader.init(&bytes);
		try std.testing.expectError(error.GenericError, raw.decode(std.testing.allocator, &br, .{ .width = 8, .height = 8 }));
	}
}
test "raw quant tables reject every truncated prefix" {
	const bytes = fixture.bytes_0;
	for (0..bytes.len) |len| {
		var br = jxl.base.bit_reader.BitReader.init(bytes[0..len]);
		if (raw.decode(std.testing.allocator, &br, .{ .width = 8, .height = 8 })) |result| {
			std.testing.allocator.free(result);
			return error.TestUnexpectedResult;
		} else |_| {}
	}
}
fn checkBorrowed(allocator: std.mem.Allocator) !void {
	const BitReader = jxl.base.bit_reader.BitReader;
	const BitWriter = jxl.base.bit_writer.BitWriter;
	var original = BitReader.init(&fixture.bytes_0);
	const denominator = original.readBits(16);
	var header = try jxl.modular.encoding.GroupHeader.readFromBitStream(&original, allocator);
	defer header.deinit();
	try std.testing.expect(!header.use_global_tree);
	const header_end = original.totalBitsConsumed();
	var tree: jxl.modular.dec_ma.Tree = .empty;
	defer tree.deinit(allocator);
	try jxl.modular.dec_ma.decodeTree(allocator, &original, &tree, 1 << 20);
	var code = jxl.entropy.dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const contexts = try jxl.entropy.dec_ans.decodeHistograms(allocator, &original, (tree.items.len + 1) / 2, &code);
	defer allocator.free(contexts);
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(16, denominator);
	try writer.write(1, 1);
	var header_bits = BitReader.init(&fixture.bytes_0);
	header_bits.skipBits(17);
	while (header_bits.totalBitsConsumed() < header_end) try writer.write(1, header_bits.readBits(1));
	while (original.totalBitsConsumed() < fixture.bits_0) try writer.write(1, original.readBits(1));
	const bits = writer.bitsWritten();
	try writer.write(8, 0xa5);
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	const values = try raw.decode(allocator, &br, .{ .width = 8, .height = 8, .stream_id = 23, .global = .{ .tree = tree.items, .code = &code, .context_map = contexts } });
	defer allocator.free(values);
	for (values, 0..) |value, i| try std.testing.expectEqual(sf.div(sf.fromInt(8), sf.fromInt(@intCast(1 + (i * 13 + i / 8 * 7) % 251))), value);
	try std.testing.expectEqual(bits, br.totalBitsConsumed());
	try std.testing.expectEqual(@as(u64, 0xa5), br.readBits(8));
}
test "raw quant tables borrow upstream entropy and preserve following fields" {
	try checkBorrowed(std.testing.allocator);
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkBorrowed, .{});
}
