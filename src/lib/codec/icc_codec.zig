const std = @import("std");
const common = @import("icc_codec_common.zig");
const icc_profiles = @import("icc_profiles.zig");

const kSizeLimit: usize = std.math.maxInt(u32) >> 2;
const kOutputLimit: usize = 1 << 28;

fn encodeVarInt(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
	var remaining = value;
	while (remaining > 127) {
		try bytes.append(allocator, @as(u8, @intCast(remaining & 127)) | 128);
		remaining >>= 7;
	}
	try bytes.append(allocator, @intCast(remaining & 127));
}

fn decodeVarInt(input: []const u8, pos: *usize) u64 {
	var i: usize = 0;
	var ret: u64 = 0;
	while (pos.* + i < input.len and i < 10) : (i += 1) {
		ret |= @as(u64, input[pos.* + i] & 127) << @as(u6, @intCast(7 * i));
		if ((input[pos.* + i] & 128) == 0) break;
	}
	pos.* += i + 1;
	return ret;
}

fn isPredictedTagSize20(tag: common.Tag) bool {
	return std.mem.eql(u8, &tag, &common.kRxyzTag) or
		std.mem.eql(u8, &tag, &common.kGxyzTag) or
		std.mem.eql(u8, &tag, &common.kBxyzTag) or
		std.mem.eql(u8, &tag, &common.kKxyzTag) or
		std.mem.eql(u8, &tag, &common.kWtptTag) or
		std.mem.eql(u8, &tag, &common.kBkptTag) or
		std.mem.eql(u8, &tag, &common.kLumiTag);
}

fn tagCode(tag: common.Tag) u8 {
	for (common.kTagStrings, 0..) |known, i| {
		if (std.mem.eql(u8, &tag, &known)) return @intCast(i + common.kCommandTagStringFirst);
	}
	return @intCast(common.kCommandTagUnknown);
}

/// Validates the ICC codec preamble enough to reject obvious truncation and
/// bogus output sizes before any command/data reconstruction begins.
pub fn checkPreamble(data: []const u8, enc_size: usize) !void {
	var pos: usize = 0;
	if (pos >= data.len) return error.OutOfBounds;
	const osize = decodeVarInt(data, &pos);
	try common.checkIs32Bit(osize);
	if (pos >= data.len) return error.OutOfBounds;
	const csize = decodeVarInt(data, &pos);
	try common.checkIs32Bit(csize);
	try common.checkOutOfBounds(pos, csize, data.len);
	if (osize + 65536 < enc_size) return error.MalformedIcc;
	if (osize >= kOutputLimit) return error.DecodedTooLarge;
}

/// Transforms raw ICC bytes into the JPEG XL compressed-ICC intermediate form.
/// The current slice proves the shared predictor path and broadens beyond the
/// header by using a legal insert-only fallback for all post-header bytes.
pub fn predictICC(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = true,
		.model_type_starts = true,
		.model_xyz = true,
		.model_mluc_shuffle = true,
		.model_sf32_shuffle = true,
	});
}

fn predictICCInsertOnlyFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = false,
		.model_type_starts = false,
		.model_xyz = false,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
	});
}

fn predictICCTagTableFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = true,
		.model_type_starts = false,
		.model_xyz = false,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
	});
}

fn predictICCBodyStructureFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = true,
		.model_type_starts = true,
		.model_xyz = true,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
	});
}

const PredictOptions = struct {
	model_tag_list: bool,
	model_type_starts: bool,
	model_xyz: bool,
	model_mluc_shuffle: bool,
	model_sf32_shuffle: bool,
};

fn unshuffle(data: []u8, width: usize) void {
	const height = (data.len + width - 1) / width;
	var result = std.heap.stackFallback(4096, std.heap.page_allocator);
	const allocator = result.get();
	const tmp = allocator.alloc(u8, data.len) catch @panic("oom");
	defer allocator.free(tmp);

	var s: usize = 0;
	var j: usize = 0;
	for (data, 0..) |b, i| {
		tmp[j] = b;
		_ = i;
		j += height;
		if (j >= data.len) {
			s += 1;
			j = s;
		}
	}
	@memcpy(data, tmp);
}

