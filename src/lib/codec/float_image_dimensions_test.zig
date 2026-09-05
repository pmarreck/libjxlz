const std = @import("std");
const FloatImage = @import("render.zig").FloatImage;
test "float image rejects overflowing planar dimensions before allocation" {
	const max = std.math.maxInt(usize);
	for ([_][3]usize{ .{max,2,3}, .{1,max,3}, .{max/3+1,1,3} }) |size| {
		try std.testing.expectError(error.GenericError, FloatImage.init(std.testing.allocator,size[0],size[1],size[2]));
	}
}
