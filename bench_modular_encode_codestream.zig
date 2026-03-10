// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// Narrow real encode benchmark for the current lossless modular RGB path.
// It exercises section assembly and codestream writing for the working
// multi-group `600x300` encoder slice instead of the old synthetic prepass.

const std = @import("std");
const BitReader = @import("src/lib/base/bit_reader.zig").BitReader;
const BitWriter = @import("src/lib/base/bit_writer.zig").BitWriter;
const headers = @import("src/lib/codec/headers.zig");
const image_metadata = @import("src/lib/codec/image_metadata.zig");
const frame_header_mod = @import("src/lib/codec/frame_header.zig");
const toc = @import("src/lib/codec/toc.zig");
const enc_frame = @import("src/lib/codec/enc_frame.zig");
const enc_codestream = @import("src/lib/codec/enc_codestream.zig");
const enc_encoding = @import("src/lib/modular/enc_encoding.zig");
const modular_image = @import("src/lib/modular/modular_image.zig");

const testing = std.testing;

pub const WorkloadConfig = struct {
	repeat: usize = 1,
};

pub const WorkloadResult = struct {
	checksum: u64 = 0,
	total_bytes: u64 = 0,
	total_sections: u64 = 0,
};

fn mixChecksum(hash: *u64, value: u64) void {
	hash.* ^=
		value +% 0x9E3779B97F4A7C15 +%
		(hash.* << 6) +%
		(hash.* >> 2);
}

fn expectedRgbFixturePixel(x: usize, y: usize) [3]i32 {
	return .{
		@intCast(x * 255 / 599),
		@intCast(y * 255 / 299),
		@intCast((x + y) * 255 / 898),
	};
}

fn prepareFixture() !struct {
	codec_meta: image_metadata.CodecMetadata,
	frame_header: frame_header_mod.FrameHeader,
	frame_dim: @import("src/lib/codec/frame_dimensions.zig").FrameDimensions,
} {
	const data = @embedFile("src/lib/testdata/lossless_600x300_multigroup_rgb.jxl");
	var br = BitReader.init(data[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.m = metadata;
	codec_meta.size = size;
	codec_meta.transform_data = transform_data;

	const frame_header = try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
	return .{
		.codec_meta = codec_meta,
		.frame_header = frame_header,
		.frame_dim = frame_header.toFrameDimensions(&codec_meta, false),
	};
}

fn buildSourceImage(allocator: std.mem.Allocator) !modular_image.Image {
	var image = try modular_image.Image.create(allocator, 600, 300, 8, 3);
	for (0..image.h) |y| {
		for (0..image.w) |x| {
			const pixel = expectedRgbFixturePixel(x, y);
			image.channels.items[0].row(y)[x] = pixel[0];
			image.channels.items[1].row(y)[x] = pixel[1];
			image.channels.items[2].row(y)[x] = pixel[2];
		}
	}
	return image;
}

fn runRealEncodeBenchmark(allocator: std.mem.Allocator, cfg: WorkloadConfig) !WorkloadResult {
	const prepared = try prepareFixture();
	var source = try buildSourceImage(allocator);
	defer source.deinit();
	var hist_cache = enc_encoding.FlatHistogramInfoCache.init(allocator);
	defer hist_cache.deinit();

	const num_sections = toc.numTocEntries(
		prepared.frame_dim.num_groups,
		prepared.frame_dim.num_dc_groups,
		prepared.frame_header.passes.num_passes,
	);
	const ac_global_index = 1 + prepared.frame_dim.num_dc_groups;

	var result = WorkloadResult{
		.checksum = 0xCBF29CE484222325,
	};

	for (0..cfg.repeat) |_| {
		const section_writers = try allocator.alloc(BitWriter, num_sections);
		defer allocator.free(section_writers);
		for (section_writers) |*section_writer| {
			section_writer.* = BitWriter.init(allocator);
		}
		defer for (section_writers) |*section_writer| {
			section_writer.deinit();
		};

		try section_writers[0].write(1, 1); // DequantMatrices all_default
		try section_writers[0].write(1, 0); // no global MA tree
		try enc_encoding.writeEmptyModularGroup(&section_writers[0]);
		try section_writers[0].zeroPadToByte();

		for (ac_global_index + 1..num_sections) |section_id| {
			const group_id = (section_id - ac_global_index - 1) % prepared.frame_dim.num_groups;
			_ = try enc_encoding.writeSingleNodeLocalTreeGroupImageRectWithCache(
				allocator,
				&source,
				prepared.frame_dim.groupRect(group_id),
				.gradient,
				&hist_cache,
				&section_writers[section_id],
			);
			try section_writers[section_id].zeroPadToByte();
		}

		const section_payloads = try allocator.alloc([]const u8, num_sections);
		defer allocator.free(section_payloads);
		for (section_writers, 0..) |*section_writer, i| {
			section_payloads[i] = section_writer.bytes();
		}

		var frame_writer = BitWriter.init(allocator);
		defer frame_writer.deinit();
		try enc_frame.writeFrame(&prepared.frame_header, &prepared.codec_meta, section_payloads, &frame_writer);
		try frame_writer.zeroPadToByte();

		var codestream = BitWriter.init(allocator);
		defer codestream.deinit();
		try enc_codestream.writeCodestream(&prepared.codec_meta, frame_writer.bytes(), &codestream);
		try codestream.zeroPadToByte();

		result.total_bytes += codestream.bytes().len;
		result.total_sections += num_sections;
		for (codestream.bytes()) |byte| {
			mixChecksum(&result.checksum, byte);
		}
		mixChecksum(&result.checksum, codestream.bytes().len);
	}

	return result;
}

fn parseArgs(args: []const []const u8) !struct {
	cfg: WorkloadConfig,
	print_checksum: bool,
	expect_checksum: ?u64,
} {
	var cfg = WorkloadConfig{};
	var print_checksum = false;
	var expect_checksum: ?u64 = null;

	var i: usize = 1;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--repeat")) {
			i += 1;
			if (i >= args.len) return error.InvalidArgs;
			cfg.repeat = try std.fmt.parseInt(usize, args[i], 10);
			continue;
		}
		if (std.mem.eql(u8, arg, "--print-checksum")) {
			print_checksum = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--expect-checksum")) {
			i += 1;
			if (i >= args.len) return error.InvalidArgs;
			expect_checksum = try std.fmt.parseInt(u64, args[i], 16);
			continue;
		}
		return error.InvalidArgs;
	}

	return .{
		.cfg = cfg,
		.print_checksum = print_checksum,
		.expect_checksum = expect_checksum,
	};
}

pub fn main() !void {
	const allocator = std.heap.page_allocator;
	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	const parsed = try parseArgs(args);
	const result = try runRealEncodeBenchmark(allocator, parsed.cfg);

	if (parsed.expect_checksum) |expected| {
		if (result.checksum != expected) return error.ChecksumMismatch;
	}

	if (parsed.print_checksum) {
		var stdout_buffer: [4096]u8 = undefined;
		var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
		const stdout = &stdout_writer.interface;
		try stdout.print("{x}\n", .{result.checksum});
		try stdout.flush();
	}
}

test "real modular encode benchmark checksum is stable" {
	const result = try runRealEncodeBenchmark(testing.allocator, .{ .repeat = 1 });
	try testing.expectEqual(@as(u64, 323341), result.total_bytes);
	try testing.expectEqual(@as(u64, 9), result.total_sections);
	try testing.expectEqual(@as(u64, 0x51a7f7f35462a14a), result.checksum);
}