fn shuffle(data: []u8, width: usize) void {
	const height = (data.len + width - 1) / width;
	var result = std.heap.stackFallback(4096, std.heap.page_allocator);
	const allocator = result.get();
	const tmp = allocator.alloc(u8, data.len) catch @panic("oom");
	defer allocator.free(tmp);

	var s: usize = 0;
	var j: usize = 0;
	for (0..data.len) |i| {
		tmp[i] = data[j];
		j += height;
		if (j >= data.len) {
			s += 1;
			j = s;
		}
	}
	@memcpy(data, tmp);
}

fn commandStream(encoded: []const u8) []const u8 {
	var pos: usize = 0;
	_ = decodeVarInt(encoded, &pos);
	const csize = decodeVarInt(encoded, &pos);
	return encoded[pos .. pos + @as(usize, @intCast(csize))];
}

fn bodyCommandsContain(encoded: []const u8, opcode: u8) bool {
	const commands = commandStream(encoded);
	var pos: usize = 0;
	_ = decodeVarInt(commands, &pos);
	while (pos < commands.len) {
		const command = commands[pos];
		pos += 1;
		const code = command & 63;
		if (code == 0) break;
		if ((command & common.kFlagBitOffset) != 0) _ = decodeVarInt(commands, &pos);
		if ((command & common.kFlagBitSize) != 0) _ = decodeVarInt(commands, &pos);
	}
	while (pos < commands.len) {
		const command = commands[pos];
		pos += 1;
		if (command == opcode) return true;
		switch (command) {
			common.kCommandInsert, common.kCommandShuffle2, common.kCommandShuffle4 => {
				_ = decodeVarInt(commands, &pos);
			},
			common.kCommandXYZ => {},
			else => {
				if (!(command >= common.kCommandTypeStartFirst and command < common.kCommandTypeStartFirst + common.kTypeStrings.len)) return false;
			},
		}
	}
	return false;
}

