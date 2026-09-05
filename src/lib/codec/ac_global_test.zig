const std = @import("std");
const jxl = @import("../root.zig");
const BitReader = jxl.base.bit_reader.BitReader;
const fixture = @import("ac_global_fixture.zig");
const ac = @import("ac_global.zig");
fn check(allocator: std.mem.Allocator, bytes: []const u8) !void {
	var matrices = jxl.codec.dec_frame.DequantMatrices{};
	defer matrices.deinit(allocator);
	var br = BitReader.init(bytes);
	const model = jxl.codec.vardct_global.BlockContextMap{ .allocator = allocator };
	var global = try ac.Global.decode(allocator, &br, &matrices, 1, 5, 2, &model);
	defer global.deinit();
	try std.testing.expectEqual(fixture.bits, br.totalBitsConsumed());
	try std.testing.expectEqual(@as(usize, 3), global.num_histograms);
	inline for (0..2) |i| {
		const pass = &global.passes[i];
		var payload = BitReader.init(if (i == 0) &fixture.payload_0 else &fixture.payload_1);
		var symbols = try jxl.entropy.dec_ans.ANSSymbolReader.create(&pass.code, &payload, 0, allocator);
		defer symbols.deinit();
		for (0..128) |k| try std.testing.expectEqual((k * 19 + i) % 61, symbols.readHybridUint((k * 97) % (3 * 7425), &payload, pass.contexts));
		try std.testing.expect(symbols.checkANSFinalState());
		try std.testing.expectEqual(if (i == 0) fixture.payload_bits_0 else fixture.payload_bits_1, payload.totalBitsConsumed());
		const scan = try pass.orders.get(0, 0);
		try std.testing.expectEqual(@as(u32, if (i == 0) 1 else 8), scan[1]);
	}
}
fn checkGood(allocator: std.mem.Allocator) !void {
	try check(allocator, &fixture.bytes);
}
test "AC global matches upstream multi-pass orders and histogram payloads" {
	try checkGood(std.testing.allocator);
}
test "AC global releases partial state on allocation failures" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkGood, .{});
}
test "AC global rejects all truncated metadata prefixes" {
	for (0..fixture.bytes.len) |len| {
		if (check(std.testing.allocator, fixture.bytes[0..len])) return error.TestUnexpectedResult else |_| {}
	}
}
