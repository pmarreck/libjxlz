const std = @import("std");

// --- Loads ---

pub fn loadLE16(p: *const [2]u8) u16 {
	return std.mem.readInt(u16, p, .little);
}

pub fn loadBE16(p: *const [2]u8) u16 {
	return std.mem.readInt(u16, p, .big);
}

pub fn loadLE32(p: *const [4]u8) u32 {
	return std.mem.readInt(u32, p, .little);
}

pub fn loadBE32(p: *const [4]u8) u32 {
	return std.mem.readInt(u32, p, .big);
}

pub fn loadLE64(p: *const [8]u8) u64 {
	return std.mem.readInt(u64, p, .little);
}

pub fn loadBE64(p: *const [8]u8) u64 {
	return std.mem.readInt(u64, p, .big);
}

// --- Stores ---

pub fn storeLE16(value: u16, p: *[2]u8) void {
	std.mem.writeInt(u16, p, value, .little);
}

pub fn storeBE16(value: u16, p: *[2]u8) void {
	std.mem.writeInt(u16, p, value, .big);
}

pub fn storeLE32(value: u32, p: *[4]u8) void {
	std.mem.writeInt(u32, p, value, .little);
}

pub fn storeBE32(value: u32, p: *[4]u8) void {
	std.mem.writeInt(u32, p, value, .big);
}

pub fn storeLE64(value: u64, p: *[8]u8) void {
	std.mem.writeInt(u64, p, value, .little);
}

pub fn storeBE64(value: u64, p: *[8]u8) void {
	std.mem.writeInt(u64, p, value, .big);
}

// --- Float loads ---

/// Load a little-endian IEEE 754 float from bytes.
pub fn loadLEFloat(p: *const [4]u8) f32 {
	const bits = loadLE32(p);
	return @bitCast(bits);
}

/// Load a big-endian IEEE 754 float from bytes.
pub fn loadBEFloat(p: *const [4]u8) f32 {
	const bits = loadBE32(p);
	return @bitCast(bits);
}

/// Byte-swap a float value.
pub fn bswapFloat(x: f32) f32 {
	const bits: u32 = @bitCast(x);
	const swapped = @byteSwap(bits);
	return @bitCast(swapped);
}

// --- Tests ---

test "load/store LE16 round-trip" {
	var buf: [2]u8 = undefined;
	storeLE16(0x1234, &buf);
	try std.testing.expectEqual(@as(u16, 0x1234), loadLE16(&buf));
}

test "load/store BE16 round-trip" {
	var buf: [2]u8 = undefined;
	storeBE16(0x1234, &buf);
	try std.testing.expectEqual(@as(u16, 0x1234), loadBE16(&buf));
}

test "load/store LE32 round-trip" {
	var buf: [4]u8 = undefined;
	storeLE32(0xDEADBEEF, &buf);
	try std.testing.expectEqual(@as(u32, 0xDEADBEEF), loadLE32(&buf));
}

test "load/store BE32 round-trip" {
	var buf: [4]u8 = undefined;
	storeBE32(0xDEADBEEF, &buf);
	try std.testing.expectEqual(@as(u32, 0xDEADBEEF), loadBE32(&buf));
}

test "load/store LE64 round-trip" {
	var buf: [8]u8 = undefined;
	storeLE64(0x0102030405060708, &buf);
	try std.testing.expectEqual(@as(u64, 0x0102030405060708), loadLE64(&buf));
}

test "load/store BE64 round-trip" {
	var buf: [8]u8 = undefined;
	storeBE64(0x0102030405060708, &buf);
	try std.testing.expectEqual(@as(u64, 0x0102030405060708), loadBE64(&buf));
}

test "endianness byte order" {
	// LE16: least significant byte first
	var buf16: [2]u8 = undefined;
	storeLE16(0x0102, &buf16);
	try std.testing.expectEqual(@as(u8, 0x02), buf16[0]);
	try std.testing.expectEqual(@as(u8, 0x01), buf16[1]);

	// BE16: most significant byte first
	storeBE16(0x0102, &buf16);
	try std.testing.expectEqual(@as(u8, 0x01), buf16[0]);
	try std.testing.expectEqual(@as(u8, 0x02), buf16[1]);
}

test "loadLEFloat / loadBEFloat with IEEE 754 1.0" {
	// IEEE 754 1.0f = 0x3F800000
	var le_buf: [4]u8 = undefined;
	storeLE32(0x3F800000, &le_buf);
	try std.testing.expectEqual(@as(f32, 1.0), loadLEFloat(&le_buf));

	var be_buf: [4]u8 = undefined;
	storeBE32(0x3F800000, &be_buf);
	try std.testing.expectEqual(@as(f32, 1.0), loadBEFloat(&be_buf));
}

test "bswapFloat" {
	const one: f32 = 1.0;
	const swapped = bswapFloat(one);
	const back = bswapFloat(swapped);
	try std.testing.expectEqual(one, back);
}
