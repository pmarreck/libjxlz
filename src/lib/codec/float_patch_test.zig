const std = @import("std");
const jxl = @import("../root.zig");
const patch = @import("patches.zig");
const fixture = @import("patches_fixture.zig");
test "patch dictionaries accept floating reference storage" {
	const allocator = std.testing.allocator;
	const storage = try allocator.alloc(f32, 4 * 8 * 6 * 3);
	defer allocator.free(storage);
	@memset(storage, 0);
	var refs: [4]patch.Reference = undefined;
	for (&refs, 0..) |*ref, r| ref.* = .{ .float_image = .{ .xsize = 8, .ysize = 6, .channels = 3, .data = storage[r * 8 * 6 * 3 ..][0 .. 8 * 6 * 3], .allocator = allocator }, .pre_color = true };
	var br = jxl.base.bit_reader.BitReader.init(&fixture.bytes_0);
	var dictionary = try patch.Dictionary.decode(allocator, &br, 16, 12, 0, &refs);
	defer dictionary.deinit();
	try std.testing.expectEqual(fixture.bits_0, br.totalBitsConsumed());
	try std.testing.expectEqual(fixture.refs_0, dictionary.refs);
	try std.testing.expectEqual(@as(usize, 5), dictionary.positions.items.len);
}
