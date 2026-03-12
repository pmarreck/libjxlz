// Encoder-side codestream-shell helpers.
// Starts with native SizeHeader/ImageMetadata/CustomTransformData writers.

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
const headers = @import("headers.zig");
const image_metadata = @import("image_metadata.zig");
const frame_header_mod = @import("frame_header.zig");
const toc = @import("toc.zig");
const dec_frame = @import("dec_frame.zig");
const enc_frame = @import("enc_frame.zig");
const enc_encoding = @import("../modular/enc_encoding.zig");
const modular_image = @import("../modular/modular_image.zig");

const Channel = modular_image.Channel;

fn expectedRgbFixturePixel(x: usize, y: usize) [3]i32 {
	return .{
		@intCast(x * 255 / 599),
		@intCast(y * 255 / 299),
		@intCast((x + y) * 255 / 898),
	};
}

fn prepareFrame(data: []const u8) !struct {
	codec_meta: image_metadata.CodecMetadata,
	frame_data: []const u8,
} {
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
    return .{
        .codec_meta = codec_meta,
        .frame_data = data[2 + frame_header_byte_offset ..],
    };
}

fn writeSizeRawValue(value: u32, writer: *BitWriter) !void {
    if (value < (1 << 9) + 1) {
        try writer.write(2, 0);
        try writer.write(9, value - 1);
        return;
    }
    if (value < (1 << 13) + 1) {
        try writer.write(2, 1);
        try writer.write(13, value - 1);
        return;
    }
    if (value < (1 << 18) + 1) {
        try writer.write(2, 2);
        try writer.write(18, value - 1);
        return;
    }
    try writer.write(2, 3);
    try writer.write(30, value - 1);
}

/// Emits the non-small ratio-0 SizeHeader form for arbitrary dimensions.
pub fn writeRawSizeHeader(xsize: u32, ysize: u32, writer: *BitWriter) !void {
    std.debug.assert(xsize > 0 and ysize > 0);
    try writer.write(1, 0); // non-small
    try writeSizeRawValue(ysize, writer);
    try writer.write(3, 0); // ratio = 0, xsize written explicitly
    try writeSizeRawValue(xsize, writer);
}

/// Writes a complete codestream using native Zig serializers for SizeHeader,
/// ImageMetadata, CustomTransformData, and the already-assembled frame payload.
pub fn writeCodestream(
    codec_meta: *const image_metadata.CodecMetadata,
    frame_data: []const u8,
    writer: *BitWriter,
) !void {
    try writer.write(8, 0xFF);
    try writer.write(8, headers.codestream_marker);
    try writeRawSizeHeader(@intCast(codec_meta.xsize()), @intCast(codec_meta.ysize()), writer);
    try image_metadata.writeImageMetadata(&codec_meta.m, writer);
    try image_metadata.writeCustomTransformData(&codec_meta.transform_data, codec_meta.m.xyb_encoded, writer);
    try writer.zeroPadToByte();
    for (frame_data) |byte| {
        try writer.write(8, byte);
    }
}

const testing = std.testing;

