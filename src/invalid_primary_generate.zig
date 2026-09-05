const std = @import("std");
const jxl = @import("lib/root.zig");
extern "c" fn printf([*:0]const u8, ...) c_int;
pub fn main() !void {
	const data = &@import("lib/codec/primary_frame_fixture.zig").bytes_0;
	const metadata = try std.heap.page_allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer std.heap.page_allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_start = 16 + br.totalBitsConsumed();
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	const transform_end = 16 + br.totalBitsConsumed();
	try br.jumpToByteBoundary();
	try br.close();
	const start = 2 + br.totalBitsConsumed() / 8;
	const original = metadata.m.color_encoding;
	_ = printf("// Generated mutations; upstream public decoder verifies every rejection.\n");
	for (0..5) |id| {
		metadata.m.color_encoding = original;
		const color = &metadata.m.color_encoding;
		if (id < 3) {
			color.white_point = .custom;
			color.white = .{ .x = if (id == 1) -1 else if (id == 2) 1000001 else 321000, .y = if (id == 0) 0 else 345000 };
		} else {
			color.primaries = .custom;
			color.red = .{ .x = 100000, .y = 200000 };
			color.green = .{ .x = if (id == 3) 100000 else 200000, .y = if (id == 3) 200000 else 300000 };
			color.blue = .{ .x = if (id == 3) 100000 else 300000, .y = if (id == 3) 200000 else 400000 };
		}
		var writer = jxl.base.bit_writer.BitWriter.init(std.heap.page_allocator);
		defer writer.deinit();
		try writer.write(16, 0x0aff);
		try jxl.codec.headers.writeSizeHeader(&metadata.size, &writer);
		try jxl.codec.image_metadata.writeImageMetadata(&metadata.m, &writer);
		for (transform_start..transform_end) |bit| try writer.write(1, (data[bit / 8] >> @as(u3, @intCast(bit % 8))) & 1);
		try writer.zeroPadToByte();
		_ = printf("pub const invalid_%u=[_]u8{", @as(c_uint, @intCast(id)));
		for (writer.bytes()) |b| {
			_ = printf("%u,", @as(c_uint, b));
		}
		for (data[start..]) |b| {
			_ = printf("%u,", @as(c_uint, b));
		}
		_ = printf("};\n");
	}
}
