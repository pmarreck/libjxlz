//! JPEG reconstruction metadata. Numeric image coefficients arrive separately.
const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const fields = @import("field_coders.zig");
const Error = @import("../base/status.zig").JxlError;
const brotli = @import("../base/brotli.zig");
const Kind = enum(u2) { unknown, icc, exif, xmp };
pub const Marker = struct { kind: Kind = .unknown, length: usize, data: []u8 = &.{} };
pub const Quant = struct { precision: u1, index: u2, is_last: bool, values: [64]i32 = @splat(0) };
pub const Component = struct {
	id: u8, quant_index: u2,
	h_sampling: u8 = 1, v_sampling: u8 = 1,
	width_blocks: usize = 0, height_blocks: usize = 0,
	coefficients: []i16 = &.{},
};
pub const Huffman = struct { slot_id: u8, is_last: bool, counts: [17]u32 = @splat(0), values: [257]u32 = @splat(0) };
pub const ScanComponent = struct { component: u2, ac_table: u2, dc_table: u2 };
pub const ZeroRun = struct { block: u32, count: u32 };
pub const Scan = struct {
	ss: u6,
	se: u6,
	al: u4,
	ah: u4,
	last_needed_pass: u32,
	components: []ScanComponent,
	reset_points: []u32 = &.{},
	extra_zero_runs: []ZeroRun = &.{},
};
pub const Data = struct {
	arena: std.heap.ArenaAllocator,
	width: usize = 0,
	height: usize = 0,
	markers: []u8 = &.{},
	components: []Component = &.{},
	quant: []Quant = &.{},
	apps: []Marker = &.{},
	comments: []Marker = &.{},
	huffman: []Huffman = &.{},
	scans: []Scan = &.{},
	restart_interval: u16 = 0,
	has_zero_padding_bit: bool = false,
	padding: []u8 = &.{},
	inter_marker: [][]u8 = &.{},
	tail: []u8 = &.{},
	pub fn deinit(self: *Data) void {
		self.arena.deinit();
	}
};
const Reader = struct {
	br: BitReader,
	fn require(self: *Reader, count: usize) Error!void {
		const consumed = self.br.totalBitsConsumed();
		const available = self.br.totalBytes() * 8;
		if (consumed > available or count > available - consumed) return error.GenericError;
	}
	fn bits(self: *Reader, count: usize) Error!u32 {
		try self.require(count);
		return @intCast(self.br.readBits(count));
	}
	fn field(self: *Reader, distribution: fields.U32Enc) Error!u32 {
		const value = fields.U32Coder.read(distribution, &self.br);
		if (!self.br.allReadsWithinBounds()) return error.GenericError;
		return value;
	}
};
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Data {
	var result = Data{ .arena = std.heap.ArenaAllocator.init(allocator) };
	errdefer result.deinit();
	const memory = result.arena.allocator();
	var reader = Reader{ .br = BitReader.init(bytes) };
	defer reader.br.close() catch {};
	_ = try reader.bits(1);
	var markers: std.ArrayList(u8) = .empty;
	var apps: usize = 0;
	var comments: usize = 0;
	var scans: usize = 0;
	var inter_markers: usize = 0;
	var has_dri = false;
	while (true) {
		if (markers.items.len == 16384) return error.GenericError;
		const marker: u8 = @intCast(0xc0 + try reader.bits(6));
		try markers.append(memory, marker);
		if (marker & 0xf0 == 0xe0) apps += 1;
		if (marker == 0xfe) comments += 1;
		if (marker == 0xda) scans += 1;
		if (marker == 0xff) inter_markers += 1;
		if (marker == 0xdd) has_dri = true;
		if (marker == 0xd9) break;
	}
	result.markers = try markers.toOwnedSlice(memory);
	result.apps = try memory.alloc(Marker, apps);
	result.comments = try memory.alloc(Marker, comments);
	for (result.apps) |*app| {
		const kind = try reader.field(fields.U32Enc.init(fields.val(0), fields.val(1), fields.bitsOffset(1, 2), fields.bitsOffset(2, 4)));
		if (kind > 3) return error.GenericError;
		const length = 1 + try reader.bits(16);
		if (length < 3) return error.GenericError;
		app.* = .{ .kind = @enumFromInt(kind), .length = length };
	}
	for (result.comments) |*comment| {
		const length = 1 + try reader.bits(16);
		if (length < 3) return error.GenericError;
		comment.* = .{ .length = length };
	}
	const count = try reader.field(fields.U32Enc.init(fields.val(1), fields.val(2), fields.val(3), fields.val(4)));
	if (count == 4) return error.GenericError;
	result.quant = try memory.alloc(Quant, count);
	for (result.quant) |*quant| quant.* = .{ .precision = @intCast(try reader.bits(1)), .index = @intCast(try reader.bits(2)), .is_last = try reader.bits(1) != 0 };
	const kind = try reader.bits(2);
	const components = if (kind == 0) 1 else if (kind != 3) 3 else try reader.field(fields.U32Enc.init(fields.val(1), fields.val(2), fields.val(3), fields.val(4)));
	if (components != 1 and components != 3) return error.GenericError;
	result.components = try memory.alloc(Component, components);
	for (result.components, 0..) |*component, i| component.* = .{ .id = if (kind == 3) @intCast(try reader.bits(8)) else if (kind == 2) "RGB"[i] else @intCast(i + 1), .quant_index = 0 };
	var used: u4 = 0;
	for (result.components) |*component| {
		component.quant_index = @intCast(try reader.bits(2));
		if (component.quant_index >= result.quant.len) return error.GenericError;
		used |= @as(u4, 1) << component.quant_index;
	}
	if (used & 1 == 0) return error.GenericError;
	const huff_count = try reader.field(fields.U32Enc.init(fields.val(4), fields.bitsOffset(3, 2), fields.bitsOffset(4, 10), fields.bitsOffset(6, 26)));
	try reader.require(huff_count * 38);
	result.huffman = try memory.alloc(Huffman, huff_count);
	for (result.huffman) |*huff| {
		const is_ac = try reader.bits(1) != 0;
		huff.* = .{ .slot_id = @intCast((@as(u32, @intFromBool(is_ac)) << 4) | try reader.bits(2)), .is_last = try reader.bits(1) != 0 };
		var symbols: usize = 0;
		for (&huff.counts) |*count_ptr| {
			count_ptr.* = try reader.field(fields.U32Enc.init(fields.val(0), fields.val(1), fields.bitsOffset(3, 2), fields.bits(8)));
			symbols += count_ptr.*;
		}
		if (symbols == 0) continue;
		if (symbols > huff.values.len) return error.GenericError;
		var seen = [_]bool{false} ** 257;
		for (huff.values[0..symbols]) |*value| {
			value.* = try reader.field(fields.U32Enc.init(fields.bits(2), fields.bitsOffset(2, 4), fields.bitsOffset(4, 8), fields.bitsOffset(8, 1)));
			if (seen[value.*] or (!is_ac and value.* >= 12 and value.* != 256)) return error.GenericError;
			seen[value.*] = true;
		}
		if (huff.values[symbols - 1] != 256) return error.GenericError;
	}
	try reader.require(scans * 30);
	result.scans = try memory.alloc(Scan, scans);
	for (result.scans) |*scan| {
		const num_components = try reader.field(fields.U32Enc.init(fields.val(1), fields.val(2), fields.val(3), fields.val(4)));
		if (num_components == 4) return error.GenericError;
		scan.* = .{
			.ss = @intCast(try reader.bits(6)),
			.se = @intCast(try reader.bits(6)),
			.al = @intCast(try reader.bits(4)),
			.ah = @intCast(try reader.bits(4)),
			.components = try memory.alloc(ScanComponent, num_components),
			.last_needed_pass = 0,
		};
		for (scan.components) |*component| {
			component.* = .{ .component = @intCast(try reader.bits(2)), .ac_table = @intCast(try reader.bits(2)), .dc_table = @intCast(try reader.bits(2)) };
			if (component.component >= result.components.len) return error.GenericError;
		}
		scan.last_needed_pass = try reader.field(fields.U32Enc.init(fields.val(0), fields.val(1), fields.val(2), fields.bitsOffset(3, 3)));
	}
	if (has_dri) result.restart_interval = @intCast(try reader.bits(16));
	const run_count = fields.U32Enc.init(fields.val(0), fields.bitsOffset(2, 1), fields.bitsOffset(4, 4), fields.bitsOffset(16, 20));
	const block_delta = fields.U32Enc.init(fields.val(0), fields.bitsOffset(3, 1), fields.bitsOffset(5, 9), fields.bitsOffset(28, 41));
	for (result.scans) |*scan| {
		const resets = try reader.field(run_count);
		try reader.require(resets * 2);
		scan.reset_points = try memory.alloc(u32, resets);
		var next_block: u32 = 0;
		for (scan.reset_points) |*point| {
			point.* = next_block + try reader.field(block_delta);
			if (point.* >= 3 << 26) return error.GenericError;
			next_block = point.* + 1;
		}
		const zeros = try reader.field(run_count);
		try reader.require(zeros * 4);
		scan.extra_zero_runs = try memory.alloc(ZeroRun, zeros);
		next_block = 0;
		for (scan.extra_zero_runs) |*run| {
			run.count = try reader.field(fields.U32Enc.init(fields.val(1), fields.bitsOffset(2, 2), fields.bitsOffset(4, 5), fields.bitsOffset(8, 20)));
			run.block = next_block + try reader.field(block_delta);
			if (run.block > 3 << 26) return error.GenericError;
			next_block = run.block + 1;
		}
	}
	try reader.require(inter_markers * 16);
	result.inter_marker = try memory.alloc([]u8, inter_markers);
	const inter_lengths = try memory.alloc(usize, inter_markers);
	for (inter_lengths) |*length| length.* = try reader.bits(16);
	const tail_length = try reader.field(fields.U32Enc.init(fields.val(0), fields.bitsOffset(8, 1), fields.bitsOffset(16, 257), fields.bitsOffset(22, 65793)));
	result.has_zero_padding_bit = try reader.bits(1) != 0;
	if (result.has_zero_padding_bit) {
		const padding = try reader.bits(24);
		try reader.require(padding);
		result.padding = try memory.alloc(u8, padding);
		for (result.padding) |*bit| bit.* = @intCast(try reader.bits(1));
	}
	try validateTableOrder(&result);
	try reader.br.jumpToByteBoundary();
	try reader.require(0);
	var payload_length: usize = tail_length;
	for (result.apps) |app| if (app.kind == .unknown) {
		payload_length += app.length;
	};
	for (result.comments) |comment| payload_length += comment.length;
	for (inter_lengths) |length| payload_length += length;
	const payload = try brotli.decompressBounded(memory, bytes[reader.br.totalBitsConsumed() / 8 ..], payload_length);
	if (payload.len != payload_length) return error.GenericError;
	var offset: usize = 0;
	var icc_count: u8 = 0;
	for (result.apps) |*app| {
		if (app.kind == .unknown) {
			app.data = payload[offset..][0..app.length];
			offset += app.length;
			try validateMarkerSize(app.data);
			continue;
		}
		const tag: []const u8 = switch (app.kind) {
			.icc => "ICC_PROFILE\x00",
			.exif => "Exif\x00\x00",
			.xmp => "http://ns.adobe.com/xap/1.0/\x00",
			.unknown => unreachable,
		};
		const header_length = 3 + tag.len + @as(usize, if (app.kind == .icc) 2 else 0);
		if (app.length < header_length) return error.GenericError;
		app.data = try memory.alloc(u8, app.length);
		@memset(app.data, 0);
		app.data[0] = if (app.kind == .icc) 0xe2 else 0xe1;
		app.data[1] = @intCast((app.length - 1) >> 8);
		app.data[2] = @truncate(app.length - 1);
		@memcpy(app.data[3..][0..tag.len], tag);
		if (app.kind == .icc) {
			icc_count +%= 1;
			app.data[15] = icc_count;
		}
	}
	for (result.apps) |app| if (app.kind == .icc) {
		app.data[16] = icc_count;
	};
	for (result.comments) |*comment| {
		comment.data = payload[offset..][0..comment.length];
		offset += comment.length;
		try validateMarkerSize(comment.data);
	}
	for (result.inter_marker, inter_lengths) |*data, length| {
		data.* = payload[offset..][0..length];
		offset += length;
	}
	result.tail = payload[offset..];
	return result;
}

fn validateMarkerSize(data: []const u8) Error!void {
	if (@as(usize, data[1]) * 256 + data[2] + 1 != data.len) return error.GenericError;
}

fn validateTableOrder(data: *const Data) Error!void {
	var huffman: usize = 0;
	var scan: usize = 0;
	var progressive = false;
	var ac = [_]bool{false} ** 4;
	var dc = [_]bool{false} ** 4;
	for (data.markers) |marker| switch (marker) {
		0xc2 => progressive = true,
		0xc4 => while (huffman < data.huffman.len) {
			const table = data.huffman[huffman];
			huffman += 1;
			if (table.slot_id & 16 != 0) ac[table.slot_id & 3] = true else dc[table.slot_id & 3] = true;
			if (table.is_last) break;
		},
		0xda => {
			const current = data.scans[scan];
			scan += 1;
			for (current.components) |component| {
				if ((!progressive or current.ss == 0) and !dc[component.dc_table]) return error.GenericError;
				if ((!progressive or current.ss != 0 or current.se != 0) and !ac[component.ac_table]) return error.GenericError;
			}
		},
		else => {},
	};
}
