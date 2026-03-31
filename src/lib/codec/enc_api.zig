const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const headers = @import("headers.zig");
const color_encoding_mod = @import("color_encoding.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const toc = @import("toc.zig");
const enc_frame = @import("enc_frame.zig");
const enc_codestream = @import("enc_codestream.zig");
const dec_frame = @import("dec_frame.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");
const modular_image = @import("../modular/modular_image.zig");

pub const SimpleInterleavedU8Image = struct {
	width: u32,
	height: u32,
	num_channels: u32,
	num_extra_channels: u32 = 0,
	alpha_associated: bool = false,
	extra_channel_info: []const image_metadata.ExtraChannelInfo = &.{},
	row_stride: usize,
	pixels: []const u8,
};

fn graySrgbColorEncoding() color_encoding_mod.ColorEncoding {
	return .{
		.color_space = .gray,
		.white_point = .d65,
		.primaries = .srgb,
		.tf = .{ .have_gamma = false, .transfer_function = .srgb },
		.rendering_intent = .relative,
	};
}

fn validateSimpleImage(image: SimpleInterleavedU8Image) !void {
	if (image.width == 0 or image.height == 0) return error.InvalidArgs;
	if (image.num_extra_channels > 1) return error.Unsupported;
	if (image.num_channels < image.num_extra_channels) return error.InvalidArgs;
	const num_color_channels = image.num_channels - image.num_extra_channels;
	if (!((num_color_channels == 1 or num_color_channels == 3) and
		(image.num_extra_channels == 0 or image.num_extra_channels == 1))) return error.Unsupported;
	if (image.num_extra_channels == 1 and !(image.num_channels == 2 or image.num_channels == 4)) return error.Unsupported;
	if (image.num_extra_channels == 0 and image.alpha_associated) return error.Unsupported;
	if (image.num_extra_channels > 1 and image.extra_channel_info.len != image.num_extra_channels) return error.InvalidArgs;
	if (image.extra_channel_info.len != 0 and image.extra_channel_info.len != image.num_extra_channels) return error.InvalidArgs;

	const min_row_stride = @as(usize, image.width) * image.num_channels;
	if (image.row_stride < min_row_stride) return error.InvalidArgs;
	const needed = image.row_stride * @as(usize, image.height);
	if (image.pixels.len < needed) return error.InvalidArgs;
}

fn buildCodecMetadata(
	image: SimpleInterleavedU8Image,
	color_encoding: color_encoding_mod.ColorEncoding,
) image_metadata.CodecMetadata {
	var codec_meta = image_metadata.CodecMetadata{};
	codec_meta.size = .{
		.small = false,
		.ysize_raw = image.height,
		.ratio = 0,
		.xsize_raw = image.width,
	};
	codec_meta.m = .{
		.bit_depth = .{},
		.modular_16_bit_buffer_sufficient = true,
		.xyb_encoded = false,
		.color_encoding = color_encoding,
	};
	if (image.num_extra_channels != 0) {
		codec_meta.m.num_extra_channels = image.num_extra_channels;
		codec_meta.m.extra_channel_count = image.num_extra_channels;
		if (image.extra_channel_info.len != 0) {
			for (image.extra_channel_info, 0..) |extra, i| {
				codec_meta.m.extra_channel_info[i] = extra;
			}
		} else if (image.num_extra_channels == 1) {
			codec_meta.m.extra_channel_info[0] = .{
				.type = .alpha,
				.bit_depth = .{},
				.alpha_associated = image.alpha_associated,
			};
		}
	}
	codec_meta.transform_data = .{};
	return codec_meta;
}

fn buildSimpleFrameHeader() frame_header_mod.FrameHeader {
	return .{
		.encoding = .modular,
		.color_transform = .none,
		.loop_filter = .{},
	};
}

fn buildSourceImage(allocator: std.mem.Allocator, image: SimpleInterleavedU8Image) !modular_image.Image {
	var source = try modular_image.Image.create(
		allocator,
		image.width,
		image.height,
		8,
		image.num_channels,
	);
	errdefer source.deinit();

	for (0..source.h) |y| {
		const row = image.pixels[y * image.row_stride .. y * image.row_stride + image.row_stride];
		for (0..source.w) |x| {
			const pixel_base = x * image.num_channels;
			for (0..source.channels.items.len) |c| {
				source.channels.items[c].row(y)[x] = row[pixel_base + c];
			}
		}
	}

	return source;
}

/// Encodes the current narrow lossless modular surface from interleaved uint8
/// grayscale or RGB pixels by tiling local-tree groups and assembling a full
/// native codestream entirely in Zig.
pub fn encodeSimpleInterleavedU8(
	allocator: std.mem.Allocator,
	image: SimpleInterleavedU8Image,
	color_encoding: ?color_encoding_mod.ColorEncoding,
) ![]u8 {
	try validateSimpleImage(image);
	const num_color_channels = image.num_channels - image.num_extra_channels;

	const effective_color_encoding = color_encoding orelse if (num_color_channels == 1)
		graySrgbColorEncoding()
	else
		color_encoding_mod.ColorEncoding{};
	if (effective_color_encoding.channels() != num_color_channels) return error.Unsupported;
	if (effective_color_encoding.want_icc) return error.Unsupported;

	const codec_meta = buildCodecMetadata(image, effective_color_encoding);
	var frame_header = buildSimpleFrameHeader();
	for (0..image.num_extra_channels) |extra_index| {
		frame_header.extra_channel_upsampling[extra_index] = 1;
	}
	const frame_dim = frame_header.toFrameDimensions(&codec_meta, false);

	var source = try buildSourceImage(allocator, image);
	defer source.deinit();
	var hist_cache = enc_encoding.FlatHistogramInfoCache.init(allocator);
	defer hist_cache.deinit();

	const num_sections = toc.numTocEntries(
		frame_dim.num_groups,
		frame_dim.num_dc_groups,
		frame_header.passes.num_passes,
	);
	const ac_global_index = 1 + frame_dim.num_dc_groups;

	const section_writers = try allocator.alloc(BitWriter, num_sections);
	defer allocator.free(section_writers);
	for (section_writers) |*section_writer| {
		section_writer.* = BitWriter.init(allocator);
	}
	defer for (section_writers) |*section_writer| {
		section_writer.deinit();
	};

	try section_writers[0].write(1, 1);
	try section_writers[0].write(1, 0);
	if (num_sections == 1) {
		_ = try enc_encoding.writeSingleNodeLocalTreeGroupImageWithCache(
			allocator,
			&source,
			.gradient,
			&hist_cache,
			&section_writers[0],
		);
		try section_writers[0].zeroPadToByte();
	} else {
		try enc_encoding.writeEmptyModularGroup(&section_writers[0]);
		try section_writers[0].zeroPadToByte();

		for (ac_global_index + 1..num_sections) |section_id| {
			const group_id = (section_id - ac_global_index - 1) % frame_dim.num_groups;
			_ = try enc_encoding.writeSingleNodeLocalTreeGroupImageRectWithCache(
				allocator,
				&source,
				frame_dim.groupRect(group_id),
				.gradient,
				&hist_cache,
				&section_writers[section_id],
			);
			try section_writers[section_id].zeroPadToByte();
		}
	}

	const section_payloads = try allocator.alloc([]const u8, num_sections);
	defer allocator.free(section_payloads);
	for (section_writers, 0..) |*section_writer, i| {
		section_payloads[i] = section_writer.bytes();
	}

	var frame_writer = BitWriter.init(allocator);
	defer frame_writer.deinit();
	try enc_frame.writeFrame(&frame_header, &codec_meta, section_payloads, &frame_writer);
	try frame_writer.zeroPadToByte();

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try enc_codestream.writeCodestream(&codec_meta, frame_writer.bytes(), &codestream);
	try codestream.zeroPadToByte();

	return allocator.dupe(u8, codestream.bytes());
}

const testing = std.testing;

fn expectCodestreamRoundtrip(
	allocator: std.mem.Allocator,
	encoded: []const u8,
	expected: SimpleInterleavedU8Image,
) !void {
	var br = BitReader.init(encoded[2..]);
	const size = headers.SizeHeader.readFromBitStream(&br);
	const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
	const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
	try br.jumpToByteBoundary();

	var parsed_meta = image_metadata.CodecMetadata{};
	parsed_meta.m = metadata;
	parsed_meta.size = size;
	parsed_meta.transform_data = transform_data;

	const frame_offset = br.totalBitsConsumed() / 8;
	var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
	defer frame_dec.deinit();
	try frame_dec.decodeFrame(encoded[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, expected.num_channels), image.channels.items.len);
	try testing.expectEqual(@as(usize, expected.width), image.w);
	try testing.expectEqual(@as(usize, expected.height), image.h);

	for (0..image.h) |y| {
		const expected_row = expected.pixels[y * expected.row_stride .. y * expected.row_stride + expected.row_stride];
		for (0..image.w) |x| {
			const pixel_base = x * expected.num_channels;
			for (0..image.channels.items.len) |c| {
				try testing.expectEqual(@as(i32, expected_row[pixel_base + c]), image.channels.items[c].row(y)[x]);
			}
		}
	}
}

test "encodeSimpleInterleavedU8 round-trips grayscale through FrameDecoder" {
	const pixels = [_]u8{
		10, 20, 30,
		40, 50, 60,
	};
	const image = SimpleInterleavedU8Image{
		.width = 3,
		.height = 2,
		.num_channels = 1,
		.row_stride = 3,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips RGB through FrameDecoder" {
	const pixels = [_]u8{
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const image = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 3,
		.row_stride = 6,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips grayscale plus alpha through FrameDecoder" {
	const pixels = [_]u8{
		5, 255, 10, 128, 15, 64,
		20, 32, 25, 16, 30, 0,
	};
	const image = SimpleInterleavedU8Image{
		.width = 3,
		.height = 2,
		.num_channels = 2,
		.num_extra_channels = 1,
		.row_stride = 6,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}

test "encodeSimpleInterleavedU8 round-trips RGBA through FrameDecoder" {
	const pixels = [_]u8{
		0, 10, 20, 255, 30, 40, 50, 128,
		60, 70, 80, 64, 90, 100, 110, 0,
	};
	const image = SimpleInterleavedU8Image{
		.width = 2,
		.height = 2,
		.num_channels = 4,
		.num_extra_channels = 1,
		.row_stride = 8,
		.pixels = &pixels,
	};
	const encoded = try encodeSimpleInterleavedU8(testing.allocator, image, null);
	defer testing.allocator.free(encoded);
	try expectCodestreamRoundtrip(testing.allocator, encoded, image);
}
