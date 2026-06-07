const std = @import("std");

pub const JxlDataType = enum(c_int) {
	JXL_TYPE_FLOAT = 0,
	JXL_TYPE_UINT8 = 2,
	JXL_TYPE_UINT16 = 3,
	JXL_TYPE_FLOAT16 = 5,
};

pub const JxlEndianness = enum(c_int) {
	JXL_NATIVE_ENDIAN = 0,
	JXL_LITTLE_ENDIAN = 1,
	JXL_BIG_ENDIAN = 2,
};

pub const JxlPixelFormat = extern struct {
	num_channels: u32,
	data_type: JxlDataType,
	endianness: JxlEndianness,
	@"align": usize,
};

/// Maps the public C pixel sample type to its byte width so C API buffer sizing
/// and output packing share one libjxl-shaped contract.
pub fn bytesPerChannel(data_type: JxlDataType) ?usize {
	return switch (data_type) {
		.JXL_TYPE_UINT8 => 1,
		.JXL_TYPE_UINT16, .JXL_TYPE_FLOAT16 => 2,
		.JXL_TYPE_FLOAT => 4,
	};
}

/// Converts pixel-format alignment into a concrete row stride so callers can
/// size and write output buffers exactly like libjxl's image buffer API.
pub fn rowStrideBytes(width: usize, format: JxlPixelFormat) ?usize {
	const bytes_per_channel = bytesPerChannel(format.data_type) orelse return null;
	const row_bytes = width * format.num_channels * bytes_per_channel;
	const row_align = if (format.@"align" <= 1) 1 else format.@"align";
	return roundUpTo(row_bytes, row_align);
}

/// Stores 16-bit C API samples in the requested byte order, resolving native
/// endianness once so output-buffer code does not duplicate byte-swap logic.
pub fn storeU16(dst: []u8, endianness: JxlEndianness, value: u16) void {
	const actual = switch (endianness) {
		.JXL_NATIVE_ENDIAN => if (builtinEndian() == .little) JxlEndianness.JXL_LITTLE_ENDIAN else JxlEndianness.JXL_BIG_ENDIAN,
		else => endianness,
	};
	var raw: [2]u8 = undefined;
	switch (actual) {
		.JXL_LITTLE_ENDIAN => std.mem.writeInt(u16, &raw, value, .little),
		.JXL_BIG_ENDIAN => std.mem.writeInt(u16, &raw, value, .big),
		else => unreachable,
	}
	@memcpy(dst[0..2], &raw);
}

/// Stores 32-bit C API samples in the requested byte order, including float
/// bit patterns that are already represented as raw u32 values by callers.
pub fn storeU32(dst: []u8, endianness: JxlEndianness, value: u32) void {
	const actual = switch (endianness) {
		.JXL_NATIVE_ENDIAN => if (builtinEndian() == .little) JxlEndianness.JXL_LITTLE_ENDIAN else JxlEndianness.JXL_BIG_ENDIAN,
		else => endianness,
	};
	var raw: [4]u8 = undefined;
	switch (actual) {
		.JXL_LITTLE_ENDIAN => std.mem.writeInt(u32, &raw, value, .little),
		.JXL_BIG_ENDIAN => std.mem.writeInt(u32, &raw, value, .big),
		else => unreachable,
	}
	@memcpy(dst[0..4], &raw);
}

pub fn builtinEndian() std.builtin.Endian {
	return @import("builtin").target.cpu.arch.endian();
}

/// Loads 16-bit C API samples from caller-declared byte order so input staging
/// can normalize public buffers before handing them to narrower codec internals.
pub fn loadU16(src: []const u8, endianness: JxlEndianness) u16 {
	const actual = switch (endianness) {
		.JXL_NATIVE_ENDIAN => if (builtinEndian() == .little) JxlEndianness.JXL_LITTLE_ENDIAN else JxlEndianness.JXL_BIG_ENDIAN,
		else => endianness,
	};
	return switch (actual) {
		.JXL_LITTLE_ENDIAN => std.mem.readInt(u16, src[0..2], .little),
		.JXL_BIG_ENDIAN => std.mem.readInt(u16, src[0..2], .big),
		else => unreachable,
	};
}

