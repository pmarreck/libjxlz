const std = @import("std");
const common = @import("icc_codec_common.zig");
const icc_profiles = @import("icc_profiles.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const BitWriter = @import("../base/bit_writer.zig").BitWriter;
const U64Coder = @import("field_coders.zig").U64Coder;
const ans_common = @import("../entropy/ans_common.zig");
const ans_params = @import("../entropy/ans_params.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const enc_ans = @import("../entropy/enc_ans.zig");
const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;

const kSizeLimit: usize = std.math.maxInt(u32) >> 2;
const kOutputLimit: usize = 1 << 28;
const kICCLogAlphaSize: u5 = 8;
const kICCAlphabetSize: u16 = 256;
const kICCByteUintConfig = HybridUintConfig.init(8, 0, 0);

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
		.model_curv_predict = true,
		.model_gbd_predict = true,
		.model_mab_curv_predict = true,
		.model_mab_clut_predict = true,
	});
}

/// Encodes a raw ICC profile into the JPEG XL compressed-ICC bitstream shape
/// using the modeled predictor plus a first legal ANS layer with one shared
/// flat byte histogram across all 41 ICC contexts.
pub fn compressICC(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	const predicted = try predictICC(allocator, icc);
	defer allocator.free(predicted);

	const flat_counts = try ans_common.createFlatHistogram(allocator, kICCAlphabetSize, ans_params.ans_tab_size);
	defer allocator.free(flat_counts);
	const info = try enc_ans.buildANSEncSymbolInfoTable(allocator, flat_counts, kICCLogAlphaSize);
	defer enc_ans.freeANSEncSymbolInfoTable(allocator, info);

	var tokens: std.ArrayList(enc_ans.Token) = .{};
	defer tokens.deinit(allocator);
	try tokens.ensureTotalCapacity(allocator, predicted.len);
	for (predicted, 0..) |value, i| {
		const b1: u8 = if (i > 0) predicted[i - 1] else 0;
		const b2: u8 = if (i > 1) predicted[i - 2] else 0;
		try tokens.append(allocator, enc_ans.Token.init(@intCast(common.ansContext(i, b1, b2)), value));
	}

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try U64Coder.write(predicted.len, &writer);
	try enc_ans.writeAllZeroContextMapFlatHistogram(common.kNumICCContexts, kICCAlphabetSize, kICCByteUintConfig, kICCLogAlphaSize, &writer);

	const infos = [_][]const enc_ans.ANSEncSymbolInfo{info};
	const context_map = [_]u8{0} ** common.kNumICCContexts;
	const uint_configs = [_]HybridUintConfig{kICCByteUintConfig};
	_ = try enc_ans.writeContextualHistogramTokens(tokens.items, &infos, &context_map, &uint_configs, &writer);
	try writer.zeroPadToByte();
	return allocator.dupe(u8, writer.bytes());
}

/// Decodes the JPEG XL compressed-ICC bitstream back to a raw ICC profile by
/// reading the ANS-coded intermediate bytes and then applying `unpredictICC`.
pub fn decompressICC(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
	var br = BitReader.init(compressed);
	const enc_size = U64Coder.read(&br);
	try common.checkIs32Bit(enc_size);
	if (enc_size >= kOutputLimit) return error.DecodedTooLarge;

	var code = dec_ans.ANSCode.init(allocator);
	defer code.deinit();
	const context_map = try dec_ans.decodeHistograms(allocator, &br, common.kNumICCContexts, &code);
	defer allocator.free(context_map);

	var reader = try dec_ans.ANSSymbolReader.create(&code, &br, 0, allocator);
	defer reader.deinit();

	const predicted = try allocator.alloc(u8, @intCast(enc_size));
	defer allocator.free(predicted);
	for (predicted, 0..) |*byte, i| {
		const b1: u8 = if (i > 0) predicted[i - 1] else 0;
		const b2: u8 = if (i > 1) predicted[i - 2] else 0;
		byte.* = @intCast(reader.readHybridUint(common.ansContext(i, b1, b2), &br, context_map));
	}

	if (!reader.checkANSFinalState()) return error.GenericError;
	try br.jumpToByteBoundary();
	try br.close();
	return unpredictICC(allocator, predicted);
}

