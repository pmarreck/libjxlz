const std = @import("std");
const sf = @import("binary32.zig");
fn check(a: u32, b: u32, c: u32) !void {
	@setFloatMode(.strict);
	const expected: u32 = @bitCast(@mulAdd(f32, @bitCast(a), @bitCast(b), @bitCast(c)));
	const actual = sf.fma(a, b, c);
	if (expected & 0x7fffffff > 0x7f800000) {
		try std.testing.expect(actual & 0x7fffffff > 0x7f800000);
		try std.testing.expect(actual & 0x400000 != 0);
	} else if (expected != actual) {
		std.debug.print("fma a={x} b={x} c={x} expected={x} actual={x}\n", .{ a, b, c, expected, actual });
		return error.TestUnexpectedResult;
	}
}
test "integer binary32 fused arithmetic matches native IEEE operation" {
	const edges = [_]u32{ 0, 0x80000000, 1, 0x80000001, 0x7fffff, 0x807fffff, 0x800000, 0x80800000, 0x3f800000, 0xbf800000, 0x3f7fffff, 0x3f800001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc12345, 0xffc12345, 0x7f800001, 0xff800001 };
	for (edges) |a| for (edges) |b| for (edges) |c| try check(a, b, c);
	var seed: u64 = 0x163942873acbfd58;
	for (0..200000) |_| {
		var words: [3]u32 = undefined;
		for (&words) |*word| {
			seed = seed *% 6364136223846793005 +% 1442695040888963407;
			word.* = @truncate(seed >> 16);
		}
		try check(words[0], words[1], words[2]);
	}
}
test "integer fused alignment matches exact wide sum through correlated cancellation" {
	const exact = @import("binary32_wide_control.zig");
	var seed: u64 = 0x962adc785bed9831;
	for (0..200000) |_| {
		var words: [3]u32 = undefined;
		for (&words) |*word| {
			seed = seed *% 6364136223846793005 +% 1442695040888963407;
			word.* = @truncate(seed >> 16);
		}
		words[2] = sf.neg(sf.mul(words[0], words[1])) +% (words[2] % 5) -% 2;
		const want = exact.fma(words[0], words[1], words[2]);
		const actual = sf.fma(words[0], words[1], words[2]);
		if (want & 0x7fffffff > 0x7f800000) try std.testing.expect(actual & 0x7fffffff > 0x7f800000) else try std.testing.expectEqual(want, actual);
	}
}
