const std = @import("std");

pub const kICCHeaderSize: usize = 128;
pub const Tag = [4]u8;

pub const kAcspTag: Tag = .{ 'a', 'c', 's', 'p' };
pub const kBkptTag: Tag = .{ 'b', 'k', 'p', 't' };
pub const kBtrcTag: Tag = .{ 'b', 'T', 'R', 'C' };
pub const kBxyzTag: Tag = .{ 'b', 'X', 'Y', 'Z' };
pub const kChadTag: Tag = .{ 'c', 'h', 'a', 'd' };
pub const kChrmTag: Tag = .{ 'c', 'h', 'r', 'm' };
pub const kCprtTag: Tag = .{ 'c', 'p', 'r', 't' };
pub const kCurvTag: Tag = .{ 'c', 'u', 'r', 'v' };
pub const kDescTag: Tag = .{ 'd', 'e', 's', 'c' };
pub const kDmddTag: Tag = .{ 'd', 'm', 'd', 'd' };
pub const kDmndTag: Tag = .{ 'd', 'm', 'n', 'd' };
pub const kGbd_Tag: Tag = .{ 'g', 'b', 'd', ' ' };
pub const kGtrcTag: Tag = .{ 'g', 'T', 'R', 'C' };
pub const kGxyzTag: Tag = .{ 'g', 'X', 'Y', 'Z' };
pub const kKtrcTag: Tag = .{ 'k', 'T', 'R', 'C' };
pub const kKxyzTag: Tag = .{ 'k', 'X', 'Y', 'Z' };
pub const kLumiTag: Tag = .{ 'l', 'u', 'm', 'i' };
pub const kMab_Tag: Tag = .{ 'm', 'A', 'B', ' ' };
pub const kMba_Tag: Tag = .{ 'm', 'B', 'A', ' ' };
pub const kMlucTag: Tag = .{ 'm', 'l', 'u', 'c' };
pub const kMntrTag: Tag = .{ 'm', 'n', 't', 'r' };
pub const kParaTag: Tag = .{ 'p', 'a', 'r', 'a' };
pub const kRgb_Tag: Tag = .{ 'R', 'G', 'B', ' ' };
pub const kRtrcTag: Tag = .{ 'r', 'T', 'R', 'C' };
pub const kRxyzTag: Tag = .{ 'r', 'X', 'Y', 'Z' };
pub const kSf32Tag: Tag = .{ 's', 'f', '3', '2' };
pub const kTextTag: Tag = .{ 't', 'e', 'x', 't' };
pub const kVcgtTag: Tag = .{ 'v', 'c', 'g', 't' };
pub const kWtptTag: Tag = .{ 'w', 't', 'p', 't' };
pub const kXyz_Tag: Tag = .{ 'X', 'Y', 'Z', ' ' };

pub const kTagStrings = [_]Tag{
	kCprtTag, kWtptTag, kBkptTag, kRxyzTag, kGxyzTag, kBxyzTag, kKxyzTag, kRtrcTag, kGtrcTag,
	kBtrcTag, kKtrcTag, kChadTag, kDescTag, kChrmTag, kDmndTag, kDmddTag, kLumiTag,
};

pub const kCommandTagUnknown: usize = 1;
pub const kCommandTagTRC: usize = 2;
pub const kCommandTagXYZ: usize = 3;
pub const kCommandTagStringFirst: usize = 4;

pub const kTypeStrings = [_]Tag{
	kXyz_Tag, kDescTag, kTextTag, kMlucTag, kParaTag, kCurvTag, kSf32Tag, kGbd_Tag,
};

pub const kCommandInsert: usize = 1;
pub const kCommandShuffle2: usize = 2;
pub const kCommandShuffle4: usize = 3;
pub const kCommandPredict: usize = 4;
pub const kCommandXYZ: usize = 10;
pub const kCommandTypeStartFirst: usize = 16;

pub const kFlagBitOffset: usize = 64;
pub const kFlagBitSize: usize = 128;

pub const kNumICCContexts: usize = 41;