fn predictICCInsertOnlyFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = false,
		.model_type_starts = false,
		.model_xyz = false,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
		.model_curv_predict = false,
		.model_gbd_predict = false,
		.model_mab_curv_predict = false,
		.model_mab_clut_predict = false,
	});
}

fn predictICCTagTableFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = true,
		.model_type_starts = false,
		.model_xyz = false,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
		.model_curv_predict = false,
		.model_gbd_predict = false,
		.model_mab_curv_predict = false,
		.model_mab_clut_predict = false,
	});
}

fn predictICCBodyStructureFallback(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	return predictICCImpl(allocator, icc, .{
		.model_tag_list = true,
		.model_type_starts = true,
		.model_xyz = true,
		.model_mluc_shuffle = false,
		.model_sf32_shuffle = false,
		.model_curv_predict = false,
		.model_gbd_predict = false,
		.model_mab_curv_predict = false,
		.model_mab_clut_predict = false,
	});
}

const PredictOptions = struct {
	model_tag_list: bool,
	model_type_starts: bool,
	model_xyz: bool,
	model_mluc_shuffle: bool,
	model_sf32_shuffle: bool,
	model_curv_predict: bool,
	model_gbd_predict: bool,
	model_mab_curv_predict: bool,
	model_mab_clut_predict: bool,
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
			common.kCommandPredict => {
				if (pos >= commands.len) return false;
				const flags = commands[pos];
				pos += 1;
				if ((flags & 16) != 0) _ = decodeVarInt(commands, &pos);
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
	var tag_types = std.AutoHashMap(usize, common.Tag).init(allocator);
	defer tag_types.deinit();
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
				try tag_types.put(@intCast(tagstart), tag);

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
		var current_tag: ?common.Tag = null;
		var current_tag_start: usize = 0;
		var current_tag_size: usize = 0;
		var clut_start: ?usize = null;
		while (pos < icc.len) {
			if (current_tag != null and pos > current_tag_start + current_tag_size) current_tag = null;
			if (tag_types.get(pos)) |tag| {
				current_tag = tag;
				current_tag_start = pos;
				current_tag_size = tag_sizes.get(pos).?;
				clut_start = null;
			}

			if (options.model_mab_curv_predict and current_tag != null and pos + 12 <= icc.len) {
				const outer_tag = current_tag.?;
				if (std.mem.eql(u8, &outer_tag, &common.kMab_Tag) or std.mem.eql(u8, &outer_tag, &common.kMba_Tag)) {
					const sub_tag = common.decodeKeyword(icc, pos);
					if ((std.mem.eql(u8, &sub_tag, &common.kCurvTag) or std.mem.eql(u8, &sub_tag, &common.kVcgtTag)) and
						common.decodeUint32(icc, pos + 4) == 0)
					{
						const num = @as(usize, common.decodeUint32(icc, pos + 8)) * 2;
						if (num > 16 and num < (1 << 28) and pos + 12 + num <= icc.len) {
							const payload_start = pos + 12;
							if (insert_start < payload_start) {
								try commands.append(allocator, common.kCommandInsert);
								try encodeVarInt(&commands, allocator, payload_start - insert_start);
								try data.appendSlice(allocator, icc[insert_start..payload_start]);
							}
							try commands.append(allocator, common.kCommandPredict);
							try commands.append(allocator, (1 << 2) | (2 - 1));
							try encodeVarInt(&commands, allocator, num);
							const start = data.items.len;
							try data.resize(allocator, start + num);
							for (0..num) |i| {
								const predicted = common.linearPredictValue(icc, payload_start, i, 2, 2, 1);
								data.items[start + i] = icc[payload_start + i] -% predicted;
							}
							unshuffle(data.items[start .. start + num], 2);
							pos = payload_start + num;
							insert_start = pos;
							continue;
						}
					}
				}
			}

			if (current_tag != null) {
				const outer_tag = current_tag.?;
				if (std.mem.eql(u8, &outer_tag, &common.kMab_Tag) or std.mem.eql(u8, &outer_tag, &common.kMba_Tag)) {
					if (pos == current_tag_start + 24 and pos + 4 <= icc.len) {
						clut_start = current_tag_start + common.decodeUint32(icc, pos);
					}
					if (options.model_mab_clut_predict and clut_start != null and pos == clut_start.? and clut_start.? + 16 < icc.len) {
						const numi = icc[current_tag_start + 8];
						const numo = icc[current_tag_start + 9];
						const width = icc[clut_start.? + 16];
						const stride = @as(usize, width) * @as(usize, numo);
						var num = stride;
						for (0..numi) |i| {
							num *= icc[clut_start.? + i];
						}
						if ((width == 1 or width == 2) and num > 64 and num < (1 << 28) and pos + num <= icc.len and pos > stride * 4) {
							if (insert_start < pos) {
								try commands.append(allocator, common.kCommandInsert);
								try encodeVarInt(&commands, allocator, pos - insert_start);
								try data.appendSlice(allocator, icc[insert_start..pos]);
							}
							try commands.append(allocator, common.kCommandPredict);
							const order: u8 = 1;
							var flags: u8 = (order << 2) | (width - 1);
							if (stride != width) flags |= 16;
							try commands.append(allocator, flags);
							if ((flags & 16) != 0) try encodeVarInt(&commands, allocator, stride);
							try encodeVarInt(&commands, allocator, num);
							const start = data.items.len;
							try data.resize(allocator, start + num);
							for (0..num) |i| {
								const predicted = common.linearPredictValue(icc, pos, i, stride, width, order);
								data.items[start + i] = icc[pos + i] -% predicted;
							}
							if (width > 1) unshuffle(data.items[start .. start + num], width);
							pos += num;
							insert_start = pos;
							continue;
						}
					}
				}
			}

			if (options.model_gbd_predict and pos >= 8) {
				const sub_tag = common.decodeKeyword(icc, pos - 8);
				const maybe_tag_size = tag_sizes.get(pos - 8);
				if (std.mem.eql(u8, &sub_tag, &common.kGbd_Tag) and
					common.decodeUint32(icc, pos - 4) == 0 and
					maybe_tag_size != null)
				{
					const tag_size = maybe_tag_size.?;
					const num = tag_size - 8;
					if (tag_size >= 8 and pos - 8 + tag_size <= icc.len and pos > 16) {
						if (insert_start < pos) {
							try commands.append(allocator, common.kCommandInsert);
							try encodeVarInt(&commands, allocator, pos - insert_start);
							try data.appendSlice(allocator, icc[insert_start..pos]);
						}
						try commands.append(allocator, common.kCommandPredict);
						try commands.append(allocator, 4 - 1);
						try encodeVarInt(&commands, allocator, num);
						const start = data.items.len;
						try data.resize(allocator, start + num);
						for (0..num) |i| {
							const predicted = common.linearPredictValue(icc, pos, i, 4, 4, 0);
							data.items[start + i] = icc[pos + i] -% predicted;
						}
						unshuffle(data.items[start .. start + num], 4);
						pos += num;
						insert_start = pos;
						continue;
					}
				}
			}

			if (options.model_curv_predict and pos + 8 <= icc.len) {
				const sub_tag = common.decodeKeyword(icc, pos);
				const maybe_tag_size = tag_sizes.get(pos);
				if (std.mem.eql(u8, &sub_tag, &common.kCurvTag) and
					common.decodeUint32(icc, pos + 4) == 0 and
					maybe_tag_size != null)
				{
					const tag_size = maybe_tag_size.?;
					const num = tag_size - 8;
					if (tag_size >= 8 and pos + tag_size <= icc.len and (num & 1) == 0 and num > 16 and pos > 0) {
						if (insert_start < pos) {
							try commands.append(allocator, common.kCommandInsert);
							try encodeVarInt(&commands, allocator, pos - insert_start);
							try data.appendSlice(allocator, icc[insert_start..pos]);
						}
						try commands.append(allocator, @intCast(common.kCommandTypeStartFirst + 5));
						try commands.append(allocator, common.kCommandPredict);
						try commands.append(allocator, (1 << 2) | (2 - 1));
						try encodeVarInt(&commands, allocator, num);
						const payload_start = pos + 8;
						const start = data.items.len;
						try data.resize(allocator, start + num);
						for (0..num) |i| {
							const predicted = common.linearPredictValue(icc, payload_start, i, 2, 2, 1);
							data.items[start + i] = icc[payload_start + i] -% predicted;
						}
						unshuffle(data.items[start .. start + num], 2);
						pos += tag_size;
						insert_start = pos;
						continue;
					}
				}
			}

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
				var matched = false;
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
						matched = true;
						break;
					}
				}
				if (matched) continue;
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
			common.kCommandPredict => {
				try common.checkOutOfBounds(cpos, 2, commands_end);
				const flags = enc[cpos];
				cpos += 1;

				const width = (flags & 3) + 1;
				if (width == 3) return error.InvalidWidth;
				const order = (flags & 12) >> 2;
				if (order == 3) return error.InvalidOrder;

				var stride: u64 = width;
				if ((flags & 16) != 0) {
					if (cpos >= commands_end) return error.OutOfBounds;
					stride = decodeVarInt(enc, &cpos);
					if (stride < width) return error.InvalidStride;
				}
				if (result.items.len == 0 or ((result.items.len - 1) >> 2) < stride) return error.InvalidStride;

				if (cpos >= commands_end) return error.OutOfBounds;
				const num = decodeVarInt(enc, &cpos);
				try common.checkOutOfBounds(pos, num, enc.len);

				const shuffled = try allocator.alloc(u8, @intCast(num));
				defer allocator.free(shuffled);
				@memcpy(shuffled, enc[pos .. pos + @as(usize, @intCast(num))]);
				if (width > 1) shuffle(shuffled, width);

				const start = result.items.len;
				for (0..@as(usize, @intCast(num))) |idx| {
					const predicted = common.linearPredictValue(result.items, start, idx, @intCast(stride), width, order);
					try result.append(allocator, predicted +% shuffled[idx]);
				}
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

fn makeSyntheticCurvPredictProfile(allocator: std.mem.Allocator) ![]u8 {
	var bytes: std.ArrayList(u8) = .{};
	errdefer bytes.deinit(allocator);
	const total_size: u32 = 128 + 4 + 12 + 28;
	try bytes.appendSlice(allocator, &common.initialHeaderPrediction(total_size));
	try common.appendUint32(&bytes, allocator, 1);
	try common.appendKeyword(&bytes, allocator, common.kRtrcTag);
	try common.appendUint32(&bytes, allocator, 144);
	try common.appendUint32(&bytes, allocator, 28);
	try common.appendKeyword(&bytes, allocator, common.kCurvTag);
	try common.appendUint32(&bytes, allocator, 0);
	const payload = [_]u8{
		0x00, 0x10, 0x00, 0x20, 0x00, 0x35, 0x00, 0x50, 0x00, 0x70,
		0x00, 0x95, 0x00, 0xBF, 0x00, 0xEE, 0x01, 0x22, 0x01, 0x5B,
	};
	try bytes.appendSlice(allocator, payload[0..]);
	return bytes.toOwnedSlice(allocator);
}

fn makeSyntheticGbdPredictProfile(allocator: std.mem.Allocator) ![]u8 {
	var bytes: std.ArrayList(u8) = .{};
	errdefer bytes.deinit(allocator);
	const total_size: u32 = 128 + 4 + 12 + 32;
	try bytes.appendSlice(allocator, &common.initialHeaderPrediction(total_size));
	try common.appendUint32(&bytes, allocator, 1);
	try common.appendKeyword(&bytes, allocator, common.kGbd_Tag);
	try common.appendUint32(&bytes, allocator, 144);
	try common.appendUint32(&bytes, allocator, 32);
	try common.appendKeyword(&bytes, allocator, common.kGbd_Tag);
	try common.appendUint32(&bytes, allocator, 0);
	const payload = [_]u8{
		0x00, 0x10, 0x20, 0x30,
		0x00, 0x10, 0x20, 0x34,
		0x00, 0x10, 0x20, 0x38,
		0x00, 0x10, 0x20, 0x3C,
		0x00, 0x10, 0x20, 0x40,
		0x00, 0x10, 0x20, 0x44,
	};
	try bytes.appendSlice(allocator, payload[0..]);
	return bytes.toOwnedSlice(allocator);
}

fn makeSyntheticMabCurvPredictProfile(allocator: std.mem.Allocator) ![]u8 {
	var bytes: std.ArrayList(u8) = .{};
	errdefer bytes.deinit(allocator);
	const total_size: u32 = 128 + 4 + 12 + 40;
	try bytes.appendSlice(allocator, &common.initialHeaderPrediction(total_size));
	try common.appendUint32(&bytes, allocator, 1);
	try common.appendKeyword(&bytes, allocator, common.kMab_Tag);
	try common.appendUint32(&bytes, allocator, 144);
	try common.appendUint32(&bytes, allocator, 40);
	try common.appendKeyword(&bytes, allocator, common.kMab_Tag);
	try common.appendUint32(&bytes, allocator, 0);
	try common.appendKeyword(&bytes, allocator, common.kCurvTag);
	try common.appendUint32(&bytes, allocator, 0);
	try common.appendUint32(&bytes, allocator, 10);
	const payload = [_]u8{
		0x00, 0x10, 0x00, 0x20, 0x00, 0x35, 0x00, 0x50, 0x00, 0x70,
		0x00, 0x95, 0x00, 0xBF, 0x00, 0xEE, 0x01, 0x22, 0x01, 0x5B,
	};
	try bytes.appendSlice(allocator, payload[0..]);
	return bytes.toOwnedSlice(allocator);
}

fn makeSyntheticMbaVcgtPredictProfile(allocator: std.mem.Allocator) ![]u8 {
	var bytes: std.ArrayList(u8) = .{};
	errdefer bytes.deinit(allocator);
	const total_size: u32 = 128 + 4 + 12 + 40;
	try bytes.appendSlice(allocator, &common.initialHeaderPrediction(total_size));
	try common.appendUint32(&bytes, allocator, 1);
	try common.appendKeyword(&bytes, allocator, common.kMba_Tag);
	try common.appendUint32(&bytes, allocator, 144);
	try common.appendUint32(&bytes, allocator, 40);
	try common.appendKeyword(&bytes, allocator, common.kMba_Tag);
	try common.appendUint32(&bytes, allocator, 0);
	try common.appendKeyword(&bytes, allocator, common.kVcgtTag);
	try common.appendUint32(&bytes, allocator, 0);
	try common.appendUint32(&bytes, allocator, 10);
	const payload = [_]u8{
		0x00, 0x12, 0x00, 0x24, 0x00, 0x39, 0x00, 0x52, 0x00, 0x74,
		0x00, 0x99, 0x00, 0xC1, 0x00, 0xF0, 0x01, 0x26, 0x01, 0x60,
	};
	try bytes.appendSlice(allocator, payload[0..]);
	return bytes.toOwnedSlice(allocator);
}

fn makeSyntheticMabClutPredictProfile(allocator: std.mem.Allocator) ![]u8 {
	var bytes: std.ArrayList(u8) = .{};
	errdefer bytes.deinit(allocator);
	const total_size: u32 = 128 + 4 + 12 + 112;
	try bytes.appendSlice(allocator, &common.initialHeaderPrediction(total_size));
	try common.appendUint32(&bytes, allocator, 1);
	try common.appendKeyword(&bytes, allocator, common.kMab_Tag);
	try common.appendUint32(&bytes, allocator, 144);
	try common.appendUint32(&bytes, allocator, 112);
	try common.appendKeyword(&bytes, allocator, common.kMab_Tag);
	try common.appendUint32(&bytes, allocator, 0);
	try bytes.appendSlice(allocator, &[_]u8{
		1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	});
	try common.appendUint32(&bytes, allocator, 32);
	try bytes.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
	var payload: [80]u8 = undefined;
	for (&payload, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xFF);
	payload[0] = 80;
	payload[16] = 1;
	try bytes.appendSlice(allocator, payload[0..]);
	return bytes.toOwnedSlice(allocator);
}

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

test "predictICC emits first predict command for synthetic curv payload and round-trips exactly" {
	const profile = try makeSyntheticCurvPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const body_only = try predictICCBodyStructureFallback(testing.allocator, profile);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, profile);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandPredict));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandPredict));

	const decoded = try unpredictICC(testing.allocator, modeled);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, profile, decoded);
}

