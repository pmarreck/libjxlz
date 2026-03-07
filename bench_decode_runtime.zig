const std = @import("std");

const BitReader = @import("src/lib/base/bit_reader.zig").BitReader;
const headers = @import("src/lib/codec/headers.zig");
const image_metadata = @import("src/lib/codec/image_metadata.zig");
const frame_header_mod = @import("src/lib/codec/frame_header.zig");
const dec_frame = @import("src/lib/codec/dec_frame.zig");
const encoding = @import("src/lib/modular/encoding.zig");

fn decodeBytesWithReaderStrategy(
	comptime reader_strategy: encoding.ReaderStrategy,
	allocator: std.mem.Allocator,
	data: []const u8,
) !u64 {
	if (data.len < 4 or data[0] != 0xFF or data[1] != 0x0A) {
		return error.InvalidData;
	}

	var br = BitReader.init(data[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.m = metadata;
	codec_meta.size = size;
	codec_meta.transform_data = transform_data;

	const frame_header_byte_offset = br.totalBitsConsumed() / 8;
	const fh = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
	_ = fh;

	const frame_data = data[2 + frame_header_byte_offset ..];
	var frame_dec = dec_frame.FrameDecoder.init(allocator, &codec_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrameWithReaderStrategy(reader_strategy, frame_data);

	const img = frame_dec.getDecodedImage();
	var checksum: u64 = @as(u64, img.w) *% 1315423911 ^ @as(u64, img.h);
	for (img.channels.items) |*ch| {
		if (ch.w == 0 or ch.h == 0) continue;
		const r0 = ch.rowConst(0);
		const r1 = ch.rowConst(ch.h - 1);
		const first_bits: u32 = @bitCast(@as(i32, r0[0]));
		const last_bits: u32 = @bitCast(@as(i32, r1[ch.w - 1]));
		checksum = checksum *% 1315423911 ^ @as(u64, first_bits);
		checksum = checksum *% 1315423911 ^ @as(u64, last_bits);
	}
	return checksum;
}

pub fn main() !void {
	const allocator = std.heap.c_allocator;

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);
	if (args.len < 2) {
		std.debug.print(
			"usage: {s} [--repeat N] [--reader reference|specialized] <file.jxl> [more.jxl ...]\n",
			.{args[0]},
		);
		return error.InvalidArgs;
	}

	var repeat: usize = 1;
	var reader_strategy: encoding.ReaderStrategy = .specialized;
	var arg_i: usize = 1;
	while (arg_i < args.len and std.mem.startsWith(u8, args[arg_i], "--")) {
		if (std.mem.eql(u8, args[arg_i], "--repeat")) {
			if (arg_i + 1 >= args.len) return error.InvalidArgs;
			repeat = try std.fmt.parseInt(usize, args[arg_i + 1], 10);
			if (repeat == 0) return error.InvalidArgs;
			arg_i += 2;
			continue;
		}
		if (std.mem.eql(u8, args[arg_i], "--reader")) {
			if (arg_i + 1 >= args.len) return error.InvalidArgs;
			reader_strategy = std.meta.stringToEnum(encoding.ReaderStrategy, args[arg_i + 1]) orelse
				return error.InvalidArgs;
			arg_i += 2;
			continue;
		}
		return error.InvalidArgs;
	}
	if (arg_i >= args.len) return error.InvalidArgs;

	const file_count = args.len - arg_i;
	const buffers = try allocator.alloc([]const u8, file_count);
	defer allocator.free(buffers);
	var b: usize = 0;
	while (b < file_count) : (b += 1) {
		buffers[b] = try std.fs.cwd().readFileAlloc(allocator, args[arg_i + b], std.math.maxInt(usize));
	}
	defer {
		for (buffers) |buf| allocator.free(buf);
	}

	var combined: u64 = 0;
	var r: usize = 0;
	while (r < repeat) : (r += 1) {
		var i: usize = 0;
		while (i < file_count) : (i += 1) {
			const c = switch (reader_strategy) {
				.reference => decodeBytesWithReaderStrategy(.reference, allocator, buffers[i]),
				.specialized => decodeBytesWithReaderStrategy(.specialized, allocator, buffers[i]),
			} catch |err| {
				std.debug.print("decode failed: {s}: {s}\n", .{ args[arg_i + i], @errorName(err) });
				return err;
			};
			combined ^= c;
		}
	}

	if (combined == 0xDEADBEEFDEADBEEF) {
		std.debug.print("checksum={x}\n", .{combined});
	}
}