pub fn clampU32(value: i32, max_value: u32) u32 {
	if (value <= 0) return 0;
	const unsigned: u32 = @intCast(value);
	return @min(unsigned, max_value);
}

pub fn normalizedFloat(value: i32, max_value: u32) f32 {
	if (max_value == 0) return 0.0;
	return @as(f32, @floatFromInt(clampU32(value, max_value))) / @as(f32, @floatFromInt(max_value));
}

pub fn scaleToU8(value: i32, max_value: u32) u8 {
	if (max_value == 0) return 0;
	const clamped = clampU32(value, max_value);
	if (max_value == 255) return @intCast(clamped);
	return @intCast((@as(u64, clamped) * 255 + max_value / 2) / max_value);
}

pub fn clampFloatSample(value: f32, max_value: u32) f32 {
	if (max_value == 0 or !std.math.isFinite(value)) return 0.0;
	return std.math.clamp(value, 0.0, @as(f32, @floatFromInt(max_value)));
}

pub fn normalizedFloatSample(value: f32, max_value: u32) f32 {
	if (max_value == 0) return 0.0;
	return clampFloatSample(value, max_value) / @as(f32, @floatFromInt(max_value));
}

pub fn clampNormalizedSample(value: f32) f32 {
	if (!std.math.isFinite(value)) return 0.0;
	return std.math.clamp(value, 0.0, 1.0);
}

pub fn scaleFloatToU8(value: f32, max_value: u32) u8 {
	if (max_value == 0) return 0;
	const scaled = @round(normalizedFloatSample(value, max_value) * 255.0);
	return @intFromFloat(scaled);
}

pub fn scaleNormalizedToU8(value: f32) u8 {
	const scaled = @round(clampNormalizedSample(value) * 255.0);
	return @intFromFloat(scaled);
}

fn roundUpTo(value: usize, alignment: usize) usize {
	return ((value + alignment - 1) / alignment) * alignment;
}

test "pixel format helpers compute channel size and aligned rows" {
	const format = JxlPixelFormat{
		.num_channels = 3,
		.data_type = .JXL_TYPE_UINT16,
		.endianness = .JXL_NATIVE_ENDIAN,
		.@"align" = 8,
	};

	try std.testing.expectEqual(@as(?usize, 2), bytesPerChannel(.JXL_TYPE_UINT16));
	try std.testing.expectEqual(@as(?usize, 16), rowStrideBytes(2, format));
}

test "pixel format helpers store explicit endian integers" {
	var two: [2]u8 = undefined;
	storeU16(two[0..], .JXL_BIG_ENDIAN, 0x1234);
	try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, two[0..]);
	storeU16(two[0..], .JXL_LITTLE_ENDIAN, 0x1234);
	try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, two[0..]);
	try std.testing.expectEqual(@as(u16, 0x1234), loadU16(&.{ 0x12, 0x34 }, .JXL_BIG_ENDIAN));
	try std.testing.expectEqual(@as(u16, 0x1234), loadU16(&.{ 0x34, 0x12 }, .JXL_LITTLE_ENDIAN));

	var four: [4]u8 = undefined;
	storeU32(four[0..], .JXL_BIG_ENDIAN, 0x12345678);
	try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, four[0..]);
	storeU32(four[0..], .JXL_LITTLE_ENDIAN, 0x12345678);
	try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, four[0..]);
}

test "pixel format helpers clamp and scale integer and normalized samples" {
	try std.testing.expectEqual(@as(u8, 128), scaleToU8(128, 255));
	try std.testing.expectEqual(@as(u8, 128), scaleToU8(50, 100));
	try std.testing.expectEqual(@as(u8, 0), scaleToU8(-5, 100));
	try std.testing.expectEqual(@as(u8, 255), scaleToU8(500, 100));
	try std.testing.expectEqual(@as(u8, 128), scaleNormalizedToU8(0.5));
	try std.testing.expectEqual(@as(u8, 0), scaleNormalizedToU8(std.math.nan(f32)));
	try std.testing.expectEqual(@as(f32, 0.25), normalizedFloat(25, 100));
}
