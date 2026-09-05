const std = @import("std");
const testing = std.testing;
const toc = @import("toc.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const ans = @import("../entropy/dec_ans.zig");
const enc = @import("../entropy/enc_ans.zig");
const common = @import("../entropy/ans_common.zig");
const params = @import("../entropy/ans_params.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;

fn encodedSymbols(allocator: std.mem.Allocator, values: []const u32) ![]u8 {
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writeSymbols(allocator, &writer, values);
	try writer.zeroPadToByte();
	return allocator.dupe(u8, writer.bytes());
}

fn writeSymbols(allocator: std.mem.Allocator, writer: *BitWriter, values: []const u32) !void {
	const cfg = HybridUintConfig.initZero();
	try enc.writeAllZeroContextMapFlatHistogram(8, 64, cfg, 6, writer);
	const counts = try common.createFlatHistogram(allocator, 64, params.ans_tab_size);
	defer allocator.free(counts);
	const info = try enc.buildANSEncSymbolInfoTable(allocator, counts, 6);
	defer enc.freeANSEncSymbolInfoTable(allocator, info);
	const tokens = try allocator.alloc(enc.Token, values.len);
	defer allocator.free(tokens);
	for (tokens, values) |*token, value| token.* = enc.Token.init(0, value);
	_ = try enc.writeSingleHistogramTokens(tokens, info, cfg, writer);
}

test "shared permutations retain one ANS state and preserve LLF prefixes" {
	const a = testing.allocator;
	// First: skip two, Lehmer [0,0,3,2,1,0]. Then identity, then a
	// discarded permutation, followed by an unrelated sentinel symbol.
	const data = try encodedSymbols(a, &.{ 3, 3, 2, 1, 0, 1, 1, 99 });
	defer a.free(data);
	var br = BitReader.init(data);
	var code = ans.ANSCode.init(a);
	defer code.deinit();
	const contexts = try ans.decodeHistograms(a, &br, 8, &code);
	defer a.free(contexts);
	var reader = try ans.ANSSymbolReader.create(&code, &br, 0, a);
	defer reader.deinit();
	var first: [6]u32 = undefined;
	try toc.readPermutation(a, 2, 6, &first, &br, &reader, contexts);
	try testing.expectEqualSlices(u32, &.{ 0, 1, 5, 4, 3, 2 }, &first);
	var second: [4]u32 = undefined;
	try toc.readPermutation(a, 0, 4, &second, &br, &reader, contexts);
	try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, &second);
	try toc.readPermutation(a, 1, 3, null, &br, &reader, contexts);
	try testing.expectEqual(@as(usize, 99), reader.readHybridUint(0, &br, contexts));
	try testing.expect(reader.checkANSFinalState());
	try br.close();
}

fn onePermutation(allocator: std.mem.Allocator, data: []const u8, skip: usize, size: usize, discard: bool) !void {
	var br = BitReader.init(data);
	var code = ans.ANSCode.init(allocator);
	defer code.deinit();
	const contexts = try ans.decodeHistograms(allocator, &br, 8, &code);
	defer allocator.free(contexts);
	var reader = try ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();
	const output = try allocator.alloc(u32, size);
	defer allocator.free(output);
	try toc.readPermutation(allocator, skip, size, if (discard) null else output, &br, &reader, contexts);
	if (!reader.checkANSFinalState()) return error.GenericError;
	try br.close();
}

test "shared permutations reject invalid sizes and discarded malformed ranks" {
	const a = testing.allocator;
	for ([_]bool{ false, true }) |discard| {
		const too_long = try encodedSymbols(a, &.{5});
		defer a.free(too_long);
		try testing.expectError(error.GenericError, onePermutation(a, too_long, 0, 4, discard));
		const bad_rank = try encodedSymbols(a, &.{ 1, 3 });
		defer a.free(bad_rank);
		try testing.expectError(error.GenericError, onePermutation(a, bad_rank, 1, 4, discard));
		const identity = try encodedSymbols(a, &.{0});
		defer a.free(identity);
		try testing.expectError(error.GenericError, onePermutation(a, identity, 5, 4, discard));
		try testing.expectError(error.GenericError, onePermutation(a, identity, 0, 0, discard));
	}
}

test "shared permutations release partial allocations" {
	const data = try encodedSymbols(testing.allocator, &.{ 3, 3, 2, 1 });
	defer testing.allocator.free(data);
	try testing.checkAllAllocationFailures(testing.allocator, onePermutation, .{ data, 2, 6, false });
}

const Orders = @import("coeff_order.zig").Orders;
const fixture = @import("coeff_order_fixture.zig");
const strategy = @import("ac_strategy.zig");
// Upstream lib/jxl/coeff_order.h, independent of the implementation's mapping.
const buckets = [_]u8{ 0, 1, 1, 1, 2, 3, 4, 4, 5, 5, 6, 6, 1, 1, 1, 1, 1, 1, 7, 8, 8, 9, 10, 10, 11, 12, 12 };

fn orderHash(order: []const u32) u64 {
	var hash: u64 = 14695981039346656037;
	for (order) |index| hash = (hash ^ index) *% 1099511628211;
	return hash;
}

test "coefficient orders default to natural orders without reading entropy" {
	var br = BitReader.init(&.{});
	var orders = try Orders.decode(testing.allocator, 0, (1 << 27) - 1, &br);
	defer orders.deinit();
	for (0..27) |raw| {
		const extent = try strategy.strategyExtent(@intCast(raw));
		const natural = try testing.allocator.alloc(u32, 64 * extent.x * extent.y);
		defer testing.allocator.free(natural);
		try strategy.naturalOrder(@intCast(raw), natural);
		for (0..3) |c| try testing.expectEqualSlices(u32, natural, try orders.get(@intCast(raw), c));
	}
	try testing.expectEqual(@as(usize, 0), br.totalBitsConsumed());
	try br.close();
}

test "coefficient orders match upstream encoded fixture for all classes and channels" {
	var br = BitReader.init(&fixture.bytes);
	var orders = try Orders.decode(testing.allocator, 0x1fff, (1 << 27) - 1, &br);
	defer orders.deinit();
	for (buckets, 0..) |bucket, raw| {
		for (0..3) |c| try testing.expectEqual(fixture.hashes[bucket][c], orderHash(try orders.get(@intCast(raw), c)));
	}
	try testing.expectEqual(fixture.encoded_bits, br.totalBitsConsumed());
	try br.close();
}

test "coefficient orders validate discarded classes and share transposed strategy classes" {
	for (0..28) |selected| {
		const used: u32 = if (selected == 27) 0 else @as(u32, 1) << @intCast(selected);
		var br = BitReader.init(&fixture.bytes);
		var orders = try Orders.decode(testing.allocator, 0x1fff, used, &br);
		defer orders.deinit();
		for (buckets, 0..) |bucket, raw| {
			if (selected < 27 and bucket == buckets[selected]) {
				try testing.expectEqual(fixture.hashes[bucket][0], orderHash(try orders.get(@intCast(raw), 0)));
			} else try testing.expectError(error.GenericError, orders.get(@intCast(raw), 0));
		}
		try testing.expectEqual(fixture.encoded_bits, br.totalBitsConsumed());
		try br.close();
	}
}

test "coefficient orders reject every truncated upstream fixture prefix" {
	for (0..fixture.bytes.len) |len| {
		var br = BitReader.init(fixture.bytes[0..len]);
		try testing.expectError(error.NotEnoughBytes, Orders.decode(testing.allocator, 0x1fff, 1, &br));
	}
}

fn allocateOrders(allocator: std.mem.Allocator) !void {
	var br = BitReader.init(&fixture.bytes);
	var orders = try Orders.decode(allocator, 0x1fff, (1 << 27) - 1, &br);
	defer orders.deinit();
}

test "coefficient orders release all partial allocations" {
	try testing.checkAllAllocationFailures(testing.allocator, allocateOrders, .{});
}

test "coefficient orders reject invalid masks and lookup bounds" {
	var br = BitReader.init(&.{});
	try testing.expectError(error.GenericError, Orders.decode(testing.allocator, 0x2000, 0, &br));
	try testing.expectError(error.GenericError, Orders.decode(testing.allocator, 0, 1 << 27, &br));
	var orders = try Orders.decode(testing.allocator, 0, 1, &br);
	defer orders.deinit();
	try testing.expectError(error.GenericError, orders.get(27, 0));
	try testing.expectError(error.GenericError, orders.get(0, 3));
}

test "coefficient orders mix custom and default classes and reject trailing symbols" {
	const data = try encodedSymbols(testing.allocator, &.{ 0, 0, 0 });
	defer testing.allocator.free(data);
	var br = BitReader.init(data);
	var orders = try Orders.decode(testing.allocator, 1, 1 | (1 << 4), &br);
	defer orders.deinit();
	for ([_]u8{ 0, 4 }) |raw| {
		const actual = try orders.get(raw, 2);
		const natural = try testing.allocator.alloc(u32, actual.len);
		defer testing.allocator.free(natural);
		try strategy.naturalOrder(raw, natural);
		try testing.expectEqualSlices(u32, natural, actual);
	}
	const extra = try encodedSymbols(testing.allocator, &.{ 0, 0, 0, 99 });
	defer testing.allocator.free(extra);
	var bad = BitReader.init(extra);
	try testing.expectError(error.GenericError, Orders.decode(testing.allocator, 1, 1, &bad));
}

test "standalone permutation integration preserves TOC physical sizes and logical IDs" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try writer.write(1, 1);
	try writeSymbols(testing.allocator, &writer, &.{ 1, 2 }); // logical-to-physical [2,0,1]
	try writer.zeroPadToByte();
	for ([_]u32{ 10, 20, 30 }) |size| {
		try writer.write(2, 0);
		try writer.write(10, size);
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	const entries = try toc.readToc(testing.allocator, 3, &br);
	defer testing.allocator.free(entries);
	try testing.expectEqualDeep([_]toc.TocEntry{
		.{ .size = 10, .id = 1 }, .{ .size = 20, .id = 2 }, .{ .size = 30, .id = 0 },
	}, entries[0..3].*);
	try br.close();
}