fn predictICCImpl(allocator: std.mem.Allocator, icc: []const u8, options: PredictOptions) ![]u8 {
	if (icc.len > kSizeLimit) return error.ProfileTooLarge;

	var result: std.ArrayList(u8) = .{};
	errdefer result.deinit(allocator);
	try encodeVarInt(&result, allocator, icc.len);

	var commands: std.ArrayList(u8) = .{};
	defer commands.deinit(allocator);
	var tag_sizes = std.AutoHashMap(usize, usize).init(allocator);
	defer tag_sizes.deinit();
	var header = common.initialHeaderPrediction(@intCast(icc.len));
	var data: std.ArrayList(u8) = .{};
	defer data.deinit(allocator);
	for (0..@min(icc.len, common.kICCHeaderSize)) |i| {
		common.predictHeader(icc, &header, i);
		try data.append(allocator, icc[i] -% header[i]);
	}

	var tail_pos = common.kICCHeaderSize;
	if (icc.len > common.kICCHeaderSize) {
		if (options.model_tag_list and tail_pos + 4 <= icc.len) {
			const numtags = common.decodeUint32(icc, tail_pos);
			tail_pos += 4;
			try encodeVarInt(&commands, allocator, @as(u64, numtags) + 1);
			var prevtagstart: u64 = common.kICCHeaderSize + @as(u64, numtags) * 12;
			var prevtagsize: u32 = 0;
			var i: u32 = 0;
			while (i < numtags and tail_pos + 12 <= icc.len) : (i += 1) {
				const tag = common.decodeKeyword(icc, tail_pos);
				const tagstart = common.decodeUint32(icc, tail_pos + 4);
				const tagsize = common.decodeUint32(icc, tail_pos + 8);
				tail_pos += 12;
				try tag_sizes.put(@intCast(tagstart), @intCast(tagsize));

				var code = tagCode(tag);
				if (std.mem.eql(u8, &tag, &common.kRtrcTag) and tail_pos + 24 < icc.len) {
					var ok = true;
					ok = ok and std.mem.eql(u8, &common.decodeKeyword(icc, tail_pos), &common.kGtrcTag);
					ok = ok and std.mem.eql(u8, &common.decodeKeyword(icc, tail_pos + 12), &common.kBtrcTag);
					if (ok) {
						for (0..8) |kk| {
							if (icc[tail_pos - 8 + kk] != icc[tail_pos + 4 + kk]) ok = false;
							if (icc[tail_pos - 8 + kk] != icc[tail_pos + 16 + kk]) ok = false;
						}
					}
					if (ok) {
						code = @intCast(common.kCommandTagTRC);
						tail_pos += 24;
						i += 2;
					}
				}
				if (std.mem.eql(u8, &tag, &common.kRxyzTag) and tail_pos + 24 < icc.len) {
					var ok = true;
					ok = ok and std.mem.eql(u8, &common.decodeKeyword(icc, tail_pos), &common.kGxyzTag);
					ok = ok and std.mem.eql(u8, &common.decodeKeyword(icc, tail_pos + 12), &common.kBxyzTag);
					const offsetr = tagstart;
					const offsetg = common.decodeUint32(icc, tail_pos + 4);
					const offsetb = common.decodeUint32(icc, tail_pos + 16);
					const sizer = tagsize;
					const sizeg = common.decodeUint32(icc, tail_pos + 8);
					const sizeb = common.decodeUint32(icc, tail_pos + 20);
					ok = ok and sizer == 20 and sizeg == 20 and sizeb == 20;
					ok = ok and offsetg == offsetr + 20 and offsetb == offsetr + 40;
					if (ok) {
						code = @intCast(common.kCommandTagXYZ);
						tail_pos += 24;
						i += 2;
					}
				}

				var command = code;
				const predicted_tagstart = prevtagstart + prevtagsize;
				if (predicted_tagstart != tagstart) command |= @intCast(common.kFlagBitOffset);
				var predicted_tagsize: u32 = prevtagsize;
				if (isPredictedTagSize20(tag)) predicted_tagsize = 20;
				if (predicted_tagsize != tagsize) command |= @intCast(common.kFlagBitSize);
				try commands.append(allocator, command);
				if (code == common.kCommandTagUnknown) try common.appendKeyword(&data, allocator, tag);
				if ((command & common.kFlagBitOffset) != 0) try encodeVarInt(&commands, allocator, tagstart);
				if ((command & common.kFlagBitSize) != 0) try encodeVarInt(&commands, allocator, tagsize);
				prevtagstart = tagstart;
				prevtagsize = tagsize;
			}
			try commands.append(allocator, 0);
		} else {
			try encodeVarInt(&commands, allocator, 0);
		}

		var insert_start = tail_pos;
		var pos = tail_pos;
		while (pos < icc.len) {
			if (options.model_mluc_shuffle and pos + 8 <= icc.len) {
				const sub_tag = common.decodeKeyword(icc, pos);
				const maybe_tag_size = tag_sizes.get(pos);
				if (std.mem.eql(u8, &sub_tag, &common.kMlucTag) and
					common.decodeUint32(icc, pos + 4) == 0 and
					maybe_tag_size != null)
				{
					const tag_size = maybe_tag_size.?;
					const num = tag_size - 8;
					if (tag_size >= 8 and pos + tag_size <= icc.len and (num & 1) == 0) {
						if (insert_start < pos) {
							try commands.append(allocator, common.kCommandInsert);
							try encodeVarInt(&commands, allocator, pos - insert_start);
							try data.appendSlice(allocator, icc[insert_start..pos]);
						}
						try commands.append(allocator, @intCast(common.kCommandTypeStartFirst + 3));
						try commands.append(allocator, common.kCommandShuffle2);
						try encodeVarInt(&commands, allocator, num);
						const start = data.items.len;
						try data.appendSlice(allocator, icc[pos + 8 .. pos + tag_size]);
						unshuffle(data.items[start..], 2);
						pos += tag_size;
						insert_start = pos;
						continue;
					}
				}
			}

			if (options.model_sf32_shuffle and pos + 8 <= icc.len) {
				const sub_tag = common.decodeKeyword(icc, pos);
				const maybe_tag_size = tag_sizes.get(pos);
				if (std.mem.eql(u8, &sub_tag, &common.kSf32Tag) and
					common.decodeUint32(icc, pos + 4) == 0 and
					maybe_tag_size != null)
				{
					const tag_size = maybe_tag_size.?;
					const num = tag_size - 8;
					if (tag_size >= 8 and pos + tag_size <= icc.len and (num & 3) == 0 and num > 0) {
						if (insert_start < pos) {
							try commands.append(allocator, common.kCommandInsert);
							try encodeVarInt(&commands, allocator, pos - insert_start);
							try data.appendSlice(allocator, icc[insert_start..pos]);
						}
						try commands.append(allocator, @intCast(common.kCommandTypeStartFirst + 6));
						try commands.append(allocator, common.kCommandShuffle4);
						try encodeVarInt(&commands, allocator, num);
						const start = data.items.len;
						try data.appendSlice(allocator, icc[pos + 8 .. pos + tag_size]);
						unshuffle(data.items[start..], 4);
						pos += tag_size;
						insert_start = pos;
						continue;
					}
				}
			}

			if (options.model_xyz and pos + 20 <= icc.len) {
				const sub_tag = common.decodeKeyword(icc, pos);
				if (std.mem.eql(u8, &sub_tag, &common.kXyz_Tag) and common.decodeUint32(icc, pos + 4) == 0) {
					if (insert_start < pos) {
						try commands.append(allocator, common.kCommandInsert);
						try encodeVarInt(&commands, allocator, pos - insert_start);
						try data.appendSlice(allocator, icc[insert_start..pos]);
					}
					try commands.append(allocator, common.kCommandXYZ);
					try data.appendSlice(allocator, icc[pos + 8 .. pos + 20]);
					pos += 20;
					insert_start = pos;
					continue;
				}
			}

			if (options.model_type_starts and pos + 8 <= icc.len and common.decodeUint32(icc, pos + 4) == 0) {
				const sub_tag = common.decodeKeyword(icc, pos);
				for (common.kTypeStrings, 0..) |known, i| {
					if (std.mem.eql(u8, &sub_tag, &known)) {
						if (insert_start < pos) {
							try commands.append(allocator, common.kCommandInsert);
							try encodeVarInt(&commands, allocator, pos - insert_start);
							try data.appendSlice(allocator, icc[insert_start..pos]);
						}
						try commands.append(allocator, @intCast(common.kCommandTypeStartFirst + i));
						pos += 8;
						insert_start = pos;
						break;
					}
				}
				if (insert_start == pos) continue;
			}

			pos += 1;
		}

		if (insert_start < icc.len) {
			try commands.append(allocator, common.kCommandInsert);
			try encodeVarInt(&commands, allocator, icc.len - insert_start);
			try data.appendSlice(allocator, icc[insert_start..]);
		}
	}

	try encodeVarInt(&result, allocator, commands.items.len);
	try result.appendSlice(allocator, commands.items);
	try result.appendSlice(allocator, data.items);
	return result.toOwnedSlice(allocator);
}

