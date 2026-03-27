// Encoder-side context-map helpers.
// Starts with the smallest multi-context slice: simple all-zero maps.

const std = @import("std");
const bits = @import("../base/bits.zig");
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const HybridUintConfig = @import("hybrid_uint.zig").HybridUintConfig;
const enc_ans = @import("enc_ans.zig");
const dec_context_map = @import("dec_context_map.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;

pub const EncodingKind = enum {
	simple,
	ans,
	mtf,
};

fn moveToFront(v: []u8, index: usize) void {
	const value = v[index];
	var i = index;
	while (i > 0) : (i -= 1) {
		v[i] = v[i - 1];
	}
	v[0] = value;
}

/// Applies the encoder-side move-to-front transform used by libjxl's
/// context-map writer so repetitive histogram-id runs can collapse to zeros.
fn moveToFrontTransform(allocator: std.mem.Allocator, context_map: []const u8) ![]u8 {
	if (context_map.len == 0) return allocator.dupe(u8, context_map);

	const max_value = std.mem.max(u8, context_map);
	const mtf = try allocator.alloc(u8, @as(usize, max_value) + 1);
	defer allocator.free(mtf);
	for (mtf, 0..) |*entry, i| {
		entry.* = @intCast(i);
	}

	const result = try allocator.alloc(u8, context_map.len);
	for (context_map, 0..) |value, i| {
		const index = std.mem.indexOfScalar(u8, mtf, value) orelse unreachable;
		result[i] = @intCast(index);
		if (index != 0) moveToFront(mtf, index);
	}
	return result;
}

fn contextMapUintConfig() HybridUintConfig {
	return HybridUintConfig.init(2, 0, 1);
}

fn selectLogAlphaSize(symbols: []const u8, uint_config: HybridUintConfig) !u5 {
	var max_token: u32 = 0;
	for (symbols) |symbol| {
		max_token = @max(max_token, uint_config.encode(symbol).token);
	}
	const needed = bits.ceilLog2Nonzero(max_token + 1);
	const log_alpha_size: u5 = @intCast(@max(@as(u32, 5), needed));
	if (log_alpha_size > 8) return error.GenericError;
	return log_alpha_size;
}

fn writeNonSimpleContextMapSymbols(
	allocator: std.mem.Allocator,
	symbols: []const u8,
	use_mtf: bool,
	writer: *BitWriter,
) !void {
	const uint_config = contextMapUintConfig();
	const log_alpha_size = try selectLogAlphaSize(symbols, uint_config);

	var tokens: std.ArrayList(enc_ans.Token) = .{};
	defer tokens.deinit(allocator);
	try tokens.ensureTotalCapacity(allocator, symbols.len);
	for (symbols) |symbol| {
		tokens.appendAssumeCapacity(enc_ans.Token.init(0, symbol));
	}

	const logical_context_map = [_]u8{0};
	const uint_configs = [_]HybridUintConfig{uint_config};
	var bundle = try enc_ans.buildContextualHistogramBundle(
		allocator,
		tokens.items,
		&logical_context_map,
		&uint_configs,
		log_alpha_size,
	);
	defer bundle.deinit(allocator);

	try writer.write(1, 0); // is_simple = false
	try writer.write(1, @intFromBool(use_mtf));
	try enc_ans.writeSingleContextNormalizedHistogram(
		bundle.normalized_counts[0],
		bundle.uint_configs[0],
		log_alpha_size,
		writer,
	);
	_ = try enc_ans.writeSingleHistogramTokens(
		tokens.items,
		bundle.infos[0],
		bundle.uint_configs[0],
		writer,
	);
}

fn estimateNonSimpleContextMapBits(
	allocator: std.mem.Allocator,
	symbols: []const u8,
	use_mtf: bool,
) !usize {
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeNonSimpleContextMapSymbols(allocator, symbols, use_mtf, &writer);
	return writer.bitsWritten();
}

fn chooseEncodingKind(
	allocator: std.mem.Allocator,
	context_map: []const u8,
	num_histograms: usize,
) !EncodingKind {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	if (num_histograms == 1) return .simple;

	const entry_bits = bits.ceilLog2Nonzero(num_histograms);
	const simple_cost = if (entry_bits < 4)
		@as(usize, 3) + entry_bits * context_map.len
	else
		std.math.maxInt(usize);

	const ans_cost = try estimateNonSimpleContextMapBits(allocator, context_map, false);
	const mtf_symbols = try moveToFrontTransform(allocator, context_map);
	defer allocator.free(mtf_symbols);
	const mtf_cost = try estimateNonSimpleContextMapBits(allocator, mtf_symbols, true);

	if (simple_cost <= ans_cost and simple_cost <= mtf_cost) return .simple;
	if (mtf_cost < ans_cost) return .mtf;
	return .ans;
}

/// Chooses between direct simple entries, raw ANS coding, and MTF+ANS coding,
/// mirroring libjxl's context-map writer on the currently-supported ANS-only path.
pub fn writeContextMap(
	allocator: std.mem.Allocator,
	context_map: []const u8,
	num_histograms: usize,
	writer: *BitWriter,
) !void {
	switch (try chooseEncodingKind(allocator, context_map, num_histograms)) {
		.simple => try writeSimpleContextMap(context_map, num_histograms, writer),
		.ans => try writeNonSimpleContextMapSymbols(allocator, context_map, false, writer),
		.mtf => {
			const mtf_symbols = try moveToFrontTransform(allocator, context_map);
			defer allocator.free(mtf_symbols);
			try writeNonSimpleContextMapSymbols(allocator, mtf_symbols, true, writer);
		},
	}
}

/// Emits the simple all-zero context-map form, which assigns every context to
/// histogram 0 without invoking the recursive histogram-coded path.
pub fn writeSimpleAllZeroContextMap(num_contexts: usize, writer: *BitWriter) !void {
	std.debug.assert(num_contexts > 0);
	try writer.write(1, 1); // is_simple = true
	try writer.write(2, 0); // bits_per_entry = 0 => all histogram ids are zero
}

/// Emits the direct-entry simple context-map form for small histogram counts,
/// avoiding the heavier ANS/MTF path while still allowing multiple histograms.
pub fn writeSimpleContextMap(context_map: []const u8, num_histograms: usize, writer: *BitWriter) !void {
	std.debug.assert(context_map.len > 0);
	std.debug.assert(num_histograms > 0);
	if (num_histograms == 1) return writeSimpleAllZeroContextMap(context_map.len, writer);

	const bits_per_entry = bits.ceilLog2Nonzero(num_histograms);
	std.debug.assert(bits_per_entry > 0 and bits_per_entry < 4);

	try writer.write(1, 1); // is_simple = true
	try writer.write(2, bits_per_entry);
	for (context_map) |entry| {
		std.debug.assert(entry < num_histograms);
		try writer.write(bits_per_entry, entry);
	}
}

const testing = std.testing;

test "writeSimpleAllZeroContextMap round-trips through decodeContextMap" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleAllZeroContextMap(6, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	var num_htrees: usize = 0;
	try dec_context_map.decodeContextMap(&map, &num_htrees, &br);
	try testing.expectEqual(@as(usize, 1), num_htrees);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, &map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeSimpleContextMap round-trips explicit histogram ids" {
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSimpleContextMap(&[_]u8{ 0, 1, 0, 1, 1, 0 }, 2, &writer);
	try writer.zeroPadToByte();

	var br = @import("../base/bit_reader.zig").BitReader.init(writer.bytes());
	var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	var num_htrees: usize = 0;
	try dec_context_map.decodeContextMap(&map, &num_htrees, &br);
	try testing.expectEqual(@as(usize, 2), num_htrees);
	try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 1, 1, 0 }, &map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "moveToFrontTransform round-trips with inverse transform" {
	const allocator = testing.allocator;
	const original = [_]u8{ 0, 1, 2, 3, 3, 3, 1, 1, 1, 2, 2, 0 };
	const transformed = try moveToFrontTransform(allocator, &original);
	defer allocator.free(transformed);
	@import("inverse_mtf.zig").inverseMoveToFrontTransform(transformed);
	try testing.expectEqualSlices(u8, &original, transformed);
}

test "writeContextMap chooses simple form when direct entries are cheaper" {
	const allocator = testing.allocator;
	const original = [_]u8{ 0, 1, 0, 1, 1, 0 };

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeContextMap(allocator, &original, 2, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	try testing.expect(br.readBits(1) != 0);

	var map = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	var num_htrees: usize = 0;
	br = BitReader.init(writer.bytes());
	try dec_context_map.decodeContextMapAlloc(&map, &num_htrees, &br, allocator);
	try testing.expectEqual(@as(usize, 2), num_htrees);
	try testing.expectEqualSlices(u8, &original, &map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeContextMap chooses non-simple form for repetitive larger maps" {
	const allocator = testing.allocator;
	const original = [_]u8{
		0, 1, 2, 3, 4, 5, 6, 7, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
	};

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeContextMap(allocator, &original, 9, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	try testing.expect(br.readBits(1) == 0);

	var map = [_]u8{0} ** original.len;
	var num_htrees: usize = 0;
	br = BitReader.init(writer.bytes());
	try dec_context_map.decodeContextMapAlloc(&map, &num_htrees, &br, allocator);
	try testing.expectEqual(@as(usize, 9), num_htrees);
	try testing.expectEqualSlices(u8, &original, &map);
	try br.jumpToByteBoundary();
	try br.close();
}

test "writeNonSimpleContextMapSymbols round-trips explicit MTF coding" {
	const allocator = testing.allocator;
	const original = [_]u8{
		0, 1, 2, 3, 4, 5, 6, 7, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8,
	};
	const mtf_symbols = try moveToFrontTransform(allocator, &original);
	defer allocator.free(mtf_symbols);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeNonSimpleContextMapSymbols(allocator, mtf_symbols, true, &writer);
	try writer.zeroPadToByte();

	var br = BitReader.init(writer.bytes());
	try testing.expect(br.readBits(1) == 0);
	try testing.expect(br.readBits(1) != 0);

	var map = [_]u8{0} ** original.len;
	var num_htrees: usize = 0;
	br = BitReader.init(writer.bytes());
	try dec_context_map.decodeContextMapAlloc(&map, &num_htrees, &br, allocator);
	try testing.expectEqual(@as(usize, 9), num_htrees);
	try testing.expectEqualSlices(u8, &original, &map);
	try br.jumpToByteBoundary();
	try br.close();
}
