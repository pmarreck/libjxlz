//! VarDCT transform coverage and adaptive quantization from modular AC metadata.

const std = @import("std");
const JxlError = @import("../base/status.zig").JxlError;
const Quantizer = @import("quantizer.zig").Quantizer;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const bits = @import("../base/bits.zig");
const modular_image = @import("../modular/modular_image.zig");
const encoding = @import("../modular/encoding.zig");
const ModularOptions = @import("../modular/options.zig").ModularOptions;
const dec_ma = @import("../modular/dec_ma.zig");
const ANSCode = @import("../entropy/dec_ans.zig").ANSCode;

pub const GlobalEntropy = struct {
	tree: ?[]const dec_ma.PropertyDecisionNode = null,
	code: ?*const ANSCode = null,
	context_map: ?[]const u8 = null,
};

pub const AcMetadata = struct {
	block_map: BlockMap,
	ytox: []i8,
	ytob: []i8,

	pub fn deinit(self: *AcMetadata) void {
		const allocator = self.block_map.allocator;
		allocator.free(self.ytox);
		allocator.free(self.ytob);
		self.block_map.deinit();
		self.ytox = &.{};
		self.ytob = &.{};
	}

	/// Decode a DC group's four modular AC-metadata channels: two subsampled
	/// CfL maps, paired strategy/quant samples, and blockwise EPF sharpness.
	pub fn decode(allocator: std.mem.Allocator, br: *BitReader, width: usize,
		height: usize, is444: bool, bitdepth: i32, stream_id: usize,
		global: GlobalEntropy) JxlError!AcMetadata
	{
		if (width == 0 or height == 0 or width > 256 or height > 256)
			return error.GenericError;
		const count: usize = @intCast(br.readBits(bits.ceilLog2Nonzero(width * height)) + 1);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		const cw = (width + 7) / 8;
		const ch = (height + 7) / 8;
		var image = try modular_image.Image.create(allocator, width, height, bitdepth, 0);
		defer image.deinit();
		try image.channels.ensureTotalCapacity(allocator, 4);
		image.channels.appendAssumeCapacity(try modular_image.Channel.create(allocator, cw, ch, 3, 3));
		image.channels.appendAssumeCapacity(try modular_image.Channel.create(allocator, cw, ch, 3, 3));
		image.channels.appendAssumeCapacity(try modular_image.Channel.create(allocator, count, 2, 0, 0));
		image.channels.appendAssumeCapacity(try modular_image.Channel.create(allocator, width, height, 0, 0));
		const options = ModularOptions{};
		encoding.modularGenericDecompress(br, &image, stream_id, &options, true,
			global.tree, global.code, global.context_map, allocator) catch |err| {
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
			return err;
		};
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (image.channels.items.len != 4) return error.GenericError;
		const channels = image.channels.items;
		if (channels[0].w != cw or channels[0].h != ch or
			channels[1].w != cw or channels[1].h != ch or
			channels[2].w != count or channels[2].h != 2 or
			channels[3].w != width or channels[3].h != height or
			channels[3].row_stride != width) return error.GenericError;
		var map = try BlockMap.decode(allocator, width, height, is444,
			channels[2].rowConst(0), channels[2].rowConst(1), channels[3].data);
		errdefer map.deinit();
		const ytox = try allocator.alloc(i8, cw * ch);
		errdefer allocator.free(ytox);
		const ytob = try allocator.alloc(i8, cw * ch);
		for (0..ch) |y| {
			for (0..cw) |x| {
				ytox[y * cw + x] = @intCast(std.math.clamp(channels[0].rowConst(y)[x], -128, 127));
				ytob[y * cw + x] = @intCast(std.math.clamp(channels[1].rowConst(y)[x], -128, 127));
			}
		}
		return .{ .block_map = map, .ytox = ytox, .ytob = ytob };
	}
};

pub const strategyExtent = @import("ac_strategy.zig").strategyExtent;

pub const Block = struct {
	strategy: u8 = 255,
	is_first: bool = false,
	// AC quant is defined at the transform's top-left block only.
	quant: u16 = 0,
	sharpness: u8 = 0,
};