/// Reconstructs raw ICC bytes from the JPEG XL compressed-ICC intermediate
/// form. The current slice supports the zero-tag path plus raw insert commands.
pub fn unpredictICC(allocator: std.mem.Allocator, enc: []const u8) ![]u8 {
	var pos: usize = 0;
	if (pos >= enc.len) return error.OutOfBounds;
	const osize = decodeVarInt(enc, &pos);
	try common.checkIs32Bit(osize);
	if (osize >= kOutputLimit) return error.DecodedTooLarge;
	if (pos >= enc.len) return error.OutOfBounds;
	const csize = decodeVarInt(enc, &pos);
	try common.checkIs32Bit(csize);
	var cpos = pos;
	try common.checkOutOfBounds(pos, csize, enc.len);
	const commands_end = cpos + @as(usize, @intCast(csize));
	pos = commands_end;

	var result: std.ArrayList(u8) = .{};
	errdefer result.deinit(allocator);

	var header = common.initialHeaderPrediction(@intCast(osize));
	var i: usize = 0;
	while (i <= common.kICCHeaderSize) : (i += 1) {
		if (result.items.len == osize) {
			if (cpos != commands_end) return error.NotAllCommandsUsed;
			if (pos != enc.len) return error.NotAllDataUsed;
			return result.toOwnedSlice(allocator);
		}
		if (i == common.kICCHeaderSize) break;
		common.predictHeader(result.items, &header, i);
		if (pos >= enc.len) return error.OutOfBounds;
		try result.append(allocator, enc[pos] +% header[i]);
		pos += 1;
	}

	if (cpos >= commands_end) return error.OutOfBounds;
	var numtags = decodeVarInt(enc, &cpos);
	if (numtags != 0) {
		numtags -= 1;
		try common.checkIs32Bit(numtags);
		try common.appendUint32(&result, allocator, @intCast(numtags));
		var prevtagstart: u64 = common.kICCHeaderSize + numtags * 12;
		var prevtagsize: u64 = 0;
		while (true) {
			if (result.items.len > osize) return error.InvalidResultSize;
			if (cpos > commands_end) return error.OutOfBounds;
			if (cpos == commands_end) break;
			const command = enc[cpos];
			cpos += 1;
			const code = command & 63;
			var tag: common.Tag = undefined;
			if (code == 0) break;
			if (code == common.kCommandTagUnknown) {
				try common.checkOutOfBounds(pos, 4, enc.len);
				tag = common.decodeKeyword(enc, pos);
				pos += 4;
			} else if (code == common.kCommandTagTRC) {
				tag = common.kRtrcTag;
			} else if (code == common.kCommandTagXYZ) {
				tag = common.kRxyzTag;
			} else {
				const index = code - common.kCommandTagStringFirst;
				if (index >= common.kTagStrings.len) return error.UnknownTagCode;
				tag = common.kTagStrings[index];
			}
			try common.appendKeyword(&result, allocator, tag);

			var tagstart: u64 = undefined;
			var tagsize: u64 = prevtagsize;
			if (isPredictedTagSize20(tag)) tagsize = 20;

			if ((command & common.kFlagBitOffset) != 0) {
				if (cpos >= commands_end) return error.OutOfBounds;
				tagstart = decodeVarInt(enc, &cpos);
			} else {
				try common.checkIs32Bit(prevtagstart);
				tagstart = prevtagstart + prevtagsize;
			}
			try common.checkIs32Bit(tagstart);
			try common.appendUint32(&result, allocator, @intCast(tagstart));

			if ((command & common.kFlagBitSize) != 0) {
				if (cpos >= commands_end) return error.OutOfBounds;
				tagsize = decodeVarInt(enc, &cpos);
			}
			try common.checkIs32Bit(tagsize);
			try common.appendUint32(&result, allocator, @intCast(tagsize));
			prevtagstart = tagstart;
			prevtagsize = tagsize;

			if (code == common.kCommandTagTRC) {
				try common.appendKeyword(&result, allocator, common.kGtrcTag);
				try common.appendUint32(&result, allocator, @intCast(tagstart));
				try common.appendUint32(&result, allocator, @intCast(tagsize));
				try common.appendKeyword(&result, allocator, common.kBtrcTag);
				try common.appendUint32(&result, allocator, @intCast(tagstart));
				try common.appendUint32(&result, allocator, @intCast(tagsize));
			}
			if (code == common.kCommandTagXYZ) {
				try common.checkIs32Bit(tagstart + tagsize * 2);
				try common.appendKeyword(&result, allocator, common.kGxyzTag);
				try common.appendUint32(&result, allocator, @intCast(tagstart + tagsize));
				try common.appendUint32(&result, allocator, @intCast(tagsize));
				try common.appendKeyword(&result, allocator, common.kBxyzTag);
				try common.appendUint32(&result, allocator, @intCast(tagstart + tagsize * 2));
				try common.appendUint32(&result, allocator, @intCast(tagsize));
			}
		}
	}

	while (true) {
		if (result.items.len > osize) return error.InvalidResultSize;
		if (cpos > commands_end) return error.OutOfBounds;
		if (cpos == commands_end) break;
		const command = enc[cpos];
		cpos += 1;
		switch (command) {
			common.kCommandInsert => {
				if (cpos >= commands_end) return error.OutOfBounds;
				const num = decodeVarInt(enc, &cpos);
				try common.checkOutOfBounds(pos, num, enc.len);
				try result.appendSlice(allocator, enc[pos .. pos + @as(usize, @intCast(num))]);
				pos += @as(usize, @intCast(num));
			},
			common.kCommandShuffle2, common.kCommandShuffle4 => {
				if (cpos >= commands_end) return error.OutOfBounds;
				const num = decodeVarInt(enc, &cpos);
				try common.checkOutOfBounds(pos, num, enc.len);
				const shuffled = try allocator.alloc(u8, @intCast(num));
				defer allocator.free(shuffled);
				@memcpy(shuffled, enc[pos .. pos + @as(usize, @intCast(num))]);
				if (command == common.kCommandShuffle2) {
					shuffle(shuffled, 2);
				} else {
					shuffle(shuffled, 4);
				}
				try result.appendSlice(allocator, shuffled);
				pos += @as(usize, @intCast(num));
			},
			common.kCommandXYZ => {
				try common.appendKeyword(&result, allocator, common.kXyz_Tag);
				try common.appendUint32(&result, allocator, 0);
				try common.checkOutOfBounds(pos, 12, enc.len);
				try result.appendSlice(allocator, enc[pos .. pos + 12]);
				pos += 12;
			},
			else => {
				if (command >= common.kCommandTypeStartFirst and command < common.kCommandTypeStartFirst + common.kTypeStrings.len) {
					const index = command - common.kCommandTypeStartFirst;
					try common.appendKeyword(&result, allocator, common.kTypeStrings[index]);
					try common.appendUint32(&result, allocator, 0);
				} else {
					return error.Unsupported;
				}
			},
		}
	}

	if (pos != enc.len) return error.NotAllDataUsed;
	if (result.items.len != osize) return error.InvalidResultSize;
	return result.toOwnedSlice(allocator);
}

