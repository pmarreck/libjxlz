const std = @import("std");

const BitReader = @import("src/lib/base/bit_reader.zig").BitReader;
const headers = @import("src/lib/codec/headers.zig");
const image_metadata = @import("src/lib/codec/image_metadata.zig");
const frame_header_mod = @import("src/lib/codec/frame_header.zig");
const dec_frame = @import("src/lib/codec/dec_frame.zig");
const encoding = @import("src/lib/modular/encoding.zig");
const Image = @import("src/lib/modular/modular_image.zig").Image;

const KnownChecksum = struct {
	basename: []const u8,
	fingerprint: u64,
};

const known_checksums = [_]KnownChecksum{
	.{ .basename = "lossless_4x4.jxl", .fingerprint = 0xb34bbdfb4006e0ad },
	.{ .basename = "lossless_16x16.jxl", .fingerprint = 0x8d2ce261c90996f1 },
	.{ .basename = "lossless_64x64.jxl", .fingerprint = 0x11cf3b0722a55989 },
	.{ .basename = "lossless_300x200.jxl", .fingerprint = 0x86d35c710bed2f52 },
	.{ .basename = "lossless_600x10_multisection.jxl", .fingerprint = 0xde7cd4ac7d5ee5f8 },
	.{ .basename = "lossless_600x300_multigroup_rgb.jxl", .fingerprint = 0x46a9b99dc0102a21 },
};

fn mix(acc: *u64, value: u64) void {
	acc.* = (acc.* ^ value) *% 0x100000001b3;
}

fn mixPixel(acc: *u64, value: i32) void {
	const bits: u32 = @bitCast(value);
	mix(acc, bits);
}

fn appendPoint(points: []usize, count: *usize, candidate: usize) void {
	var i: usize = 0;
	while (i < count.*) : (i += 1) {
		if (points[i] == candidate) return;
	}
	points[count.*] = candidate;
	count.* += 1;
}

fn samplePoints(comptime max_points: usize, len: usize) struct { points: [max_points]usize, len: usize } {
	var result = [_]usize{0} ** max_points;
	var count: usize = 0;
	if (len == 0) return .{ .points = result, .len = 0 };

	const last = len - 1;
	appendPoint(&result, &count, 0);
	appendPoint(&result, &count, last / 4);
	appendPoint(&result, &count, last / 2);
	appendPoint(&result, &count, (last * 3) / 4);
	appendPoint(&result, &count, last);
	appendPoint(&result, &count, @min(last, 255));
	appendPoint(&result, &count, @min(last, 256));
	appendPoint(&result, &count, @min(last, 511));
	appendPoint(&result, &count, @min(last, 512));
	return .{ .points = result, .len = count };
}

fn imageFingerprint(img: *const Image) u64 {
	var acc: u64 = 0xcbf29ce484222325;
	mix(&acc, img.w);
	mix(&acc, img.h);
	mix(&acc, img.channels.items.len);

	for (img.channels.items, 0..) |*ch, c| {
		const hshift_bits: u32 = @bitCast(@as(i32, ch.hshift));
		const vshift_bits: u32 = @bitCast(@as(i32, ch.vshift));
		mix(&acc, c);
		mix(&acc, ch.w);
		mix(&acc, ch.h);
		mix(&acc, hshift_bits);
		mix(&acc, vshift_bits);
		const xs = samplePoints(9, ch.w);
		const ys = samplePoints(9, ch.h);
		var yi: usize = 0;
		while (yi < ys.len) : (yi += 1) {
			const row = ch.rowConst(ys.points[yi]);
			var xi: usize = 0;
			while (xi < xs.len) : (xi += 1) {
				mixPixel(&acc, row[xs.points[xi]]);
			}
		}
	}

	return acc;
}

fn expectedFingerprintForPath(path: []const u8) ?u64 {
	const basename = std.fs.path.basename(path);
	for (known_checksums) |known| {
		if (std.mem.eql(u8, basename, known.basename)) return known.fingerprint;
	}
	return null;
}

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

	return imageFingerprint(frame_dec.getDecodedImage());
}

pub fn main(init: std.process.Init) !void {
	const allocator = std.heap.c_allocator;

	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len < 2) {
		std.debug.print(
			"usage: {s} [--repeat N] [--reader reference|specialized] [--no-verify-known] [--print-checksum] <file.jxl> [more.jxl ...]\n",
			.{args[0]},
		);
		return error.InvalidArgs;
	}

	var repeat: usize = 1;
	var reader_strategy: encoding.ReaderStrategy = .specialized;
	var verify_known = true;
	var print_checksum = false;
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
		if (std.mem.eql(u8, args[arg_i], "--no-verify-known")) {
			verify_known = false;
			arg_i += 1;
			continue;
		}
		if (std.mem.eql(u8, args[arg_i], "--print-checksum")) {
			print_checksum = true;
			arg_i += 1;
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
			if (print_checksum) {
				std.debug.print("{s} {x}\n", .{ std.fs.path.basename(args[arg_i + i]), c });
			}
			if (verify_known) {
				if (expectedFingerprintForPath(args[arg_i + i])) |expected| {
					if (c != expected) {
						std.debug.print(
							"checksum mismatch: {s}: got {x}, expected {x}\n",
							.{ args[arg_i + i], c, expected },
						);
						return error.ChecksumMismatch;
					}
				}
			}
			combined ^= c;
		}
	}

	if (combined == 0xDEADBEEFDEADBEEF) {
		std.debug.print("checksum={x}\n", .{combined});
	}
}

test "samplePoints includes group boundaries" {
	const samples = samplePoints(9, 600);
	try std.testing.expectEqual(@as(usize, 9), samples.len);
	try std.testing.expectEqual(@as(usize, 255), samples.points[5]);
	try std.testing.expectEqual(@as(usize, 256), samples.points[6]);
	try std.testing.expectEqual(@as(usize, 511), samples.points[7]);
	try std.testing.expectEqual(@as(usize, 512), samples.points[8]);
}

test "expectedFingerprintForPath matches basename only" {
	try std.testing.expect(expectedFingerprintForPath("src/lib/testdata/lossless_4x4.jxl") != null);
	try std.testing.expect(expectedFingerprintForPath("/tmp/lossless_600x300_multigroup_rgb.jxl") != null);
	try std.testing.expectEqual(@as(?u64, null), expectedFingerprintForPath("unknown.jxl"));
}

test "known fixture fingerprints stay stable" {
	const allocator = std.testing.allocator;
	const cases = [_][]const u8{
		@embedFile("src/lib/testdata/lossless_4x4.jxl"),
		@embedFile("src/lib/testdata/lossless_16x16.jxl"),
		@embedFile("src/lib/testdata/lossless_64x64.jxl"),
		@embedFile("src/lib/testdata/lossless_300x200.jxl"),
		@embedFile("src/lib/testdata/lossless_600x10_multisection.jxl"),
		@embedFile("src/lib/testdata/lossless_600x300_multigroup_rgb.jxl"),
	};

	for (known_checksums, cases) |known, data| {
		const fingerprint = try decodeBytesWithReaderStrategy(.specialized, allocator, data);
		try std.testing.expectEqual(known.fingerprint, fingerprint);
	}
}