test "predictICC emits predict for synthetic gbd payload and round-trips exactly" {
	const profile = try makeSyntheticGbdPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const body_only = try predictICCBodyStructureFallback(testing.allocator, profile);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, profile);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandPredict));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandPredict));

	const decoded = try unpredictICC(testing.allocator, modeled);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, profile, decoded);
}

test "predictICC emits predict for synthetic mAB nested curv payload and round-trips exactly" {
	const profile = try makeSyntheticMabCurvPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const body_only = try predictICCBodyStructureFallback(testing.allocator, profile);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, profile);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandPredict));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandPredict));

	const decoded = try unpredictICC(testing.allocator, modeled);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, profile, decoded);
}

test "predictICC emits predict for synthetic mBA nested vcgt payload and round-trips exactly" {
	const profile = try makeSyntheticMbaVcgtPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const body_only = try predictICCBodyStructureFallback(testing.allocator, profile);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, profile);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandPredict));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandPredict));

	const decoded = try unpredictICC(testing.allocator, modeled);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, profile, decoded);
}

test "predictICC emits predict for synthetic mAB CLUT payload and round-trips exactly" {
	const profile = try makeSyntheticMabClutPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const body_only = try predictICCBodyStructureFallback(testing.allocator, profile);
	defer testing.allocator.free(body_only);
	const modeled = try predictICC(testing.allocator, profile);
	defer testing.allocator.free(modeled);
	try testing.expect(!bodyCommandsContain(body_only, common.kCommandPredict));
	try testing.expect(bodyCommandsContain(modeled, common.kCommandPredict));

	const decoded = try unpredictICC(testing.allocator, modeled);
	defer testing.allocator.free(decoded);
	try testing.expectEqualSlices(u8, profile, decoded);
}

test "compressICC and decompressICC round-trip builtin sRGB profile" {
	const compressed = try compressICC(testing.allocator, icc_profiles.srgb_builtin_profile[0..]);
	defer testing.allocator.free(compressed);

	const decompressed = try decompressICC(testing.allocator, compressed);
	defer testing.allocator.free(decompressed);
	try testing.expectEqualSlices(u8, icc_profiles.srgb_builtin_profile[0..], decompressed);
}

test "compressICC and decompressICC round-trip synthetic mAB CLUT profile" {
	const profile = try makeSyntheticMabClutPredictProfile(testing.allocator);
	defer testing.allocator.free(profile);

	const compressed = try compressICC(testing.allocator, profile);
	defer testing.allocator.free(compressed);

	const decompressed = try decompressICC(testing.allocator, compressed);
	defer testing.allocator.free(decompressed);
	try testing.expectEqualSlices(u8, profile, decompressed);
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