pub const BlockMap = struct {
	blocks: []Block,
	width: usize,
	height: usize,
	used_acs: u32,
	allocator: std.mem.Allocator,

	pub fn deinit(self: *BlockMap) void {
		self.allocator.free(self.blocks);
		self.blocks = &.{};
	}

	/// Expand the paired strategy/quant rows from DecodeAcMetadata into a DC
	/// group's block map. Check overlap, AC-group boundaries and every EPF sample.
	/// Complexity: O(width * height), with each covered block visited once.
	pub fn decode(allocator: std.mem.Allocator, width: usize, height: usize,
		is444: bool, strategies: []const i32, quants: []const i32,
		sharpness: []const i32) JxlError!BlockMap
	{
		const dc_group_blocks = 256;
		const ac_group_blocks = 32;
		if (width == 0 or height == 0 or width > dc_group_blocks or height > dc_group_blocks)
			return error.GenericError;
		if (strategies.len != quants.len or sharpness.len != width * height)
			return error.GenericError;
		const blocks = try allocator.alloc(Block, width * height);
		errdefer allocator.free(blocks);
		@memset(blocks, .{});
		var num: usize = 0;
		var used_acs: u32 = 0;
		for (blocks, sharpness, 0..) |*block, sharp, index| {
			if (sharp < 0 or sharp >= 8) return error.GenericError;
			block.sharpness = @intCast(sharp);
			if (block.strategy != 255) continue;
			if (num >= strategies.len) return error.GenericError;
			const raw = strategies[num];
			const extent = try strategyExtent(raw);
			if (!is444 and (extent.x > 1 or extent.y > 1)) return error.GenericError;
			const x = index % width;
			const y = index / width;
			if (extent.x > width - x or extent.y > height - y or
				extent.x > ac_group_blocks - x % ac_group_blocks or
				extent.y > ac_group_blocks - y % ac_group_blocks) return error.GenericError;
			for (0..extent.y) |dy| {
				for (0..extent.x) |dx| {
					const covered = &blocks[(y + dy) * width + x + dx];
					if (covered.strategy != 255) return error.GenericError;
					covered.strategy = @intCast(raw);
				}
			}
			block.is_first = true;
			block.quant = @intCast(1 + std.math.clamp(quants[num], 0, Quantizer.kQuantMax - 1));
			used_acs |= @as(u32, 1) << @intCast(raw);
			num += 1;
		}
		return .{ .blocks = blocks, .width = width, .height = height,
			.used_acs = used_acs, .allocator = allocator };
	}
};

const testing = std.testing;

test "AC metadata expands transform coverage and clamps adaptive quant samples" {
	// 16x16 in the left 2x2 cells, then two 8x8 transforms at the right.
	var map = try BlockMap.decode(testing.allocator, 3, 2, true,
		&.{ 4, 0, 0 }, &.{ -1, 17, 256 }, &.{ 0, 1, 2, 3, 4, 7 });
	defer map.deinit();
	try testing.expectEqual(@as(u32, 17), map.used_acs);
	try testing.expectEqual(@as(u8, 4), map.blocks[0].strategy);
	try testing.expect(map.blocks[0].is_first);
	try testing.expect(!map.blocks[1].is_first);
	try testing.expect(!map.blocks[3].is_first);
	try testing.expect(!map.blocks[4].is_first);
	try testing.expectEqual(@as(u16, 1), map.blocks[0].quant);
	try testing.expectEqual(@as(u16, 18), map.blocks[2].quant);
	try testing.expectEqual(@as(u16, 256), map.blocks[5].quant);
	try testing.expectEqual(@as(u8, 7), map.blocks[5].sharpness);
}

test "AC metadata rejects invalid strategy tilings and sharpness" {
	const a = testing.allocator;
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{-1}, &.{0}, &.{0}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{27}, &.{0}, &.{0}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{4}, &.{0}, &.{0}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 2, 2, false, &.{4}, &.{0}, &.{ 0, 0, 0, 0 }));
	// First transform covers (0,0) and (0,1); the second starts at (1,0)
	// and attempts to extend below the two-row image.
	try testing.expectError(error.GenericError, BlockMap.decode(a, 2, 2, true, &.{ 6, 8 }, &.{ 0, 0 }, &.{ 0, 0, 0, 0 }));
	// The lower 2x2 overlaps the upper-right 2x2 at (1,1).
	try testing.expectError(error.GenericError, BlockMap.decode(a, 3, 3, true,
		&.{ 0, 4, 4 }, &.{ 0, 0, 0 }, &([_]i32{0} ** 9)));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 2, 1, true, &.{0}, &.{0}, &.{ 0, 0 }));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{0}, &.{}, &.{0}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{0}, &.{0}, &.{-1}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 1, 1, true, &.{0}, &.{0}, &.{8}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 0, 1, true, &.{}, &.{}, &.{}));
	try testing.expectError(error.GenericError, BlockMap.decode(a, 257, 1, true, &.{0}, &.{0}, &.{0}));
}

test "AC metadata rejects transforms crossing an AC group boundary" {
	var strategies = [_]i32{0} ** 32;
	strategies[31] = 7; // 8x16, two blocks wide, starts at x=31.
	try testing.expectError(error.GenericError, BlockMap.decode(testing.allocator,
		33, 1, true, &strategies, &([_]i32{0} ** 32), &([_]i32{0} ** 33)));
}