test "writeCodestream round-trips a grayscale codestream through header parse and FrameDecoder" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_600x10_multisection.jxl");
    const prepared = try prepareFrame(source_data);

    var codec_meta = prepared.codec_meta;
    codec_meta.size = .{
        .small = false,
        .ysize_raw = 3,
        .ratio = 0,
        .xsize_raw = 3,
    };

    const frame_header = blk: {
        var br = BitReader.init(prepared.frame_data);
        break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    };

    var channel = try Channel.create(allocator, 3, 3, 0, 0);
    defer channel.deinit();
    channel.row(0)[0] = 10;
    channel.row(0)[1] = 12;
    channel.row(0)[2] = 14;
    channel.row(1)[0] = 11;
    channel.row(1)[1] = 13;
    channel.row(1)[2] = 15;
    channel.row(2)[0] = 13;
    channel.row(2)[1] = 14;
    channel.row(2)[2] = 18;

    var dc_global = BitWriter.init(allocator);
    defer dc_global.deinit();
    try dc_global.write(1, 1); // DequantMatrices all_default
    try dc_global.write(1, 0); // no global tree
    try testing.expectEqual(@as(usize, 0), try enc_encoding.writeSingleNodeLocalTreeGroup(
        allocator,
        &channel,
        .gradient,
        &dc_global,
    ));
    try dc_global.zeroPadToByte();

    const sections = [_][]const u8{dc_global.bytes()};
    var frame_writer = BitWriter.init(allocator);
    defer frame_writer.deinit();
    try enc_frame.writeFrame(&frame_header, &codec_meta, &sections, &frame_writer);
    try frame_writer.zeroPadToByte();

    var codestream = BitWriter.init(allocator);
    defer codestream.deinit();
    try writeCodestream(&codec_meta, frame_writer.bytes(), &codestream);
    try codestream.zeroPadToByte();

    const bytes = codestream.bytes();
    try testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try testing.expectEqual(@as(u8, 0x0A), bytes[1]);

    var br = BitReader.init(bytes[2..]);
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 3), size.xsize());
    try testing.expectEqual(@as(usize, 3), size.ysize());
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    try br.jumpToByteBoundary();

    var parsed_meta = image_metadata.CodecMetadata{};
    parsed_meta.m = metadata;
    parsed_meta.size = size;
    parsed_meta.transform_data = transform_data;

    const frame_offset = br.totalBitsConsumed() / 8;
    try testing.expectEqualSlices(u8, frame_writer.bytes(), bytes[2 + frame_offset ..]);
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
    defer frame_dec.deinit();
    try frame_dec.decodeFrame(bytes[2 + frame_offset ..]);

    const image = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 1), image.channels.items.len);
    try testing.expectEqual(@as(usize, 3), image.w);
    try testing.expectEqual(@as(usize, 3), image.h);
    try testing.expectEqualSlices(i32, channel.data, image.channels.items[0].data);
}

