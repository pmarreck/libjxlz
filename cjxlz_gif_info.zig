const std = @import("std");
const jxlz = @import("src/root.zig");
const BitReader = jxlz.base.bit_reader.BitReader;
const headers = jxlz.codec.headers;
const image_metadata = jxlz.codec.image_metadata;
const icc_codec = jxlz.codec.icc_codec;
const dec_frame = jxlz.codec.dec_frame;

pub fn main(init: std.process.Init) !void {
	const gpa = init.gpa;
	const io = init.io;

	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len < 2) return error.InvalidArgs;
	const path = args[1];

	const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
	defer gpa.free(bytes);
	if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != headers.codestream_marker) return error.InvalidArgs;

	var br = BitReader.init(bytes[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	const embedded_icc = if (metadata.color_encoding.want_icc)
		try icc_codec.decompressICCFromBitReader(gpa, &br)
	else
		&[_]u8{};
	defer if (embedded_icc.len != 0) gpa.free(embedded_icc);
	try br.jumpToByteBoundary();

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = size;
	codec_meta.m = metadata;
	codec_meta.transform_data = transform_data;

	var frame_offset = 2 + br.totalBitsConsumed() / 8;
	var frame_count: usize = 0;
	var durations: std.ArrayList(u32) = .empty;
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
	var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
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