test "AC metadata covers all 27 strategies including DCT256 without dequant work" {
	// Explicit dimensions from lib/jxl/ac_strategy.h, independent of Zig's LUT.
	const widths = [_]usize{ 1, 1, 1, 1, 2, 4, 1, 2, 1, 4, 2, 4, 1, 1, 1, 1, 1, 1, 8, 4, 8, 16, 8, 16, 32, 16, 32 };
	const heights = [_]usize{ 1, 1, 1, 1, 2, 4, 2, 1, 4, 1, 4, 2, 1, 1, 1, 1, 1, 1, 8, 8, 4, 16, 16, 8, 32, 32, 16 };
	for (widths, heights, 0..) |w, h, raw| {
		const sharpness = try testing.allocator.alloc(i32, w * h);
		defer testing.allocator.free(sharpness);
		@memset(sharpness, 0);
		var map = try BlockMap.decode(testing.allocator, w, h, true, &.{@intCast(raw)}, &.{255}, sharpness);
		defer map.deinit();
		try testing.expectEqual(@as(u32, 1) << @intCast(raw), map.used_acs);
		try testing.expectEqual(@as(u16, 256), map.blocks[0].quant);
		try testing.expect(map.blocks[0].is_first);
		for (map.blocks[1..]) |block| {
			try testing.expectEqual(@as(u8, @intCast(raw)), block.strategy);
			try testing.expect(!block.is_first);
		}
	}
}

fn metadataStream(allocator: std.mem.Allocator) ![]u8 {
	const Image = @import("../modular/modular_image.zig").Image;
	const Channel = @import("../modular/modular_image.zig").Channel;
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const enc = @import("../modular/enc_encoding.zig");
	var image = try Image.create(allocator, 3, 2, 8, 4);
	defer image.deinit();
	for (0..2) |c| {
		image.channels.items[c].deinit();
		image.channels.items[c] = try Channel.create(allocator, 1, 1, 3, 3);
	}
	image.channels.items[0].data[0] = -200;
	image.channels.items[1].data[0] = 200;
	@memcpy(image.channels.items[2].row(0), &[_]i32{ 4, 0, 0 });
	@memcpy(image.channels.items[2].row(1), &[_]i32{ -1, 17, 256 });
	@memcpy(image.channels.items[3].data, &[_]i32{ 0, 1, 2, 3, 4, 7 });
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(3, 2); // ceil(log2(3*2)) bits, count minus one.
	_ = try enc.writeSingleNodeLocalTreeGroupImage(allocator, &image, .zero, &writer);
	try writer.zeroPadToByte();
	return allocator.dupe(u8, writer.bytes());
}

test "AC metadata decodes its modular stream and clamps color correlation maps" {
	const a = testing.allocator;
	const data = try metadataStream(a);
	defer a.free(data);
	var br = BitReader.init(data);
	var metadata = try AcMetadata.decode(a, &br, 3, 2, true, 8, 1, .{});
	defer metadata.deinit();
	try br.close();
	try testing.expectEqual(@as(i8, -128), metadata.ytox[0]);
	try testing.expectEqual(@as(i8, 127), metadata.ytob[0]);
	try testing.expectEqual(@as(u16, 18), metadata.block_map.blocks[2].quant);
	try testing.expectEqual(@as(u16, 256), metadata.block_map.blocks[5].quant);
}

test "AC metadata reports truncated modular input without leaking" {
	const a = testing.allocator;
	const data = try metadataStream(a);
	defer a.free(data);
	for (0..data.len) |len| {
		var br = BitReader.init(data[0..len]);
		try testing.expectError(error.NotEnoughBytes, AcMetadata.decode(a, &br, 3, 2, true, 8, 1, .{}));
	}
}

fn decodeMetadataWithAllocator(allocator: std.mem.Allocator, data: []const u8) !void {
	var br = BitReader.init(data);
	var metadata = try AcMetadata.decode(allocator, &br, 3, 2, true, 8, 1, .{});
	defer metadata.deinit();
}

test "AC metadata releases every partial allocation on failure" {
	const data = try metadataStream(testing.allocator);
	defer testing.allocator.free(data);
	try testing.checkAllAllocationFailures(testing.allocator, decodeMetadataWithAllocator, .{data});
}

test "AC metadata frame adapter derives partial edge block geometry" {
	const frame = @import("dec_frame.zig");
	const FrameDimensions = @import("frame_dimensions.zig").FrameDimensions;
	const FrameHeader = @import("frame_header.zig").FrameHeader;
	var dimensions = FrameDimensions{};
	dimensions.set(17, 9, 1, 0, 0, false, 1);
	var decoder = frame.ModularFrameDecoder.init(testing.allocator);
	defer decoder.deinit();
	decoder.initFrame(dimensions);
	decoder.full_image.bitdepth = 8;
	var header = FrameHeader{};
	header.encoding = .var_dct;
	const data = try metadataStream(testing.allocator);
	defer testing.allocator.free(data);
	var br = BitReader.init(data);
	var metadata = try decoder.decodeAcMetadata(&br, 0, &header);
	defer metadata.deinit();
	try testing.expectEqual(@as(usize, 3), metadata.block_map.width);
	try testing.expectEqual(@as(usize, 2), metadata.block_map.height);
	try testing.expectEqual(@as(u16, 18), metadata.block_map.blocks[2].quant);
	try testing.expectError(error.GenericError, decoder.decodeAcMetadata(&br, 1, &header));
}