test "writeCodestream round-trips an RGB codestream through header parse and FrameDecoder" {
    const allocator = testing.allocator;
    const source_data = @embedFile("../testdata/lossless_4x4.jxl");
    const prepared = try prepareFrame(source_data);

    var codec_meta = prepared.codec_meta;
    codec_meta.size = .{
        .small = false,
        .ysize_raw = 2,
        .ratio = 0,
        .xsize_raw = 3,
    };

    const frame_header = blk: {
        var br = BitReader.init(prepared.frame_data);
        break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &codec_meta, false);
    };

    var source = try modular_image.Image.create(allocator, 3, 2, 8, 3);
    defer source.deinit();

    source.channels.items[0].row(0)[0] = 10;
    source.channels.items[0].row(0)[1] = 12;
    source.channels.items[0].row(0)[2] = 14;
    source.channels.items[0].row(1)[0] = 13;
    source.channels.items[0].row(1)[1] = 15;
    source.channels.items[0].row(1)[2] = 17;

    source.channels.items[1].row(0)[0] = 20;
    source.channels.items[1].row(0)[1] = 19;
    source.channels.items[1].row(0)[2] = 18;
    source.channels.items[1].row(1)[0] = 17;
    source.channels.items[1].row(1)[1] = 16;
    source.channels.items[1].row(1)[2] = 15;

    source.channels.items[2].row(0)[0] = 7;
    source.channels.items[2].row(0)[1] = 8;
    source.channels.items[2].row(0)[2] = 9;
    source.channels.items[2].row(1)[0] = 11;
    source.channels.items[2].row(1)[1] = 12;
    source.channels.items[2].row(1)[2] = 13;

    var dc_global = BitWriter.init(allocator);
    defer dc_global.deinit();
    try dc_global.write(1, 1); // DequantMatrices all_default
    try dc_global.write(1, 0); // no global tree
    try testing.expectEqual(@as(usize, 0), try enc_encoding.writeSingleNodeLocalTreeGroupImage(
        allocator,
        &source,
        .gradient,
        &dc_global,
    ));
    try dc_global.zeroPadToByte();

    const sections = [_][]const u8{dc_global.bytes()};
    var frame_writer = BitWriter.init(allocator);
    defer frame_writer.deinit();
    try enc_frame.writeFrame(&frame_header, &codec_meta, &sections, &frame_writer);
    try frame_writer.zeroPadToByte();

    var codestream = BitWriter.init(allocator);
    defer codestream.deinit();
    try writeCodestream(&codec_meta, frame_writer.bytes(), &codestream);
    try codestream.zeroPadToByte();

    const bytes = codestream.bytes();
    try testing.expectEqual(@as(u8, 0xFF), bytes[0]);
    try testing.expectEqual(@as(u8, 0x0A), bytes[1]);

    var br = BitReader.init(bytes[2..]);
    const size = headers.SizeHeader.readFromBitStream(&br);
    try testing.expectEqual(@as(usize, 3), size.xsize());
    try testing.expectEqual(@as(usize, 2), size.ysize());
    const metadata = try image_metadata.ImageMetadata.readFromBitStream(&br);
    const transform_data = try image_metadata.CustomTransformData.readFromBitStream(&br, metadata.xyb_encoded);
    try br.jumpToByteBoundary();

    var parsed_meta = image_metadata.CodecMetadata{};
    parsed_meta.m = metadata;
    parsed_meta.size = size;
    parsed_meta.transform_data = transform_data;

    const frame_offset = br.totalBitsConsumed() / 8;
    try testing.expectEqualSlices(u8, frame_writer.bytes(), bytes[2 + frame_offset ..]);
    var frame_dec = dec_frame.FrameDecoder.init(allocator, &parsed_meta);
    defer frame_dec.deinit();
    try frame_dec.decodeFrame(bytes[2 + frame_offset ..]);

    const image = frame_dec.getDecodedImage();
    try testing.expectEqual(@as(usize, 3), image.channels.items.len);
    try testing.expectEqual(@as(usize, 3), image.w);
    try testing.expectEqual(@as(usize, 2), image.h);

	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeCodestream round-trips a multi-group RGB codestream through header parse and FrameDecoder" {
	const allocator = testing.allocator;
	const source_data = @embedFile("../testdata/lossless_600x300_multigroup_rgb.jxl");
	const prepared = try prepareFrame(source_data);

	const frame_header = blk: {
		var br = BitReader.init(prepared.frame_data);
		break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &prepared.codec_meta, false);
	};
	const frame_dim = frame_header.toFrameDimensions(&prepared.codec_meta, false);
	const num_sections = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, frame_header.passes.num_passes);

	var source = try modular_image.Image.create(allocator, prepared.codec_meta.xsize(), prepared.codec_meta.ysize(), 8, 3);
	defer source.deinit();
	var hist_cache = enc_encoding.FlatHistogramInfoCache.init(allocator);
	defer hist_cache.deinit();
	for (0..source.h) |y| {
		for (0..source.w) |x| {
			const pixel = expectedRgbFixturePixel(x, y);
			source.channels.items[0].row(y)[x] = pixel[0];
			source.channels.items[1].row(y)[x] = pixel[1];
			source.channels.items[2].row(y)[x] = pixel[2];
		}
	}

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

	const ac_global_index = 1 + frame_dim.num_dc_groups;
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

	const section_payloads = try allocator.alloc([]const u8, num_sections);
	defer allocator.free(section_payloads);
	for (section_writers, 0..) |*section_writer, i| {
		section_payloads[i] = section_writer.bytes();
	}

	var frame_writer = BitWriter.init(allocator);
	defer frame_writer.deinit();
	try enc_frame.writeFrame(&frame_header, &prepared.codec_meta, section_payloads, &frame_writer);
	try frame_writer.zeroPadToByte();

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try writeCodestream(&prepared.codec_meta, frame_writer.bytes(), &codestream);
	try codestream.zeroPadToByte();

	var br = BitReader.init(codestream.bytes()[2..]);
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
	try frame_dec.decodeFrame(codestream.bytes()[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 3), image.channels.items.len);
	try testing.expectEqual(@as(usize, source.w), image.w);
	try testing.expectEqual(@as(usize, source.h), image.h);
	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeCodestream round-trips a multi-group RGB codestream with an encoded global tree" {
	const allocator = testing.allocator;
	const source_data = @embedFile("../testdata/lossless_600x300_multigroup_rgb.jxl");
	const prepared = try prepareFrame(source_data);

	const frame_header = blk: {
		var br = BitReader.init(prepared.frame_data);
		break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &prepared.codec_meta, false);
	};
	const frame_dim = frame_header.toFrameDimensions(&prepared.codec_meta, false);
	const num_sections = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, frame_header.passes.num_passes);

	var source = try modular_image.Image.create(allocator, prepared.codec_meta.xsize(), prepared.codec_meta.ysize(), 8, 3);
	defer source.deinit();
	for (0..source.h) |y| {
		for (0..source.w) |x| {
			const pixel = expectedRgbFixturePixel(x, y);
			source.channels.items[0].row(y)[x] = pixel[0];
			source.channels.items[1].row(y)[x] = pixel[1];
			source.channels.items[2].row(y)[x] = pixel[2];
		}
	}

	var global_tree = try enc_encoding.predefinedTree(allocator, .gradient_fixed_dc, source.w * source.h, 8, 0);
	defer global_tree.deinit(allocator);
	const uint_config = HybridUintConfig.initDefault();
	const log_alpha_size: u5 = 8;
	const counts = try ans_common.createFlatHistogram(allocator, 256, ans_params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts, log_alpha_size);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);

	const section_writers = try allocator.alloc(BitWriter, num_sections);
	defer allocator.free(section_writers);
	for (section_writers) |*section_writer| {
		section_writer.* = BitWriter.init(allocator);
	}
	defer for (section_writers) |*section_writer| {
		section_writer.deinit();
	};

	try section_writers[0].write(1, 1); // DequantMatrices all_default
	try enc_encoding.writeGlobalTreeDcSection(
		allocator,
		global_tree.items,
		256,
		uint_config,
		log_alpha_size,
		&section_writers[0],
	);
	try section_writers[0].zeroPadToByte();

	const ac_global_index = 1 + frame_dim.num_dc_groups;
	for (ac_global_index + 1..num_sections) |section_id| {
		const group_id = (section_id - ac_global_index - 1) % frame_dim.num_groups;
		_ = try enc_encoding.writeSingleNodeGlobalTreeGroupImageRect(
			allocator,
			&source,
			frame_dim.groupRect(group_id),
			.gradient,
			0,
			info,
			uint_config,
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
	try enc_frame.writeFrame(&frame_header, &prepared.codec_meta, section_payloads, &frame_writer);
	try frame_writer.zeroPadToByte();

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try writeCodestream(&prepared.codec_meta, frame_writer.bytes(), &codestream);
	try codestream.zeroPadToByte();

	var br = BitReader.init(codestream.bytes()[2..]);
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
	try frame_dec.decodeFrame(codestream.bytes()[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	try testing.expectEqual(@as(usize, 3), image.channels.items.len);
	try testing.expectEqual(@as(usize, source.w), image.w);
	try testing.expectEqual(@as(usize, source.h), image.h);
	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}

test "writeCodestream round-trips a multi-group RGB codestream with split global histogram contexts" {
	const allocator = testing.allocator;
	const source_data = @embedFile("../testdata/lossless_600x300_multigroup_rgb.jxl");
	const prepared = try prepareFrame(source_data);

	const frame_header = blk: {
		var br = BitReader.init(prepared.frame_data);
		break :blk try frame_header_mod.FrameHeader.readFromBitStream(&br, &prepared.codec_meta, false);
	};
	const frame_dim = frame_header.toFrameDimensions(&prepared.codec_meta, false);
	const num_sections = toc.numTocEntries(frame_dim.num_groups, frame_dim.num_dc_groups, frame_header.passes.num_passes);

	var source = try modular_image.Image.create(allocator, prepared.codec_meta.xsize(), prepared.codec_meta.ysize(), 8, 3);
	defer source.deinit();
	for (0..source.h) |y| {
		for (0..source.w) |x| {
			const pixel = expectedRgbFixturePixel(x, y);
			source.channels.items[0].row(y)[x] = pixel[0];
			source.channels.items[1].row(y)[x] = pixel[1];
			source.channels.items[2].row(y)[x] = pixel[2];
		}
	}

	const global_tree = [_]@import("../modular/dec_ma.zig").PropertyDecisionNode{
		@import("../modular/dec_ma.zig").PropertyDecisionNode.split(0, 0, 1, 2),
		@import("../modular/dec_ma.zig").PropertyDecisionNode.leaf(.gradient, 0, 1),
		@import("../modular/dec_ma.zig").PropertyDecisionNode.leaf(.gradient, 0, 1),
	};
	const channel_contexts = [_]u32{ 1, 0, 0 };
	const context_map = [_]u8{ 0, 1 };
	const uint_configs = [_]HybridUintConfig{
		HybridUintConfig.initDefault(),
		HybridUintConfig.init(5, 0, 0),
	};
	const alphabet_sizes = [_]u16{
		256,
		256,
	};
	const counts0 = try ans_common.createFlatHistogram(allocator, alphabet_sizes[0], ans_params.ans_tab_size);
	defer allocator.free(counts0);
	const counts1 = try ans_common.createFlatHistogram(allocator, alphabet_sizes[1], ans_params.ans_tab_size);
	defer allocator.free(counts1);
	const info0 = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts0, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info0);
	const info1 = try enc_ans.buildANSEncSymbolInfoTable(allocator, counts1, 8);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info1);
	const infos = [_][]const enc_ans.ANSEncSymbolInfo{ info0, info1 };

	const section_writers = try allocator.alloc(BitWriter, num_sections);
	defer allocator.free(section_writers);
	for (section_writers) |*section_writer| {
		section_writer.* = BitWriter.init(allocator);
	}
	defer for (section_writers) |*section_writer| {
		section_writer.deinit();
	};

	try section_writers[0].write(1, 1); // DequantMatrices all_default
	try enc_encoding.writeGlobalTreeDcSectionWithFlatHistograms(
		allocator,
		&global_tree,
		&context_map,
		2,
		&alphabet_sizes,
		&uint_configs,
		8,
		&section_writers[0],
	);
	try section_writers[0].zeroPadToByte();

	const ac_global_index = 1 + frame_dim.num_dc_groups;
	for (ac_global_index + 1..num_sections) |section_id| {
		const group_id = (section_id - ac_global_index - 1) % frame_dim.num_groups;
		_ = try enc_encoding.writeSingleNodeGlobalTreeGroupImageRectContexts(
			allocator,
			&source,
			frame_dim.groupRect(group_id),
			.gradient,
			&channel_contexts,
			&infos,
			&context_map,
			&uint_configs,
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
	try enc_frame.writeFrame(&frame_header, &prepared.codec_meta, section_payloads, &frame_writer);
	try frame_writer.zeroPadToByte();

	var codestream = BitWriter.init(allocator);
	defer codestream.deinit();
	try writeCodestream(&prepared.codec_meta, frame_writer.bytes(), &codestream);
	try codestream.zeroPadToByte();

	var br = BitReader.init(codestream.bytes()[2..]);
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
	try frame_dec.decodeFrame(codestream.bytes()[2 + frame_offset ..]);

	const image = frame_dec.getDecodedImage();
	for (source.channels.items, image.channels.items) |want, got| {
		try testing.expectEqualSlices(i32, want.data, got.data);
	}
}
