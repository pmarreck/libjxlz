// Encoder-side ANS helpers.
// Starts with the smallest real entropy-writing slice: HybridUintConfig encoding.

const std = @import("std");
const bits_mod = @import("../base/bits.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const HybridUintConfig = @import("hybrid_uint.zig").HybridUintConfig;
const dec_ans = @import("dec_ans.zig");

pub const SizeWriter = struct {
	size: usize = 0,

	pub fn write(self: *SizeWriter, n_bits: usize, bits: anytype) !void {
		_ = bits;
		self.size += n_bits;
	}
};

pub fn encodeUintConfig(cfg: HybridUintConfig, writer: anytype, log_alpha_size: u5) !void {
	try writer.write(bits_mod.ceilLog2Nonzero(@as(u32, log_alpha_size) + 1), cfg.split_exponent);
	if (cfg.split_exponent == log_alpha_size) return;

	var nbits = bits_mod.ceilLog2Nonzero(cfg.split_exponent + 1);
	try writer.write(nbits, cfg.msb_in_token);
	nbits = bits_mod.ceilLog2Nonzero(cfg.split_exponent - cfg.msb_in_token + 1);
	try writer.write(nbits, cfg.lsb_in_token);
}

pub fn encodeUintConfigs(configs: []const HybridUintConfig, writer: anytype, log_alpha_size: u5) !void {
	for (configs) |cfg| {
		try encodeUintConfig(cfg, writer, log_alpha_size);
	}
}

/// Encodes a compact variable-length integer in the range [0..255].
/// Mirrors libjxl's histogram-header format so small counts stay very cheap to write.
pub fn storeVarLenUint8(value: u8, writer: anytype) !void {
	if (value == 0) {
		try writer.write(1, 0);
		return;
	}

	try writer.write(1, 1);
	const nbits = bits_mod.floorLog2Nonzero(value);
	try writer.write(3, nbits);
	if (nbits != 0) {
		try writer.write(nbits, value - (@as(u8, 1) << @intCast(nbits)));
	}
}

/// Encodes a compact variable-length integer in the range [0..65535].
/// This is the wider companion to `storeVarLenUint8` for histogram alphabet sizes.
pub fn storeVarLenUint16(value: u16, writer: anytype) !void {
	if (value == 0) {
		try writer.write(1, 0);
		return;
	}

	try writer.write(1, 1);
	const nbits = bits_mod.floorLog2Nonzero(value);
	try writer.write(4, nbits);
	if (nbits != 0) {
		try writer.write(nbits, value - (@as(u16, 1) << @intCast(nbits)));
	}
}

const testing = std.testing;

test "encodeUintConfigs round-trips a mixed config set" {
	const log_alpha_size: u5 = 8;
	const original = [_]HybridUintConfig{
		HybridUintConfig.init(0, 0, 0),
		HybridUintConfig.init(3, 1, 0),
		HybridUintConfig.init(4, 2, 1),
		HybridUintConfig.init(5, 1, 2),
		HybridUintConfig.init(log_alpha_size, 0, 0),
	};

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try encodeUintConfigs(&original, &writer, log_alpha_size);
	try writer.zeroPadToByte();

	var decoded: [original.len]HybridUintConfig = undefined;
	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try dec_ans.decodeUintConfigs(log_alpha_size, &decoded, &reader);
	try reader.close();

	for (original, decoded) |want, got| {
		try testing.expectEqual(want.split_exponent, got.split_exponent);
		try testing.expectEqual(want.msb_in_token, got.msb_in_token);
		try testing.expectEqual(want.lsb_in_token, got.lsb_in_token);
	}
}

test "encodeUintConfig omits msb/lsb fields at max split exponent" {
	const log_alpha_size: u5 = 6;
	const original = [_]HybridUintConfig{
		HybridUintConfig.init(log_alpha_size, 0, 0),
		HybridUintConfig.init(2, 1, 0),
	};

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try encodeUintConfigs(&original, &writer, log_alpha_size);
	try writer.zeroPadToByte();

	var decoded: [original.len]HybridUintConfig = undefined;
	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	try dec_ans.decodeUintConfigs(log_alpha_size, &decoded, &reader);
	try reader.close();

	try testing.expectEqual(original[0].split_exponent, decoded[0].split_exponent);
	try testing.expectEqual(original[1].split_exponent, decoded[1].split_exponent);
	try testing.expectEqual(original[1].msb_in_token, decoded[1].msb_in_token);
	try testing.expectEqual(original[1].lsb_in_token, decoded[1].lsb_in_token);
}

test "encodeUintConfigs exhaustively round-trips valid configs through decoder" {
	inline for (5..9) |log_alpha_size_usize| {
		const log_alpha_size: u5 = @intCast(log_alpha_size_usize);
		var original: std.ArrayList(HybridUintConfig) = .{};
		defer original.deinit(testing.allocator);

		for (0..log_alpha_size) |split_exponent_usize| {
			const split_exponent: u32 = @intCast(split_exponent_usize);
			for (0..split_exponent + 1) |msb_in_token_usize| {
				const msb_in_token: u32 = @intCast(msb_in_token_usize);
				for (0..(split_exponent - msb_in_token) + 1) |lsb_in_token_usize| {
					const lsb_in_token: u32 = @intCast(lsb_in_token_usize);
					try original.append(testing.allocator, HybridUintConfig.init(split_exponent, msb_in_token, lsb_in_token));
				}
			}
		}
		try original.append(testing.allocator, HybridUintConfig.init(log_alpha_size, 0, 0));

		var writer = BitWriter.init(testing.allocator);
		defer writer.deinit();
		try encodeUintConfigs(original.items, &writer, log_alpha_size);
		try writer.zeroPadToByte();

		const decoded = try testing.allocator.alloc(HybridUintConfig, original.items.len);
		defer testing.allocator.free(decoded);
		var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
		try dec_ans.decodeUintConfigs(log_alpha_size, decoded, &reader);
		try reader.close();

		for (original.items, decoded) |want, got| {
			try testing.expectEqual(want.split_exponent, got.split_exponent);
			try testing.expectEqual(want.msb_in_token, got.msb_in_token);
			try testing.expectEqual(want.lsb_in_token, got.lsb_in_token);
		}
	}
}

test "storeVarLenUint8 exhaustively round-trips through decoder helper" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	for (0..256) |value| {
		try storeVarLenUint8(@intCast(value), &writer);
	}
	try writer.zeroPadToByte();

	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	for (0..256) |value| {
		try testing.expectEqual(@as(u32, @intCast(value)), dec_ans.decodeVarLenUint8(&reader));
	}
	try reader.close();
}

