const std = @import("std");
const jxl = @import("../root.zig");
fn check(allocator: std.mem.Allocator) !void {
	var writer = jxl.base.bit_writer.BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(1, 1); // Local tree, default predictor.
	try writer.write(2, 2);
	try writer.write(4, 8); // Ten transforms.
	for (0..10) |_| {
		try writer.write(2, 2);
		try writer.write(2, 1);
		try writer.write(4, 0);
		try writer.write(1, 1);
		try writer.write(1, 1);
		try writer.write(2, 0);
		try writer.write(3, 0);
		try writer.write(2, 0);
	}
	try writer.zeroPadToByte();
	var image = try jxl.modular.modular_image.Image.create(allocator, 1, 1, 8, 3);
	defer image.deinit();
	var br = jxl.base.bit_reader.BitReader.init(writer.bytes());
	const options = jxl.modular.options.ModularOptions{ .max_chan_size = 0 };
	try jxl.modular.encoding.modularGenericDecompress(&br, &image, 0, &options, false, null, null, null, allocator);
	try std.testing.expectEqual(@as(usize, 10), image.transforms.items.len);
}
test "modular transform ownership transfers atomically on allocation failure" {
	try check(std.testing.allocator);
	try std.testing.checkAllAllocationFailures(std.testing.allocator, check, .{});
}
