const std = @import("std");
const common = @import("icc_codec_common.zig");

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
/// This first slice only targets header-only streams so the shared predictor
/// path can be proven before tag/content commands are added.
pub fn predictICC(allocator: std.mem.Allocator, icc: []const u8) ![]u8 {
	if (icc.len > kSizeLimit) return error.ProfileTooLarge;

	var result: std.ArrayList(u8) = .{};
	errdefer result.deinit(allocator);
	try encodeVarInt(&result, allocator, icc.len);

	var header = common.initialHeaderPrediction(@intCast(icc.len));
	var data: std.ArrayList(u8) = .{};
	defer data.deinit(allocator);
	for (0..@min(icc.len, common.kICCHeaderSize)) |i| {
		common.predictHeader(icc, &header, i);
		try data.append(allocator, icc[i] -% header[i]);
	}

	if (icc.len <= common.kICCHeaderSize) {
		try encodeVarInt(&result, allocator, 0);
		try result.appendSlice(allocator, data.items);
		return result.toOwnedSlice(allocator);
	}

	return error.Unsupported;
}

/// Reconstructs raw ICC bytes from the JPEG XL compressed-ICC intermediate
/// form. This first slice only supports the zero-command header-only subset.
pub fn unpredictICC(allocator: std.mem.Allocator, enc: []const u8) ![]u8 {
	var pos: usize = 0;
	if (pos >= enc.len) return error.OutOfBounds;
	const osize = decodeVarInt(enc, &pos);
	try common.checkIs32Bit(osize);
	if (osize >= kOutputLimit) return error.DecodedTooLarge;
	if (pos >= enc.len) return error.OutOfBounds;
	const csize = decodeVarInt(enc, &pos);
	try common.checkIs32Bit(csize);
	const cpos = pos;
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

	return error.Unsupported;
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
