const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const fixture = @import("raw_quant_fixture.zig");
test "all raw dequant matrices parse upstream AC global payload" {
	var matrices = jxl.codec.dec_frame.DequantMatrices{};
	defer matrices.deinit(std.testing.allocator);
	var br = jxl.base.bit_reader.BitReader.init(&fixture.bytes_all);
	try matrices.decode(std.testing.allocator, &br, .{});
	try std.testing.expectEqual(fixture.bits_all, br.totalBitsConsumed());
	try matrices.ensureComputed(std.testing.allocator, (@as(u32, 1) << 27) - 1);
	for (0..27) |raw| for (0..3) |c| {
		const extent = try jxl.codec.ac_strategy.strategyExtent(@intCast(raw));
		const width = @min(extent.x, extent.y) * 8;
		const matrix = matrices.matrix(@enumFromInt(raw), c);
		for (matrix, 0..) |value, i| {
			const index = c * matrix.len + i;
			const expected = sf.div(sf.fromInt(@intCast(1 + (index * 13 + index / width * 7) % 251)), sf.fromInt(8));
			const delta = sf.sub(value, expected);
			try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.parse("0.000000000001").?) <= 0);
		}
	};
}
fn oneRaw(allocator: std.mem.Allocator) !void {
	var writer = jxl.base.bit_writer.BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, 7);
	var payload = jxl.base.bit_reader.BitReader.init(&fixture.bytes_0);
	for (0..fixture.bits_0) |_| try writer.write(1, payload.readBits(1));
	for (1..17) |_| try writer.write(3, 0);
	const bits = writer.bitsWritten();
	try writer.write(8, 0xa5);
	try writer.zeroPadToByte();
	var br = jxl.base.bit_reader.BitReader.init(writer.bytes());
	var matrices = jxl.codec.dec_frame.DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(allocator, &br, .{});
	try std.testing.expectEqual(bits, br.totalBitsConsumed());
	try std.testing.expectEqual(@as(u64, 0xa5), br.readBits(8));
	try matrices.ensureComputed(allocator, 1);
	try std.testing.expectEqual(sf.div(sf.fromInt(1), sf.fromInt(8)), matrices.matrix(.dct, 0)[0]);
	var defaults = jxl.base.bit_reader.BitReader.init(&.{1});
	try matrices.decode(allocator, &defaults, .{});
	try std.testing.expectEqual(@as(u32, 0), matrices.computed_mask);
	for (matrices.encodings) |entry| try std.testing.expectEqual(@as(usize, 0), entry.raw_weights.len);
	try matrices.ensureComputed(allocator, 1);
	try std.testing.expect(sf.cmp(matrices.matrix(.dct, 0)[0], sf.div(sf.fromInt(1), sf.fromInt(8))) != 0);
}
test "raw dequant matrix ownership survives failures and replacement" {
	try oneRaw(std.testing.allocator);
	try std.testing.checkAllAllocationFailures(std.testing.allocator, oneRaw, .{});
}
