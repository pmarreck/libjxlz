const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const display = @import("fixed_display.zig");
test "Fixed output conversion round-trips finite binary32 wire values" {
	const edges = [_]u32{ 0, 0x00000001, 0x007fffff, 0x00800000, 0x3f800000, 0x3f800001, 0x7f7fffff, 0x80000001, 0x807fffff, 0x80800000, 0xbf800000, 0xff7fffff };
	for (edges) |raw| try std.testing.expectEqual(raw, display.bits(try jxl.base.float16.loadFloat32Fixed(@bitCast(raw))));
	var random: u32 = 0x31415926;
	for (0..4096) |_| {
		random = random *% 1664525 +% 1013904223;
		if ((random >> 23) & 255 == 255) continue;
		try std.testing.expectEqual(random, display.bits(try jxl.base.float16.loadFloat32Fixed(@bitCast(random))));
	}
}
test "Fixed output conversion rounds ties to even and handles exponent limits" {
	try std.testing.expectEqual(@as(u32, 0x3f800000), display.bits(sf.div(sf.fromInt(16777217), sf.fromInt(16777216))));
	try std.testing.expectEqual(@as(u32, 0x3f800002), display.bits(sf.div(sf.fromInt(16777219), sf.fromInt(16777216))));
	try std.testing.expectEqual(@as(u32, 0), display.bits(.{ .m = 1 << 62, .e = -150 }));
	try std.testing.expectEqual(@as(u32, 2), display.bits(.{ .m = 3 << 61, .e = -149 }));
	try std.testing.expectEqual(@as(u32, 0x80000000), display.bits(.{ .m = -(1 << 62), .e = -151 }));
	try std.testing.expectEqual(@as(u32, 0x7f800000), display.bits(.{ .m = 1 << 62, .e = 128 }));
	try std.testing.expectEqual(@as(u32, 0xff800000), display.bits(.{ .m = -(1 << 62), .e = std.math.maxInt(i32) }));
	try std.testing.expectEqual(@as(u32, 0), display.bits(.{ .m = 1 << 62, .e = std.math.minInt(i32) }));
}
