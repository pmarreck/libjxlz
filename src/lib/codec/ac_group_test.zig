const std = @import("std");
const testing = std.testing;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const ans = @import("../entropy/dec_ans.zig");
const ac = @import("ac_group.zig");
const meta = @import("ac_metadata.zig");
const order = @import("coeff_order.zig");
const global = @import("vardct_global.zig");
const Chroma = @import("frame_header.zig").YCbCrChromaSubsampling;
const fixture = @import("ac_group_fixture.zig");

const Reader = struct {
	br: *BitReader,
	symbols: *ans.ANSSymbolReader,
	contexts: []const u8,
	hash: u64 = 14695981039346656037,
	count: usize = 0,
	pub fn read(self: *Reader, context: usize) !u32 {
		if (context >= self.contexts.len) return error.GenericError;
		const value = self.symbols.readHybridUint(context, self.br, self.contexts);
		if (!self.br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (value > std.math.maxInt(u32)) return error.GenericError;
		self.hash = ((self.hash ^ context) *% 1099511628211 ^ value) *% 1099511628211;
		self.count += 1;
		return @intCast(value);
	}
};

fn checkCaseBytes(allocator: std.mem.Allocator, id: usize, bytes: []const u8) !void {
	const f = fixture.cases[id];
	var global_br = BitReader.init(if (f.custom) &@import("vardct_global_fixture.zig").block_context else &.{1});
	var model = try global.BlockContextMap.decode(allocator, &global_br);
	defer model.deinit();
	const strategies = try allocator.alloc(i32, f.width * f.height);
	defer allocator.free(strategies);
	@memset(strategies, 0);
	strategies[0] = if (id < 27) @intCast(id) else if (id == 27) 4 else 0;
	const zeros = try allocator.alloc(i32, strategies.len);
	defer allocator.free(zeros);
	@memset(zeros, 0);
	var map = try meta.BlockMap.decode(allocator, f.width, f.height, id != 28, strategies, zeros, zeros);
	defer map.deinit();
	const dc = try allocator.alloc(u8, strategies.len);
	defer allocator.free(dc);
	for (map.blocks, dc, 0..) |*block, *bucket, i| {
		const x = i % f.width;
		const y = i / f.width;
		block.quant = @intCast(7 + (x + y + id) % 2);
		bucket.* = if (f.custom) @intCast((x + y * 3 + id) % 12) else 0;
	}
	var empty = BitReader.init(&.{});
	var orders = try order.Orders.decode(allocator, 0, map.used_acs, &empty);
	defer orders.deinit();
	var br = BitReader.init(bytes);
	var code = ans.ANSCode.init(allocator);
	defer code.deinit();
	const contexts = try ans.decodeHistograms(allocator, &br, model.numACContexts(), &code);
	defer allocator.free(contexts);
	if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
	if (f.header_bits != br.totalBitsConsumed()) return error.GenericError;
	try testing.expectEqual(f.lz77, code.lz77.enabled);
	try testing.expectEqual(f.huffman, code.use_prefix_code);
	var symbols = try ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer symbols.deinit();
	var reader = Reader{ .br = &br, .symbols = &symbols, .contexts = contexts };
	var chroma_br = BitReader.init(&.{f.chroma});
	const chroma = Chroma.readFromBitStream(&chroma_br);
	var group = try ac.Group.create(allocator, f.width, f.height, chroma);
	defer group.deinit();
	try group.decodePass(allocator, .{ .map = &map, .dc = dc, .orders = &orders, .context = &model }, &reader);
	try testing.expectEqual(f.token_count, reader.count);
	try testing.expectEqual(f.token_hash, reader.hash);
	try testing.expectEqual(f.total_bits, br.totalBitsConsumed());
	try testing.expect(symbols.checkANSFinalState());
	var replay_br = BitReader.init(bytes);
	replay_br.skipBits(f.header_bits);
	var replay = try ac.Group.create(allocator, f.width, f.height, chroma);
	defer replay.deinit();
	try replay.decodeEntropyPass(allocator, .{ .map = &map, .dc = dc, .orders = &orders, .context = &model },
		&replay_br, &code, contexts, 1);
	for (group.planes, replay.planes) |plane, repeated| try testing.expectEqualSlices(i32, plane, repeated);
	if (id == 0) {
		const repeated_contexts = try allocator.alloc(u8, 3 * contexts.len);
		defer allocator.free(repeated_contexts);
		for (0..3) |i| @memcpy(repeated_contexts[i * contexts.len ..][0..contexts.len], contexts);
		var writer = @import("../base/bit_writer.zig").BitWriter.init(allocator);
		defer writer.deinit();
		try writer.write(2, 2);
		var source = BitReader.init(bytes);
		source.skipBits(f.header_bits);
		for (f.header_bits..f.total_bits) |_| try writer.write(1, source.readBits(1));
		try writer.zeroPadToByte();
		var selected_br = BitReader.init(writer.bytes());
		var selected = try ac.Group.create(allocator, f.width, f.height, chroma);
		defer selected.deinit();
		try selected.decodeEntropyPass(allocator, .{ .map = &map, .dc = dc, .orders = &orders, .context = &model },
			&selected_br, &code, repeated_contexts, 3);
		for (group.planes, selected.planes) |plane, other| try testing.expectEqualSlices(i32, plane, other);
		var invalid = BitReader.init(&.{3});
		try testing.expectError(error.GenericError, selected.decodeEntropyPass(allocator,
			.{ .map = &map, .dc = dc, .orders = &orders, .context = &model }, &invalid, &code, repeated_contexts, 3));
	}
	for (group.planes, f.hashes) |plane, expected| {
		var hash: u64 = 14695981039346656037;
		for (plane) |value| hash = (hash ^ @as(u32, @bitCast(value))) *% 1099511628211;
		try testing.expectEqual(expected, hash);
	}
}

fn checkCase(allocator: std.mem.Allocator, id: usize) !void {
	try checkCaseBytes(allocator, id, fixture.cases[id].bytes);
}

test "AC groups match upstream coefficients and every token context for all strategies" {
	for (0..fixture.cases.len) |id| try checkCase(testing.allocator, id);
}

test "AC groups release allocations on failures" {
	try testing.checkAllAllocationFailures(testing.allocator, checkCase, .{@as(usize, 27)});
}

test "AC groups reject every truncated entropy stream prefix" {
	for ([_]usize{ 0, 27, 28, 29, 30 }) |id| for (0..fixture.cases[id].bytes.len) |len| {
		if (checkCaseBytes(testing.allocator, id, fixture.cases[id].bytes[0..len]))
			return error.TestUnexpectedResult else |_| {}
	};
}

const Sequence = struct {
	values: []const u32,
	index: usize = 0,
	pub fn read(self: *Sequence, _: usize) !u32 {
		if (self.index == self.values.len) return error.NotEnoughBytes;
		defer self.index += 1;
		return self.values[self.index];
	}
};

test "AC groups add shifted passes in custom scan order and reject impossible counts" {
	var map = try meta.BlockMap.decode(testing.allocator, 1, 1, true, &.{0}, &.{0}, &.{0});
	defer map.deinit();
	var br = BitReader.init(&.{});
	var orders = try order.Orders.decode(testing.allocator, 0, 1, &br);
	defer orders.deinit();
	// A legal permutation puts the first coded AC sample in coefficient 63.
	for (0..3) |c| std.mem.swap(u32, &orders.classes[0][c * 64 + 1], &orders.classes[0][c * 64 + 63]);
	const model = global.BlockContextMap{ .allocator = testing.allocator };
	var group = try ac.Group.create(testing.allocator, 1, 1, .{});
	defer group.deinit();
	var p = ac.Pass{ .map = &map, .dc = &.{0}, .orders = &orders, .context = &model, .shift = 2 };
	var first = Sequence{ .values = &.{ 1, 2, 1, 1, 0 } };
	try group.decodePass(testing.allocator, p, &first);
	try testing.expectEqual(@as(i32, 4), group.planes[1][63]);
	try testing.expectEqual(@as(i32, -4), group.planes[0][63]);
	try testing.expectEqual(@as(i32, 0), group.planes[2][63]);
	p.shift = 0;
	var second = Sequence{ .values = &.{ 1, 2, 1, 1, 0 } };
	try group.decodePass(testing.allocator, p, &second);
	try testing.expectEqual(@as(i32, 5), group.planes[1][63]);
	try testing.expectEqual(@as(i32, -5), group.planes[0][63]);
	try testing.expectEqual(@as(i32, 0), group.planes[1][0]);
	var impossible = Sequence{ .values = &.{64} };
	try testing.expectError(error.GenericError, group.decodePass(testing.allocator, p, &impossible));
	var too_many = Sequence{ .values = &.{ 63, 0 } };
	try testing.expectError(error.GenericError, group.decodePass(testing.allocator, p, &too_many));
	p.x = 1;
	try testing.expectError(error.GenericError, group.decodePass(testing.allocator, p, &first));
}