test "storeVarLenUint16 exhaustively round-trips through decoder helper" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	for (0..65536) |value| {
		try storeVarLenUint16(@intCast(value), &writer);
	}
	try writer.zeroPadToByte();

	var reader = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	for (0..65536) |value| {
		try testing.expectEqual(@as(u32, @intCast(value)), dec_ans.decodeVarLenUint16(&reader));
	}
	try reader.close();
}

test "SizeWriter matches BitWriter bit count for varlen integers" {
	var bit_writer = BitWriter.init(testing.allocator);
	defer bit_writer.deinit();
	var size_writer = SizeWriter{};

	for (0..256) |value| {
		try storeVarLenUint8(@intCast(value), &bit_writer);
		try storeVarLenUint8(@intCast(value), &size_writer);
	}
	for (0..1024) |value| {
		try storeVarLenUint16(@intCast(value), &bit_writer);
		try storeVarLenUint16(@intCast(value), &size_writer);
	}

	try testing.expectEqual(bit_writer.bitsWritten(), size_writer.size);
}

test "SizeWriter matches BitWriter bit count for uint configs" {
	const log_alpha_size: u5 = 8;
	const configs = [_]HybridUintConfig{
		HybridUintConfig.init(0, 0, 0),
		HybridUintConfig.init(3, 1, 0),
		HybridUintConfig.init(4, 2, 1),
		HybridUintConfig.init(5, 1, 2),
		HybridUintConfig.init(log_alpha_size, 0, 0),
	};

	var bit_writer = BitWriter.init(testing.allocator);
	defer bit_writer.deinit();
	var size_writer = SizeWriter{};

	try encodeUintConfigs(&configs, &bit_writer, log_alpha_size);
	try encodeUintConfigs(&configs, &size_writer, log_alpha_size);

	try testing.expectEqual(bit_writer.bitsWritten(), size_writer.size);
}
