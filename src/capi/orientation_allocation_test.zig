const std = @import("std");
const FrameDecoder = @import("../lib/codec/dec_frame.zig").FrameDecoder;
const CodecMetadata = @import("../lib/codec/image_metadata.zig").CodecMetadata;
const Image = @import("../lib/modular/modular_image.zig").Image;
const output = @import("output_buffer.zig");
const fixture = @import("orientation_fixture.zig");

fn checkAllocation(allocator: std.mem.Allocator, frame: *FrameDecoder, metadata: *CodecMetadata) !void {
	var pixels: [18]u8 = undefined;
	try output.writeOrientedFrameDecoderOutput(allocator, frame, metadata, 2, .{ .num_channels = 3, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 }, &pixels, pixels.len);
	try std.testing.expectEqualSlices(u8, &fixture.pixels_2_0, &pixels);
}

test "orientation temporary pixels release every allocation on success and failure" {
	var metadata: CodecMetadata = .{};
	metadata.m.xyb_encoded = false;
	metadata.m.bit_depth.bits_per_sample = 8;
	metadata.m.color_encoding.color_space = .rgb;
	var frame = FrameDecoder.init(std.testing.allocator, &metadata);
	defer frame.deinit();
	frame.frame_header.color_transform = .none;
	frame.modular_decoder.full_image.deinit();
	frame.modular_decoder.full_image = try Image.create(std.testing.allocator, 3, 2, 8, 3);
	for (0..2) |y| for (0..3) |x| {
		for (0..3) |channel| frame.modular_decoder.full_image.channels.items[channel].row(y)[x] = fixture.pixels_1_1[(y * 3 + x) * 3 + channel];
	};
	try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocation, .{ &frame, &metadata });
	var pixels: [12]u8 = undefined;
	try std.testing.expectError(error.Unsupported, output.writeOrientedFrameDecoderOutput(std.testing.allocator, &frame, &metadata, 2, .{ .num_channels = 2, .data_type = .JXL_TYPE_UINT8, .endianness = .JXL_NATIVE_ENDIAN, .@"align" = 0 }, &pixels, pixels.len));
}
