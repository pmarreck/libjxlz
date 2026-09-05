//! Chroma sampling and full-range JFIF YCbCr conversion in Fixed.
const sf = @import("../base/soft_float.zig");
pub fn toRgb(cb: sf.Fixed, y: sf.Fixed, cr: sf.Fixed) [3]sf.Fixed {
	const center = sf.add(y, sf.div(sf.fromInt(128), sf.fromInt(255)));
	return .{ sf.add(center, sf.mul(sf.parse("1.402").?, cr)), sf.sub(sf.sub(center, sf.mul(sf.div(sf.fromInt(114 * 1772), sf.fromInt(587 * 1000)), cb)), sf.mul(sf.div(sf.fromInt(299 * 1402), sf.fromInt(587 * 1000)), cr)), sf.add(center, sf.mul(sf.parse("1.772").?, cb)) };
}
const std = @import("std");
const Error = @import("../base/status.zig").JxlError;
pub const Plane = struct { width: usize, height: usize, data: []const sf.Fixed };
pub fn upsample(allocator: std.mem.Allocator, input: Plane, hs: u8, vs: u8, width: usize, height: usize) Error![]sf.Fixed {
	if (hs > 1 or vs > 1 or width == 0 or height == 0 or width == std.math.maxInt(usize) or height == std.math.maxInt(usize)) return error.GenericError;
	if (input.width != (width + hs) >> @intCast(hs) or input.height != (height + vs) >> @intCast(vs)) return error.GenericError;
	const area = std.math.mul(usize, input.width, input.height) catch return error.GenericError;
	if (input.data.len != area) return error.GenericError;
	const horizontal_size = std.math.mul(usize, width, input.height) catch return error.GenericError;
	const horizontal = try allocator.alloc(sf.Fixed, horizontal_size);
	errdefer allocator.free(horizontal);
	for (0..input.height) |y| for (0..width) |x| {
		if (hs == 0) {
			horizontal[y * width + x] = input.data[y * input.width + x];
			continue;
		}
		const cx = x / 2;
		const neighbor = if (x % 2 == 0) cx - @intFromBool(cx != 0) else @min(cx + 1, input.width - 1);
		horizontal[y * width + x] = sf.div(sf.add(sf.mul(sf.fromInt(3), input.data[y * input.width + cx]), input.data[y * input.width + neighbor]), sf.fromInt(4));
	};
	if (vs == 0) return horizontal;
	const size = std.math.mul(usize, width, height) catch return error.GenericError;
	const output = try allocator.alloc(sf.Fixed, size);
	for (0..height) |y| for (0..width) |x| {
		const cy = y / 2;
		const neighbor = if (y % 2 == 0) cy - @intFromBool(cy != 0) else @min(cy + 1, input.height - 1);
		output[y * width + x] = sf.div(sf.add(sf.mul(sf.fromInt(3), horizontal[cy * width + x]), horizontal[neighbor * width + x]), sf.fromInt(4));
	};
	allocator.free(horizontal);
	return output;
}

test "chroma shape validation rejects impossible planes before allocation" {
	const t = std.testing;
	const one = [_]sf.Fixed{sf.fromInt(1)};
	const shapes = [_][6]usize{
		.{ 0, 1, 0, 0, 1, 1 },                      .{ 1, 0, 0, 0, 1, 1 }, .{ 1, 1, 2, 0, 1, 1 }, .{ 1, 1, 0, 2, 1, 1 },
		.{ 1, 1, 0, 0, 0, 1 },                      .{ 1, 1, 0, 0, 1, 0 }, .{ 1, 1, 1, 1, 3, 3 }, .{ 1, 1, 0, 0, std.math.maxInt(usize), 1 },
		.{ 1, 1, 0, 0, 1, std.math.maxInt(usize) },
	};
	for (shapes) |s| try t.expectError(error.GenericError, upsample(t.allocator, .{ .width = s[0], .height = s[1], .data = &one }, @intCast(s[2]), @intCast(s[3]), s[4], s[5]));
	try t.expectError(error.GenericError, upsample(t.allocator, .{ .width = 1, .height = 1, .data = &.{} }, 0, 0, 1, 1));
}
fn allocationCase(allocator: std.mem.Allocator) !void {
	const one = [_]sf.Fixed{sf.fromInt(1)};
	const result = try upsample(allocator, .{ .width = 1, .height = 1, .data = &one }, 1, 1, 2, 2);
	defer allocator.free(result);
	try std.testing.expectEqual(4, result.len);
	for (result) |value| try std.testing.expectEqual(one[0], value);
}
test "chroma allocation failures release horizontal temporary" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
