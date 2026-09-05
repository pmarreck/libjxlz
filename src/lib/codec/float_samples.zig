const std = @import("std");
const Error = @import("../base/status.zig").JxlError;
pub fn toFixed(raw: i32, depth: @import("image_metadata.zig").BitDepth) Error!@import("../base/soft_float.zig").Fixed {
	if (depth.floating_point_sample) return @import("../base/float.zig").loadFloat32Fixed(@bitCast(try toBits(raw, depth.bits_per_sample, depth.exponent_bits_per_sample)));
	if (depth.bits_per_sample == 0 or depth.bits_per_sample > 31) return error.GenericError;
	const sf = @import("../base/soft_float.zig");
	return sf.div(sf.fromInt(raw), sf.fromInt((@as(i64, 1) << @as(u6, @intCast(depth.bits_per_sample))) - 1));
}
pub fn toBits(raw: i32, bits: u32, exponent_bits: u32) Error!u32 {
	if (exponent_bits < 2 or exponent_bits > 8 or bits < exponent_bits + 3 or bits > exponent_bits + 24 or bits > 32) return error.GenericError;
	const wire: u32 = @bitCast(raw);
	if (bits == 32) return wire;
	const sign_shift: u5 = @intCast(bits - 1);
	const mant_bits: u5 = @intCast(bits - exponent_bits - 1);
	const mant_shift: u5 = 23 - mant_bits;
	const sign: u32 = if (wire >> sign_shift != 0) 0x80000000 else 0;
	const magnitude = wire & ((@as(u32, 1) << sign_shift) - 1);
	if (magnitude == 0) return sign;
	var exponent: i32 = @intCast(magnitude >> mant_bits);
	var mantissa = (magnitude & ((@as(u32, 1) << mant_bits) - 1)) << mant_shift;
	if (exponent == (@as(u32, 1) << @as(u5, @intCast(exponent_bits))) - 1) return sign | 0x7f800000 | mantissa;
	if (exponent == 0 and exponent_bits < 8) {
		while (mantissa & 0x800000 == 0) {
			mantissa <<= 1;
			exponent -= 1;
		}
		exponent += 1;
		mantissa &= 0x7fffff;
	}
	exponent += 127 - ((@as(i32, 1) << @as(u5, @intCast(exponent_bits - 1))) - 1);
	if (exponent < 0 or exponent > 254) return error.GenericError;
	return sign | (@as(u32, @intCast(exponent)) << 23) | mantissa;
}
test "float samples match all 154 upstream wire layouts and special values" {
	const fixture = @import("float_sample_fixture.zig");
	for (fixture.cases) |case| try std.testing.expectEqual(case[3], try toBits(@bitCast(case[2]), case[0], case[1]));
}

test "float sample layouts reject invalid exponent and mantissa combinations" {
	const invalid = [_][2]u32{ .{ 0, 0 }, .{ 32, 0 }, .{ 16, 1 }, .{ 16, 9 }, .{ 32, 7 }, .{ 33, 8 }, .{ 4, 2 }, .{ 34, 8 }, .{ 31, 2 }, .{ 16, 0xffffffff }, .{ 0xffffffff, 8 } };
	for (invalid) |layout| try std.testing.expectError(error.GenericError, toBits(0, layout[0], layout[1]));
}
