const std = @import("std");
const old = @import("soft_float_reference.zig");
const new = @import("soft_float.zig");
fn check(a: old.Fixed, b: old.Fixed) !void {
	const expected = old.div(a, b);
	const actual = new.div(.{ .m = a.m, .e = a.e }, .{ .m = b.m, .e = b.e });
	try std.testing.expectEqual(expected.m, actual.m);
	try std.testing.expectEqual(expected.e, actual.e);
}
test "wide division matches retained bit serial division across signs and boundaries" {
	const edges = [_]u64{ old.TWO62, old.TWO62 + 1, old.TWO62 + 2, old.TWO62 + old.TWO61, 0x7ffffffffffffffe, 0x7fffffffffffffff };
	for (edges) |a| for (edges) |b| for (0..4) |sign| {
		try check(.{ .m = @as(i64, @intCast(a)) * (if (sign & 1 == 0) @as(i64, 1) else -1), .e = -127 }, .{ .m = @as(i64, @intCast(b)) * (if (sign & 2 == 0) @as(i64, 1) else -1), .e = 127 });
	};
	var random = std.Random.DefaultPrng.init(0x6469766d6167);
	for (0..100000) |_| {
		const a: i64 = @intCast(random.random().int(u62) | old.TWO62);
		const b: i64 = @intCast(random.random().int(u62) | old.TWO62);
		for (0..4) |sign| try check(.{ .m = a * (if (sign & 1 == 0) @as(i64, 1) else -1), .e = random.random().int(i8) }, .{ .m = b * (if (sign & 2 == 0) @as(i64, 1) else -1), .e = random.random().int(i8) });
	}
	try check(old.Fixed.zero, old.fromInt(3));
}

test "magnitude shifts match signed division in addition for every exponent gap" {
	var random = std.Random.DefaultPrng.init(0x616464);
	for (0..70) |gap| for (0..1024) |_| {
		const a: i64 = @intCast(random.random().int(u62) | old.TWO62);
		const b: i64 = @intCast(random.random().int(u62) | old.TWO62);
		for (0..4) |sign| {
			const x = old.Fixed{ .m = a * (if (sign & 1 == 0) @as(i64, 1) else -1), .e = 30 };
			const y = old.Fixed{ .m = b * (if (sign & 2 == 0) @as(i64, 1) else -1), .e = 30 - @as(i32, @intCast(gap)) };
			const actual = new.add(.{ .m = x.m, .e = x.e }, .{ .m = y.m, .e = y.e });
			const expected = old.add(x, y);
			try std.testing.expectEqual(expected.m, actual.m);
			try std.testing.expectEqual(expected.e, actual.e);
		}
	};
}