const testing = std.testing;

test "predictICC and unpredictICC round-trip header-only byte streams" {
	var source: [48]u8 = undefined;
	for (&source, 0..) |*b, i| b.* = @intCast((i * 37 + 11) & 0xFF);

	const encoded = try predictICC(testing.allocator, source[0..]);
	defer testing.allocator.free(encoded);
	try testing.expect(encoded.len > source.len);
	try testing.expectEqual(@as(u8, source.len), encoded[0]);
	try testing.expectEqual(@as(u8, 0), encoded[1]);

	const decoded = try unpredictICC(testing.allocator, encoded);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, source[0..], decoded);
}

test "predictICC and unpredictICC round-trip builtin sRGB ICC via insert fallback" {
	const encoded = try predictICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(encoded);
	try checkPreamble(encoded, encoded.len);

	const decoded = try unpredictICC(testing.allocator, encoded);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, icc_profiles.srgb_builtin_profile[0..], decoded);
}

test "predictICC models builtin sRGB tag table more compactly than insert-only fallback" {
	const insert_only = try predictICCInsertOnlyFallback(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(insert_only);
	const modeled = try predictICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(modeled);
	try testing.expect(modeled.len < insert_only.len);
}

test "predictICC models builtin sRGB body more compactly than tag-table-only fallback" {
	const tag_only = try predictICCTagTableFallback(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(tag_only);
	const modeled = try predictICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(modeled);
	try testing.expect(modeled.len < tag_only.len);
}

test "predictICC models builtin sRGB mluc payload with shuffle2" {
	const body_only = try predictICCBodyStructureFallback(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandShuffle2));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandShuffle2));
}

test "predictICC models builtin sRGB sf32 payload with shuffle4" {
	const body_only = try predictICCBodyStructureFallback(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandShuffle4));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandShuffle4));
}

test "checkPreamble rejects truncated command/data spans" {
	const truncated = [_]u8{
		0x20, // output size
		0x05, // command stream size
		0x01, 0x02, 0x03, // only 3 bytes follow instead of 5
	};
	try testing.expectError(error.OutOfBounds, checkPreamble(truncated[0..], truncated.len));
}

test "checkPreamble rejects implausibly huge decoded sizes" {
	const too_large = [_]u8{
		0x80, 0x80, 0x80, 0x80, 0x01, // 1 << 28
		0x00,
	};
	try testing.expectError(error.DecodedTooLarge, checkPreamble(too_large[0..], too_large.len));
}
