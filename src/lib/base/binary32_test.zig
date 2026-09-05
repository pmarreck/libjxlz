const std = @import("std");
const sf = @import("binary32.zig");
fn check(a: u32, b: u32) !void {
	@setFloatMode(.strict);
	const x: f32 = @bitCast(a);
	const y: f32 = @bitCast(b);
	const actual = [_]u32{ sf.add(a, b), sf.sub(a, b), sf.mul(a, b), sf.div(a, b) };
	const expected = [_]f32{ x + y, x - y, x * y, x / y };
	for (actual, expected, 0..) |bits, wanted, op| {
		const word: u32 = @bitCast(wanted);
		if (word & 0x7fffffff > 0x7f800000) {
			try std.testing.expect(bits & 0x7fffffff > 0x7f800000);
			try std.testing.expect(bits & 0x400000 != 0);
		} else if (bits != word) {
			std.debug.print("binary32 op={d} a={x} b={x} actual={x} expected={x}\n", .{ op, a, b, bits, word });
			return error.TestUnexpectedResult;
		}
	}
}
test "integer binary32 arithmetic matches independent native IEEE operations" {
	const edges = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x7fffff, 0x807fffff, 0x800000, 0x80800000, 0x3f800000, 0xbf800000, 0x3f7fffff, 0x3f800001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f800001, 0xff800001 };
	for (edges) |a| for (edges) |b| try check(a, b);
	var seed: u64 = 0xfedcba9876543210;
	for (0..200000) |_| {
		seed = seed *% 6364136223846793005 +% 1442695040888963407;
		const a: u32 = @truncate(seed >> 16);
		seed = seed *% 6364136223846793005 +% 1442695040888963407;
		const b: u32 = @truncate(seed >> 16);
		try check(a, b);
	}
}
