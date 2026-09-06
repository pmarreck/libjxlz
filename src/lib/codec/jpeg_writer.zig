//! JPEG serialization from retained markers and quantized coefficients.
//! Coding follows lib/jxl/jpeg/dec_jpeg_data_writer.cc (BSD-3-Clause).
const std = @import("std");
const jpeg = @import("jpeg_reconstruction.zig");
const Error = @import("../base/status.zig").JxlError;
const order = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };
const Table = struct { depths: [256]u5 = @splat(0), codes: [256]u16 = @splat(0) };
const State = struct {
	allocator: std.mem.Allocator,
	data: *const jpeg.Data,
	out: std.ArrayList(u8) = .empty,
	tables: [8]Table = @splat(.{}),
	pending: u32 = 0,
	pending_bits: u5 = 0,
	padding_pos: usize = 0,
	restarts_enabled: bool = false,
	progressive: bool = false,
	eob_run: u32 = 0,
	eob_table: usize = 0,
	refinement: std.ArrayList(u8) = .empty,
	refinement_scratch: [64]u8 = undefined,
	fn byte(self: *State, value: u8) Error!void {
		try self.out.append(self.allocator, value);
	}
	fn bytes(self: *State, value: []const u8) Error!void {
		try self.out.appendSlice(self.allocator, value);
	}
	fn word(self: *State, value: usize) Error!void {
		if (value > 65535) return error.GenericError;
		try self.byte(@intCast(value >> 8));
		try self.byte(@truncate(value));
	}
	fn marker(self: *State, value: u8) Error!void {
		try self.bytes(&.{ 255, value });
	}
	fn segment(self: *State, value: u8) Error!usize {
		try self.marker(value);
		const start = self.out.items.len;
		try self.word(0);
		return start;
	}
	fn endSegment(self: *State, start: usize) Error!void {
		const size = self.out.items.len - start;
		if (size > 65535) return error.GenericError;
		self.out.items[start] = @intCast(size >> 8);
		self.out.items[start + 1] = @truncate(size);
	}
	fn bits(self: *State, count: u5, value: u32) Error!void {
		if (count > 16) return error.GenericError;
		self.pending = (self.pending << count) | (value & ((@as(u32, 1) << count) - 1));
		self.pending_bits += count;
		while (self.pending_bits >= 8) {
			self.pending_bits -= 8;
			const b: u8 = @truncate(self.pending >> self.pending_bits);
			try self.byte(b);
			if (b == 255) try self.byte(0);
		}
	}
	fn alignByte(self: *State) Error!void {
		while (self.pending_bits != 0) {
			var value: u32 = 1;
			if (self.data.has_zero_padding_bit) {
				if (self.padding_pos >= self.data.padding.len) return error.GenericError;
				value = self.data.padding[self.padding_pos];
				self.padding_pos += 1;
				if (value > 1) return error.GenericError;
			}
			try self.bits(1, value);
		}
	}
	fn symbol(self: *State, table: usize, value: usize) Error!void {
		if (table >= self.tables.len or value >= 256) return error.GenericError;
		const depth = self.tables[table].depths[value];
		if (depth == 0) return error.GenericError;
		try self.bits(depth, self.tables[table].codes[value]);
	}
	fn magnitude(self: *State, table: usize, zeros: usize, value: i32) Error!void {
		const size: u5 = @intCast(32 - @clz(@abs(value)));
		try self.symbol(table, (zeros << 4) + size);
		if (size != 0) try self.bits(size, @bitCast(if (value < 0) value - 1 else value));
	}
	fn huffman(self: *State, huff: *const jpeg.Huffman) Error!void {
		var total: usize = 0;
		var last: usize = 0;
		for (huff.counts, 0..) |count, i| {
			total += count;
			if (count != 0) last = i;
		}
		if (total == 0) return;
		if (total > 257 or last == 0) return error.GenericError;
		const slot = (huff.slot_id & 3) + @as(usize, if (huff.slot_id & 16 != 0) 4 else 0);
		self.tables[slot] = .{};
		try self.byte(huff.slot_id);
		var pos: usize = 0;
		var code: u32 = 0;
		for (1..17) |length| {
			const count = huff.counts[length] - @as(u32, if (length == last) 1 else 0);
			if (count > 255) return error.GenericError;
			try self.byte(@intCast(count));
			for (0..count) |_| {
				const value = huff.values[pos];
				pos += 1;
				if (value >= 256 or code >= @as(u32, 1) << @intCast(length)) return error.GenericError;
				self.tables[slot].depths[value] = @intCast(length);
				self.tables[slot].codes[value] = @intCast(code);
				code += 1;
			}
			code <<= 1;
		}
		for (huff.values[0 .. total - 1]) |value| {
			if (value >= 256) return error.GenericError;
			try self.byte(@intCast(value));
		}
	}
	fn block(self: *State, coeffs: []const i16, dc_table: usize, ac_table: usize, last_dc: *i32, extra: u32) Error!void {
		const dc: i32 = coeffs[0];
		try self.magnitude(dc_table, 0, dc - last_dc.*);
		last_dc.* = dc;
		var zeros: usize = 0;
		for (order[1..]) |i| {
			const value: i32 = coeffs[i];
			if (value == 0) {
				zeros += 1;
				continue;
			}
			while (zeros >= 16) {
				try self.symbol(ac_table, 0xf0);
				zeros -= 16;
			}
			try self.magnitude(ac_table, zeros, value);
			zeros = 0;
		}
		try self.extraZeroRuns(ac_table, &zeros, extra);
		if (zeros != 0) try self.symbol(ac_table, 0);
	}
	fn extraZeroRuns(self: *State, table: usize, zeros: *usize, count: u32) Error!void {
		if (count > zeros.* / 16) return error.GenericError;
		for (0..count) |_| {
			try self.symbol(table, 0xf0);
			zeros.* -= 16;
		}
	}
	fn flush(self: *State) Error!void {
		if (self.eob_run != 0) {
			const count: u5 = @intCast(31 - @clz(self.eob_run));
			try self.symbol(self.eob_table, @as(usize, count) << 4);
			try self.bits(count, self.eob_run);
			self.eob_run = 0;
		}
		for (self.refinement.items) |bit| try self.bits(1, bit);
		self.refinement.clearRetainingCapacity();
	}
	fn endBand(self: *State, table: usize, new_bits: []const u8) Error!void {
		if (self.eob_run == 0) self.eob_table = table;
		self.eob_run += 1;
		try self.refinement.appendSlice(self.allocator, new_bits);
		if (self.eob_run == 0x7fff) try self.flush();
	}
	fn initialBlock(self: *State, coeffs: []const i16, scan_info: *const jpeg.Scan, dc_table: usize, ac_table: usize, last_dc: *i32, extra: u32) Error!void {
		var start: usize = scan_info.ss;
		if (start == 0) {
			const dc: i32 = coeffs[0] >> scan_info.al;
			try self.magnitude(dc_table, 0, dc - last_dc.*);
			last_dc.* = dc;
			start = 1;
		}
		var zeros: usize = 0;
		var k = start;
		while (k <= scan_info.se) : (k += 1) {
			const raw: i32 = coeffs[order[k]];
			const abs: i32 = @intCast(@abs(raw) >> scan_info.al);
			if (abs == 0) {
				zeros += 1;
				continue;
			}
			try self.flush();
			while (zeros >= 16) {
				try self.symbol(ac_table, 0xf0);
				zeros -= 16;
			}
			try self.magnitude(ac_table, zeros, if (raw < 0) -abs else abs);
			zeros = 0;
		}
		if (extra != 0) {
			try self.flush();
			try self.extraZeroRuns(ac_table, &zeros, extra);
		}
		if (zeros != 0) {
			try self.endBand(ac_table, &.{});
			if (scan_info.ss == 0) try self.flush();
		}
	}
	fn refinementBlock(self: *State, coeffs: []const i16, scan_info: *const jpeg.Scan, ac_table: usize) Error!void {
		var start: usize = scan_info.ss;
		if (start == 0) {
			try self.bits(1, @bitCast(@as(i32, coeffs[0]) >> scan_info.al));
			start = 1;
		}
		var last_new: usize = 0;
		var k = start;
		while (k <= scan_info.se) : (k += 1) {
			if (@abs(@as(i32, coeffs[order[k]])) >> scan_info.al == 1) last_new = k;
		}
		var zeros: usize = 0;
		var new_count: usize = 0;
		k = start;
		while (k <= scan_info.se) : (k += 1) {
			const raw: i32 = coeffs[order[k]];
			const abs = @abs(raw) >> scan_info.al;
			if (abs == 0) {
				zeros += 1;
				continue;
			}
			while (zeros >= 16 and k <= last_new) {
				try self.flush();
				try self.symbol(ac_table, 0xf0);
				zeros -= 16;
				for (self.refinement_scratch[0..new_count]) |bit| try self.bits(1, bit);
				new_count = 0;
			}
			if (abs > 1) {
				self.refinement_scratch[new_count] = @intCast(abs & 1);
				new_count += 1;
				continue;
			}
			try self.flush();
			try self.symbol(ac_table, (zeros << 4) | 1);
			try self.bits(1, if (raw < 0) 0 else 1);
			for (self.refinement_scratch[0..new_count]) |bit| try self.bits(1, bit);
			new_count = 0;
			zeros = 0;
		}
		if (zeros != 0 or new_count != 0) {
			try self.endBand(ac_table, self.refinement_scratch[0..new_count]);
			if (scan_info.ss == 0) try self.flush();
		}
	}
	fn scan(self: *State, scan_info: *const jpeg.Scan) Error!void {
		if (scan_info.components.len == 0) return error.GenericError;
		const start = try self.segment(0xda);
		try self.byte(@intCast(scan_info.components.len));
		for (scan_info.components) |c| {
			if (c.component >= self.data.components.len) return error.GenericError;
			try self.byte(self.data.components[c.component].id);
			try self.byte((@as(u8, c.dc_table) << 4) | c.ac_table);
		}
		try self.bytes(&.{ scan_info.ss, scan_info.se, (@as(u8, scan_info.ah) << 4) | scan_info.al });
		try self.endSegment(start);
		const interleaved = scan_info.components.len > 1;
		var max_h: usize = 1;
		var max_v: usize = 1;
		for (self.data.components) |c| {
			max_h = @max(max_h, c.h_sampling);
			max_v = @max(max_v, c.v_sampling);
		}
		const base = self.data.components[scan_info.components[0].component];
		const width = std.math.divCeil(usize, self.data.width * (if (interleaved) @as(usize, 1) else base.h_sampling), 8 * max_h) catch return error.GenericError;
		const height = std.math.divCeil(usize, self.data.height * (if (interleaved) @as(usize, 1) else base.v_sampling), 8 * max_v) catch return error.GenericError;
		var last_dc: [3]i32 = @splat(0);
		const interval: usize = if (self.restarts_enabled) self.data.restart_interval else 0;
		var remaining = interval;
		var restart: u3 = 0;
		var block_index: usize = 0;
		var reset_index: usize = 0;
		var extra_index: usize = 0;
		for (0..height) |my| for (0..width) |mx| {
			if (interval != 0 and remaining == 0) {
				try self.flush();
				try self.alignByte();
				try self.marker(0xd0 + @as(u8, restart));
				restart +%= 1;
				remaining = interval;
				last_dc = @splat(0);
			}
			for (scan_info.components) |sc| {
				const c = self.data.components[sc.component];
				const nx: usize = if (interleaved) c.h_sampling else 1;
				const ny: usize = if (interleaved) c.v_sampling else 1;
				for (0..ny) |iy| for (0..nx) |ix| {
					const x = mx * nx + ix;
					const y = my * ny + iy;
					if (x >= c.width_blocks or y >= c.height_blocks) return error.GenericError;
					const offset = (y * c.width_blocks + x) * 64;
					if (offset + 64 > c.coefficients.len) return error.GenericError;
					if (reset_index < scan_info.reset_points.len and block_index == scan_info.reset_points[reset_index]) {
						try self.flush();
						reset_index += 1;
					}
					const coefficients = c.coefficients[offset..][0..64];
					const ac_table = 4 + @as(usize, sc.ac_table);
					var extra: u32 = 0;
					if (extra_index < scan_info.extra_zero_runs.len and block_index == scan_info.extra_zero_runs[extra_index].block) {
						extra = scan_info.extra_zero_runs[extra_index].count;
						extra_index += 1;
					}
					if (!self.progressive or (scan_info.ah == 0 and scan_info.al == 0 and scan_info.ss == 0 and scan_info.se == 63)) {
						try self.block(coefficients, sc.dc_table, ac_table, &last_dc[sc.component], extra);
					} else if (scan_info.ah == 0) {
						try self.initialBlock(coefficients, scan_info, sc.dc_table, ac_table, &last_dc[sc.component], extra);
					} else try self.refinementBlock(coefficients, scan_info, ac_table);
					block_index += 1;
				};
			}
			if (interval != 0) remaining -= 1;
		};
		try self.flush();
		try self.alignByte();
	}
};
pub fn write(allocator: std.mem.Allocator, data: *const jpeg.Data) Error![]u8 {
	if (data.width == 0 or data.height == 0 or data.width > 65535 or data.height > 65535 or (data.components.len != 1 and data.components.len != 3)) return error.GenericError;
	const s = try allocator.create(State);
	defer allocator.destroy(s);
	s.* = .{ .allocator = allocator, .data = data };
	errdefer s.out.deinit(allocator);
	defer s.refinement.deinit(allocator);
	var app: usize = 0;
	var comment: usize = 0;
	var quant: usize = 0;
	var huff: usize = 0;
	var scan: usize = 0;
	var inter: usize = 0;
	try s.marker(0xd8);
	for (data.markers) |marker| switch (marker) {
		0xc0, 0xc1, 0xc2 => {
			s.progressive = marker == 0xc2;
			const start = try s.segment(marker);
			try s.byte(8);
			try s.word(data.height);
			try s.word(data.width);
			try s.byte(@intCast(data.components.len));
			for (data.components) |c| {
				if (c.quant_index >= data.quant.len) return error.GenericError;
				try s.bytes(&.{ c.id, (c.h_sampling << 4) | c.v_sampling, data.quant[c.quant_index].index });
			}
			try s.endSegment(start);
		},
		0xc4 => {
			const start = try s.segment(marker);
			while (true) {
				if (huff >= data.huffman.len) return error.GenericError;
				const entry = &data.huffman[huff];
				huff += 1;
				try s.huffman(entry);
				if (entry.is_last) break;
			}
			try s.endSegment(start);
		},
		0xdb => {
			const start = try s.segment(marker);
			while (true) {
				if (quant >= data.quant.len) return error.GenericError;
				const entry = &data.quant[quant];
				quant += 1;
				try s.byte((@as(u8, entry.precision) << 4) | entry.index);
				for (order) |i| {
					const value = entry.values[i];
					if (value <= 0 or value > 65535) return error.GenericError;
					if (entry.precision != 0) try s.word(@intCast(value)) else {
						if (value > 255) return error.GenericError;
						try s.byte(@intCast(value));
					}
				}
				if (entry.is_last) break;
			}
			try s.endSegment(start);
		},
		0xdd => {
			s.restarts_enabled = true;
			try s.marker(marker);
			try s.word(4);
			try s.word(data.restart_interval);
		},
		0xe0...0xef => {
			if (app >= data.apps.len) return error.GenericError;
			try s.byte(255);
			try s.bytes(data.apps[app].data);
			app += 1;
		},
		0xfe => {
			if (comment >= data.comments.len) return error.GenericError;
			try s.byte(255);
			try s.bytes(data.comments[comment].data);
			comment += 1;
		},
		0xff => {
			if (inter >= data.inter_marker.len) return error.GenericError;
			try s.bytes(data.inter_marker[inter]);
			inter += 1;
		},
		0xd0...0xd7 => try s.marker(marker),
		0xda => {
			if (scan >= data.scans.len) return error.GenericError;
			try s.scan(&data.scans[scan]);
			scan += 1;
		},
		0xd9 => {
			try s.marker(marker);
			try s.bytes(data.tail);
		},
		else => return error.GenericError,
	};
	if (data.has_zero_padding_bit and s.padding_pos != data.padding.len) return error.GenericError;
	return s.out.toOwnedSlice(allocator);
}
