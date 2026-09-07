const std = @import("std");
const encoder = @import("../lib/codec/enc_api.zig");
const metadata_mod = @import("../lib/codec/image_metadata.zig");
const FrameDecoder = @import("../lib/codec/dec_frame.zig").FrameDecoder;

test "encoded preview resamples sixteen bit color and alpha" {
	const samples = [_]u16{1000,1001,1002,2000,2001,2002,3000,3001,3002,4000,4001,4002,5000,5001,5002,6000,6001,6002};
	var pixels: [36]u8 = undefined;
	for (samples, 0..) |sample, i| std.mem.writeInt(u16, pixels[i * 2 ..][0..2], sample, .big);
	const bytes = try encoder.encodeSimplePackedU8(std.testing.allocator, .{
		.width = 3, .height = 2, .num_color_channels = 3, .bits_per_sample = 16,
		.color_row_stride = 18, .color_pixels = &pixels,
		.alpha_row_stride = 6, .alpha_pixels = &.{1,0,2,0,3,0,4,0,5,0,6,0},
		.preview_width = 2, .preview_height = 1,
	}, null);
	defer std.testing.allocator.free(bytes);
	try checkPlanes(bytes, &.{ &.{1000,2000}, &.{1001,2001}, &.{1002,2002}, &.{256,512} });
}

test "encoded preview preserves subsampled extra planes" {
	const bytes = try encoder.encodeSimplePackedU8(std.testing.allocator, .{
		.width = 3, .height = 2, .num_color_channels = 1,
		.color_row_stride = 3, .color_pixels = &.{10,20,30,40,50,60},
		.alpha_row_stride = 3, .alpha_pixels = &.{1,2,3,4,5,6},
		.preview_width = 2, .preview_height = 1,
		.extra_planes = &.{.{ .info = .{ .type = .depth, .dim_shift = 1, .bit_depth = .{ .bits_per_sample = 8 } }, .row_stride = 2, .pixels = &.{7,99} }},
	}, null);
	defer std.testing.allocator.free(bytes);
	try checkPlanes(bytes, &.{ &.{10,20}, &.{1,2}, &.{7} });
}

fn checkPlanes(bytes: []const u8, expected: []const []const i32) !void {
	var reader = @import("../lib/base/bit_reader.zig").BitReader.init(bytes[2..]);
	var metadata: metadata_mod.CodecMetadata = .{};
	metadata.size = @import("../lib/codec/headers.zig").SizeHeader.readFromBitStream(&reader);
	metadata.m = try metadata_mod.ImageMetadata.readFromBitStream(&reader);
	metadata.transform_data = try metadata_mod.CustomTransformData.readFromBitStream(&reader, metadata.m.xyb_encoded);
	try reader.jumpToByteBoundary();
	var preview = FrameDecoder.init(std.testing.allocator, &metadata);
	defer preview.deinit();
	preview.is_preview = true;
	try preview.decodeFrame(bytes[2 + reader.totalBitsConsumed() / 8 ..]);
	const image = preview.getDecodedImage();
	try std.testing.expectEqual(@as(usize, 2), image.w);
	try std.testing.expectEqual(@as(usize, 1), image.h);
	try std.testing.expectEqual(expected.len, image.channels.items.len);
	for (expected, image.channels.items) |samples, channel| try std.testing.expectEqualSlices(i32, samples, channel.rowConst(0));
}

fn encodeWithAllocator(allocator: std.mem.Allocator) !void {
	const bytes = try encoder.encodeSimplePackedU8(allocator, .{
		.width = 2, .height = 2, .num_color_channels = 3,
		.color_row_stride = 6, .color_pixels = &.{0,10,20,30,40,50,60,70,80,90,100,110},
		.preview_width = 1, .preview_height = 1,
	}, null);
	defer allocator.free(bytes);
	try std.testing.expect(bytes.len > 0);
}

test "encoded preview releases every allocation on encoder failure" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeWithAllocator, .{});
}
