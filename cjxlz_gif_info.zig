const std = @import("std");
const jxlz = @import("src/root.zig");
const BitReader = jxlz.base.bit_reader.BitReader;
const headers = jxlz.codec.headers;
const image_metadata = jxlz.codec.image_metadata;
const dec_frame = jxlz.codec.dec_frame;

pub fn main() !void {
	var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa_state.deinit();
	const gpa = gpa_state.allocator();

	var args = try std.process.argsWithAllocator(gpa);
	defer args.deinit();
	_ = args.next();
	const path = args.next() orelse return error.InvalidArgs;

	const bytes = try std.fs.cwd().readFileAlloc(gpa, path, std.math.maxInt(usize));
	defer gpa.free(bytes);
	if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != headers.codestream_marker) return error.InvalidArgs;

	var br = BitReader.init(bytes[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	var frame_count: usize = 0;
	var durations: std.ArrayList(u32) = .{};
	defer durations.deinit(gpa);

	while (frame_offset < bytes.len) {
		const frame_bytes = try dec_frame.frameByteCount(gpa, &codec_meta, bytes[frame_offset..]);
		var frame_dec = dec_frame.FrameDecoder.init(gpa, &codec_meta);
		defer frame_dec.deinit();
		var frame_br = BitReader.init(bytes[frame_offset .. frame_offset + frame_bytes]);
		try frame_dec.initFrame(&frame_br);
		try durations.append(gpa, frame_dec.frame_header.animation_frame.duration);
		frame_count += 1;
		frame_offset += frame_bytes;
		if (frame_dec.frame_header.is_last) break;
	}

	var stdout_buffer: [4096]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
	const stdout = &stdout_writer.interface;
	try stdout.print(
		"{d} {d} {d} {d} {d}",
		.{
			metadata.animation.tps_numerator,
			metadata.animation.tps_denominator,
			metadata.animation.num_loops,
			@intFromBool(metadata.animation.have_timecodes),
			frame_count,
		},
	);
	for (durations.items) |duration| {
		try stdout.print(" {d}", .{duration});
	}
	try stdout.writeByte('\n');
	try stdout.flush();
}