fn byteKind1(b: u8) u8 {
	if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')) return 0;
	if ((b >= '0' and b <= '9') or b == '.' or b == ',') return 1;
	if (b == 0) return 2;
	if (b == 1) return 3;
	if (b < 16) return 4;
	if (b == 255) return 6;
	if (b > 240) return 5;
	return 7;
}

fn byteKind2(b: u8) u8 {
	if ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z')) return 0;
	if ((b >= '0' and b <= '9') or b == '.' or b == ',') return 1;
	if (b < 16) return 2;
	if (b > 240) return 3;
	return 4;
}

fn predictValue(comptime T: type, p1: T, p2: T, p3: T, order: i32) T {
	return switch (order) {
		0 => p1,
		1 => 2 *% p1 -% p2,
		2 => 3 *% p1 -% 3 *% p2 +% p3,
		else => 0,
	};
}

/// Reads a big-endian 32-bit value from a byte slice, returning zero on
/// out-of-bounds access so malformed ICC parsing can stay total and testable.
pub fn decodeUint32(data: []const u8, pos: usize) u32 {
	if (pos + 4 > data.len) return 0;
	return std.mem.readInt(u32, @ptrCast(data[pos .. pos + 4]), .big);
}

/// Appends one big-endian 32-bit value to an owned byte buffer for ICC
/// command/tag assembly without open-coded endian writes at call sites.
pub fn appendUint32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
	var buf: [4]u8 = undefined;
	std.mem.writeInt(u32, &buf, value, .big);
	try bytes.appendSlice(allocator, buf[0..]);
}

/// Decodes a four-byte ICC tag keyword or returns a space-filled sentinel when
/// out of bounds, matching upstream's forgiving raw-byte inspection behavior.
pub fn decodeKeyword(data: []const u8, pos: usize) Tag {
	if (pos + 4 > data.len) return .{ ' ', ' ', ' ', ' ' };
	return .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
}

/// Writes one four-byte ICC tag keyword into a caller-owned buffer when space
/// is available, keeping malformed writes as harmless no-ops.
pub fn encodeKeyword(keyword: Tag, data: []u8, pos: usize) void {
	if (pos + 4 > data.len) return;
	@memcpy(data[pos .. pos + 4], keyword[0..]);
}

/// Appends one four-byte ICC tag keyword to an owned byte buffer for compact
/// command/data stream construction during ICC codec assembly.
pub fn appendKeyword(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, keyword: Tag) !void {
	try bytes.appendSlice(allocator, keyword[0..]);
}

/// Detects `a + b > size`, including wraparound, so ICC codec range checks stay
/// explicit and deterministic instead of relying on unchecked integer math.
pub fn checkOutOfBounds(a: u64, b: u64, size: u64) !void {
	const pos = a +% b;
	if (pos > size or pos < a) return error.OutOfBounds;
}

/// Rejects values that do not fit in 32 bits, which is the ICC codec's byte
/// addressing domain for tag tables and decoded profile sizes.
pub fn checkIs32Bit(v: u64) !void {
	if (v & ~@as(u64, 0xFFFF_FFFF) != 0) return error.Expected32BitValue;
}

