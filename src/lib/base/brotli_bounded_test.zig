const std = @import("std");
const brotli = @import("brotli.zig");
test "bounded Brotli rejects output beyond its declared budget" {
	const allocator = std.testing.allocator;
	const encoded = try brotli.compress(allocator, "123456789");
	defer allocator.free(encoded);
	if (brotli.decompressBounded(allocator, encoded, 8)) |output| {
		allocator.free(output);
		return error.AcceptedExcessOutput;
	} else |err| try std.testing.expectEqual(error.GenericError, err);
}
test "bounded Brotli accepts exact, spare, and empty budgets" {
	const allocator = std.testing.allocator;
	for ([_][]const u8{ "", "123456789" }) |input| {
		const encoded = try brotli.compress(allocator, input);
		defer allocator.free(encoded);
		for ([_]usize{ input.len, input.len + 1 }) |limit| {
			const output = try brotli.decompressBounded(allocator, encoded, limit);
			defer allocator.free(output);
			try std.testing.expectEqualSlices(u8, input, output);
		}
	}
}
test "bounded Brotli enforces the cumulative limit across output chunks" {
	const allocator = std.testing.allocator;
	const input = try allocator.alloc(u8, 8193);
	defer allocator.free(input);
	@memset(input, 37);
	const encoded = try brotli.compress(allocator, input);
	defer allocator.free(encoded);
	for ([_]usize{ 0, 4095, 4096, 8192 }) |limit| {
		if (brotli.decompressBounded(allocator, encoded, limit)) |output| {
			allocator.free(output);
			return error.AcceptedExcessOutput;
		} else |err| try std.testing.expectEqual(error.GenericError, err);
	}
	const output = try brotli.decompressBounded(allocator, encoded, input.len);
	defer allocator.free(output);
	try std.testing.expectEqualSlices(u8, input, output);
}