const kIccInitialHeaderPrediction = [kICCHeaderSize]u8{
	0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 'm', 'n', 't', 'r',
	'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ', 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 'a', 'c', 's', 'p', 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 246, 214, 0, 1, 0, 0, 0, 0, 211, 45,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/// Produces the default 128-byte ICC header predictor with only the file-size
/// field specialized, which is the codec's fixed baseline before local tweaks.
pub fn initialHeaderPrediction(size: u32) [kICCHeaderSize]u8 {
	var copy = kIccInitialHeaderPrediction;
	std.mem.writeInt(u32, copy[0..4], size, .big);
	return copy;
}

/// Adjusts the running ICC header predictor using earlier decoded header bytes,
/// mirroring the upstream APPL/MSFT/SGI/SUNW special cases.
pub fn predictHeader(icc: []const u8, header: *[kICCHeaderSize]u8, pos: usize) void {
	if (pos == 8 and icc.len >= 8) {
		header[80] = icc[4];
		header[81] = icc[5];
		header[82] = icc[6];
		header[83] = icc[7];
	}
	if (pos == 41 and icc.len >= 41) {
		if (icc[40] == 'A') {
			header[41] = 'P';
			header[42] = 'P';
			header[43] = 'L';
		}
		if (icc[40] == 'M') {
			header[41] = 'S';
			header[42] = 'F';
			header[43] = 'T';
		}
	}
	if (pos == 42 and icc.len >= 42) {
		if (icc[40] == 'S' and icc[41] == 'G') {
			header[42] = 'I';
			header[43] = ' ';
		}
		if (icc[40] == 'S' and icc[41] == 'U') {
			header[42] = 'N';
			header[43] = 'W';
		}
	}
}

/// Predicts one byte from prior ICC data using the codec's width-aware linear
/// model over 1-, 2-, or 4-byte lanes for better entropy coding.
pub fn linearPredictValue(data: []const u8, start: usize, i: usize, stride: usize, width: usize, order: i32) u8 {
	const pos = start + i;
	if (width == 1) {
		const p1 = data[pos - stride];
		const p2 = data[pos - stride * 2];
		const p3 = data[pos - stride * 3];
		return predictValue(u8, p1, p2, p3, order);
	}
	if (width == 2) {
		const p = start + (i & ~@as(usize, 1));
		const p1 = (@as(u16, data[p - stride]) << 8) | data[p - stride + 1];
		const p2 = (@as(u16, data[p - stride * 2]) << 8) | data[p - stride * 2 + 1];
		const p3 = (@as(u16, data[p - stride * 3]) << 8) | data[p - stride * 3 + 1];
		const pred = predictValue(u16, p1, p2, p3, order);
		return if ((i & 1) == 1) @intCast(pred & 0xFF) else @intCast((pred >> 8) & 0xFF);
	}
	const p = start + (i & ~@as(usize, 3));
	const p1 = decodeUint32(data[0..pos], p - stride);
	const p2 = decodeUint32(data[0..pos], p - stride * 2);
	const p3 = decodeUint32(data[0..pos], p - stride * 3);
	const pred = predictValue(u32, p1, p2, p3, order);
	const shiftbytes: u5 = @intCast((3 - (i & 3)) * 8);
	return @intCast((pred >> shiftbytes) & 0xFF);
}

/// Maps neighboring encoded bytes into one of the ICC codec's 41 ANS contexts,
/// separating early header bytes from later textual/numeric/binary mixtures.
pub fn ansContext(i: usize, b1: u8, b2: u8) usize {
	if (i <= 128) return 0;
	return 1 + byteKind1(b1) + byteKind2(b2) * 8;
}

const testing = std.testing;

test "decodeUint32 and appendUint32 round-trip big-endian values" {
	var bytes: std.ArrayList(u8) = .{};
	defer bytes.deinit(testing.allocator);
	try appendUint32(&bytes, testing.allocator, 0x1234_5678);
	try appendUint32(&bytes, testing.allocator, 0xAABB_CCDD);
	try testing.expectEqual(@as(usize, 8), bytes.items.len);
	try testing.expectEqual(@as(u32, 0x1234_5678), decodeUint32(bytes.items, 0));
	try testing.expectEqual(@as(u32, 0xAABB_CCDD), decodeUint32(bytes.items, 4));
	try testing.expectEqual(@as(u32, 0), decodeUint32(bytes.items, 5));
}

test "keyword helpers round-trip tags and tolerate out-of-bounds" {
	var bytes = [_]u8{ 0, 0, 0, 0, 0, 0 };
	encodeKeyword(kAcspTag, bytes[0..], 1);
	try testing.expectEqualSlices(u8, "acsp", bytes[1..5]);
	try testing.expectEqual(kAcspTag, decodeKeyword(bytes[0..], 1));
	try testing.expectEqual(Tag{ ' ', ' ', ' ', ' ' }, decodeKeyword(bytes[0..], 3));

	var out: std.ArrayList(u8) = .{};
	defer out.deinit(testing.allocator);
	try appendKeyword(&out, testing.allocator, kDescTag);
	try testing.expectEqualSlices(u8, "desc", out.items);
}

test "checkOutOfBounds and checkIs32Bit reject invalid ranges" {
	try checkOutOfBounds(4, 8, 12);
	try testing.expectError(error.OutOfBounds, checkOutOfBounds(5, 8, 12));
	try testing.expectError(error.OutOfBounds, checkOutOfBounds(std.math.maxInt(u64), 1, std.math.maxInt(u64)));
	try checkIs32Bit(0xFFFF_FFFF);
	try testing.expectError(error.Expected32BitValue, checkIs32Bit(0x1_0000_0000));
}

test "initialHeaderPrediction and predictHeader follow upstream ICC header tweaks" {
	var header = initialHeaderPrediction(0x0102_0304);
	try testing.expectEqual(@as(u8, 0x01), header[0]);
	try testing.expectEqual(@as(u8, 0x02), header[1]);
	try testing.expectEqual(@as(u8, 0x03), header[2]);
	try testing.expectEqual(@as(u8, 0x04), header[3]);
	try testing.expectEqualSlices(u8, "mntrRGB XYZ ", header[12..24]);

	const appl = [_]u8{ 0, 0, 0, 0, 1, 2, 3, 4 } ++ [_]u8{0} ** 32 ++ [_]u8{ 'A' };
	predictHeader(appl[0..], &header, 8);
	try testing.expectEqual(@as(u8, 1), header[80]);
	try testing.expectEqual(@as(u8, 2), header[81]);
	try testing.expectEqual(@as(u8, 3), header[82]);
	try testing.expectEqual(@as(u8, 4), header[83]);
	predictHeader(appl[0..], &header, 41);
	try testing.expectEqual(@as(u8, 0), header[40]);
	try testing.expectEqualSlices(u8, "PPL", header[41..44]);

	var sgi_header = initialHeaderPrediction(0x0102_0304);
	const sgi = [_]u8{ 0, 0, 0, 0 } ++ [_]u8{0} ** 36 ++ [_]u8{ 'S', 'G' };
	predictHeader(sgi[0..], &sgi_header, 42);
	try testing.expectEqual(@as(u8, 0), sgi_header[40]);
	try testing.expectEqual(@as(u8, 0), sgi_header[41]);
	try testing.expectEqual(@as(u8, 'I'), sgi_header[42]);
	try testing.expectEqual(@as(u8, ' '), sgi_header[43]);
}

test "linearPredictValue matches width-1 width-2 and width-4 lanes" {
	const bytes1 = [_]u8{ 10, 20, 30, 40, 50 };
	try testing.expectEqual(@as(u8, 40), linearPredictValue(bytes1[0..], 4, 0, 1, 1, 0));

	const bytes2 = [_]u8{
		0x00, 0x10,
		0x00, 0x20,
		0x00, 0x30,
		0x00, 0x40,
	};
	try testing.expectEqual(@as(u8, 0x00), linearPredictValue(bytes2[0..], 6, 0, 2, 2, 0));
	try testing.expectEqual(@as(u8, 0x30), linearPredictValue(bytes2[0..], 6, 1, 2, 2, 0));

	const bytes4 = [_]u8{
		0x00, 0x00, 0x00, 0x10,
		0x00, 0x00, 0x00, 0x20,
		0x00, 0x00, 0x00, 0x30,
		0x00, 0x00, 0x00, 0x40,
	};
	try testing.expectEqual(@as(u8, 0x00), linearPredictValue(bytes4[0..], 12, 0, 4, 4, 0));
	try testing.expectEqual(@as(u8, 0x30), linearPredictValue(bytes4[0..], 12, 3, 4, 4, 0));
}

test "ansContext preserves header context and classifies later bytes" {
	try testing.expectEqual(@as(usize, 0), ansContext(12, 'A', 'B'));
	const ctx_alpha = ansContext(129, 'A', 'Z');
	const ctx_num = ansContext(129, '9', '.');
	const ctx_zero = ansContext(129, 0, 0);
	try testing.expect(ctx_alpha != ctx_num);
	try testing.expect(ctx_zero != ctx_alpha);
	try testing.expectEqual(@as(usize, 1), ansContext(129, 'A', 'A'));
}
