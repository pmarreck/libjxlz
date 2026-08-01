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

/// 32x32 blue-noise dither table ported from libjxl v0.12.0's `stage_write.cc`
/// (https://momentsingraphics.de/BlueNoise.html), scaled to average 0 and lie
/// within (-0.49219, 0.49219). v0.11.x used an 8x8 ordered dither loaded via
/// `LoadDup128`, which repeated each four-value half-row; v0.12.0 replaced the
/// algorithm outright. Upstream pads each row to 48 floats so SIMD can wrap
/// horizontally; that padding duplicates the first 16 columns and is omitted
/// here in favour of an explicit modulo.
const rendered_dither = [32][32]f32{
		.{ -0.26057, 0.32619, 0.21039, -0.03281, -0.10616, 0.16792, 0.43042, -0.48061, -0.00965, -0.31075, 0.24899, -0.35322, -0.02509, -0.25285, 0.02895, 0.10230, -0.28373, -0.00193, 0.23355, 0.43428, -0.23741, 0.18336, -0.31847, -0.11002, -0.36094, 0.26057, -0.19108, -0.29531, 0.40726, -0.09458, 0.11002, -0.48833 },
		.{ 0.16020, -0.35708, -0.18336, 0.36094, -0.28373, -0.34550, -0.20267, 0.07914, 0.35708, -0.41498, 0.47675, -0.21811, -0.12546, 0.44200, -0.41884, -0.17178, 0.39954, 0.33778, -0.33778, 0.04053, -0.46517, 0.27215, -0.16792, 0.39182, 0.20653, -0.43814, -0.02895, 0.17950, -0.41498, 0.01737, 0.24899, 0.49219 },
		.{ -0.00965, 0.08300, 0.41112, -0.46903, 0.04053, 0.47289, 0.26057, -0.05983, -0.13704, 0.14862, 0.03281, 0.29531, -0.45744, 0.22583, 0.14862, -0.09072, -0.37638, 0.19881, -0.14476, 0.14476, -0.09072, 0.48447, -0.39954, 0.06369, -0.05983, -0.26829, 0.43428, -0.12546, 0.28759, -0.22969, -0.32619, -0.15248 },
		.{ -0.42270, 0.23741, -0.23355, -0.11774, 0.18722, 0.11388, -0.43814, -0.24899, 0.41884, 0.21039, -0.28373, -0.06756, 0.07914, 0.36480, -0.31075, 0.30303, -0.03281, 0.07142, -0.42656, 0.38024, -0.27987, 0.00579, 0.12546, -0.22197, 0.29917, 0.36866, 0.13704, -0.47289, 0.09072, 0.35708, -0.04825, 0.38796 },
		.{ -0.28759, -0.07142, 0.44200, 0.27601, -0.38024, -0.16020, -0.01737, 0.30303, -0.33006, -0.40340, -0.16792, 0.40726, -0.36480, -0.00579, -0.19108, 0.41498, -0.26443, 0.46903, -0.21811, 0.28759, -0.04053, 0.22197, 0.34550, -0.44972, -0.14476, -0.34164, 0.04053, -0.19494, 0.45358, -0.37252, 0.21425, 0.05597 },
		.{ 0.31075, 0.14090, -0.33778, 0.00579, 0.34550, -0.29917, 0.38796, 0.13704, 0.05983, -0.10230, 0.34164, 0.10616, -0.23741, 0.19494, -0.47675, 0.04439, -0.39568, 0.24127, 0.10616, -0.49219, -0.17950, -0.36094, -0.30303, 0.45744, -0.01351, 0.24513, -0.39182, -0.07528, 0.18722, -0.26057, -0.11002, -0.45358 },
		.{ 0.46903, -0.17178, -0.41112, 0.07528, -0.09458, 0.21811, -0.20267, -0.48833, 0.44972, 0.00965, 0.24127, -0.42656, 0.48447, -0.11774, 0.26443, 0.14090, -0.15634, -0.07142, -0.32233, 0.36094, 0.42270, 0.19108, 0.07142, -0.11002, 0.15634, 0.38024, -0.28759, 0.27987, -0.00193, 0.33006, 0.11388, -0.21039 },
		.{ 0.02123, 0.17950, 0.38024, -0.24127, -0.44586, 0.48833, -0.03667, 0.26829, -0.36866, -0.22583, 0.17178, -0.30689, 0.29145, -0.04825, -0.35322, 0.43042, 0.34936, 0.00193, 0.16792, -0.12932, 0.03667, -0.06756, 0.31847, -0.40726, -0.24513, 0.09458, -0.17564, 0.47675, -0.43042, -0.32233, 0.40340, 0.26057 },
		.{ -0.47675, -0.12160, -0.04825, 0.28759, 0.10230, 0.15634, -0.14862, -0.27601, 0.36094, -0.12932, -0.05983, -0.45358, -0.17950, 0.01737, 0.09458, -0.29145, -0.22969, -0.43428, 0.45744, -0.38796, -0.27601, -0.21039, -0.46131, 0.22969, 0.41112, -0.05211, -0.48061, 0.16406, 0.05211, -0.14862, -0.03281, -0.36866 },
		.{ -0.27215, 0.34164, -0.31075, 0.42656, -0.38410, -0.32619, 0.02895, 0.19881, 0.08300, 0.42270, 0.31461, 0.13318, 0.45744, 0.37638, -0.40726, 0.31847, -0.08686, 0.21425, 0.29917, 0.07914, 0.26829, 0.13704, 0.48447, -0.15248, 0.02509, -0.34936, 0.34936, -0.10230, 0.42656, -0.23741, 0.22583, 0.09072 },
		.{ 0.44972, 0.20267, 0.04825, -0.21425, 0.24513, -0.07142, 0.39954, -0.46131, -0.39568, -0.01351, -0.33392, 0.05597, -0.26443, 0.22197, -0.20653, 0.15248, 0.04439, -0.46517, -0.16406, -0.04439, -0.34936, 0.37252, -0.01351, -0.30689, 0.29917, 0.20653, -0.26829, 0.26443, 0.13318, -0.39954, 0.30303, -0.08686 },
		.{ -0.42656, 0.12932, -0.14476, -0.46903, -0.00579, 0.34936, -0.18722, 0.28373, -0.23741, 0.22969, -0.16020, -0.38024, -0.08300, -0.48447, -0.02123, -0.14862, 0.48061, -0.31847, 0.39568, -0.24899, 0.18722, -0.41884, 0.10230, -0.08300, -0.38796, 0.06369, -0.19881, -0.44972, 0.00579, -0.33392, 0.37252, -0.19108 },
		.{ -0.02509, -0.35708, 0.32619, 0.46517, 0.17178, -0.28373, 0.10616, 0.47675, -0.09458, 0.15248, 0.43428, 0.35322, 0.17564, 0.27215, 0.41112, -0.36480, 0.24899, 0.11774, 0.01351, 0.33006, -0.11388, -0.18336, 0.41884, -0.23355, 0.16406, 0.46131, 0.38410, -0.04825, -0.15634, 0.49219, 0.17564, 0.03667 },
		.{ 0.40726, 0.23355, -0.25285, -0.08300, -0.41112, -0.12160, -0.35708, 0.05211, -0.41884, -0.29531, 0.02123, -0.21425, 0.09844, -0.30689, -0.11388, 0.34550, -0.26443, -0.07142, -0.39954, 0.44586, 0.05983, -0.48833, 0.24127, 0.34936, -0.44200, -0.12546, 0.12160, -0.30303, 0.27215, 0.07528, -0.48447, -0.29145 },
		.{ 0.28373, -0.17564, 0.09458, 0.02123, 0.30689, 0.41884, 0.20653, -0.03667, 0.32233, 0.25671, -0.45744, -0.05597, 0.46517, -0.41498, 0.00965, 0.07142, -0.44586, 0.16406, -0.20653, 0.21811, -0.29917, 0.28759, -0.05597, 0.03281, -0.32619, -0.00965, 0.31847, -0.37252, 0.18722, -0.11002, -0.22969, -0.06369 },
		.{ -0.39568, 0.36866, -0.45744, -0.31847, 0.14476, -0.22583, -0.49219, 0.37638, -0.19494, -0.13318, 0.39182, -0.35322, 0.29531, -0.24127, 0.21039, -0.18722, 0.45358, 0.31461, -0.13318, -0.01737, -0.36094, 0.12932, -0.25671, 0.43814, -0.16792, 0.23355, -0.22197, 0.44972, -0.42270, 0.33392, 0.42656, 0.11774 },
		.{ -0.13318, 0.19494, -0.03667, 0.44972, 0.24513, -0.15248, 0.08300, -0.33006, 0.00579, 0.12546, 0.19494, 0.05983, -0.15634, 0.14476, 0.36480, -0.04053, -0.33006, 0.25671, -0.46903, 0.37252, 0.48833, -0.09458, -0.41112, 0.19108, 0.08686, -0.46903, -0.07528, 0.04053, -0.26829, -0.02895, 0.22197, -0.34164 },
		.{ 0.47289, -0.21811, 0.06756, -0.38410, -0.27987, -0.06369, 0.27987, 0.43814, -0.25671, -0.39182, 0.49219, -0.27601, -0.07914, -0.48061, 0.42656, -0.38410, 0.11002, 0.03667, -0.27215, 0.15634, 0.07528, -0.22197, 0.33006, 0.38410, -0.34936, 0.27987, 0.15248, 0.40340, 0.09844, -0.16406, -0.46131, 0.03281 },
		.{ -0.29531, 0.31461, -0.10616, 0.39954, 0.01351, 0.33778, -0.43814, 0.17178, -0.08686, 0.23741, -0.44586, 0.33778, -0.00193, -0.31461, 0.23741, -0.12932, -0.22583, -0.06756, 0.40340, -0.16792, -0.43428, 0.01351, -0.14476, -0.04053, -0.29145, 0.46517, -0.13704, -0.39182, -0.32233, 0.29531, 0.38410, 0.16020 },
		.{ -0.44200, 0.26443, 0.12546, -0.42270, 0.21425, -0.19881, -0.35708, 0.04825, 0.36480, -0.02895, -0.21425, 0.09072, 0.41498, 0.18336, 0.04439, 0.29917, 0.47675, -0.40340, 0.27601, -0.31461, 0.31075, 0.17564, 0.24899, -0.45744, 0.05597, -0.19494, 0.00193, 0.36094, 0.24127, -0.09844, -0.24513, -0.00965 },
		.{ -0.17564, -0.05597, -0.34550, -0.24899, 0.48061, 0.15248, -0.11388, 0.45358, -0.16406, -0.32233, 0.31461, -0.11774, -0.36866, -0.18722, -0.25671, -0.44200, 0.13318, -0.02123, 0.19881, -0.10616, 0.43042, -0.36866, -0.24899, 0.41112, 0.11002, 0.21425, -0.25671, -0.47675, -0.04439, 0.13704, -0.37252, 0.43814 },
		.{ 0.19108, 0.03667, 0.35708, -0.14090, 0.08300, -0.02123, -0.30303, -0.48061, 0.11774, 0.20267, -0.43042, 0.25285, 0.14090, -0.04439, 0.38796, 0.34550, -0.34164, -0.19494, 0.05983, -0.48447, 0.09844, -0.00579, -0.07914, 0.33778, -0.41498, -0.10230, 0.30689, 0.17178, 0.48833, -0.20267, 0.07914, 0.33392 },
		.{ -0.48833, -0.30689, 0.41498, 0.22969, -0.44586, 0.32233, 0.25285, 0.39182, -0.23355, 0.01737, 0.42270, -0.27987, 0.46903, -0.47289, 0.02123, -0.09072, 0.21811, 0.44586, -0.25285, 0.36480, -0.29145, 0.47289, -0.18722, 0.14476, -0.31461, 0.43814, -0.36094, 0.04439, -0.29917, -0.41884, 0.25285, -0.11774 },
		.{ 0.46131, 0.11388, -0.21039, -0.07528, -0.38024, -0.26057, 0.06369, -0.05983, 0.29145, -0.40340, -0.09072, 0.06756, -0.16020, 0.27601, -0.31075, 0.10616, -0.14090, -0.43042, 0.25671, -0.05211, -0.13318, 0.23355, -0.44972, 0.02895, 0.26829, -0.02895, -0.17950, 0.37252, -0.13704, 0.40726, 0.01351, -0.26443 },
		.{ -0.03281, -0.40340, 0.27987, 0.17564, 0.02509, 0.44200, -0.15248, -0.34550, 0.14862, -0.19881, -0.01351, 0.36866, -0.38796, 0.19494, -0.22197, 0.32619, -0.37638, 0.00193, 0.30689, 0.12160, -0.39182, 0.16792, -0.34550, 0.39954, -0.23355, 0.09072, -0.43428, 0.22969, -0.06369, 0.12546, -0.35322, 0.30689 },
		.{ -0.09844, 0.06756, 0.38410, -0.33392, -0.18336, 0.35322, 0.21039, -0.42270, 0.48833, 0.33006, 0.21811, -0.33392, 0.12932, -0.05211, 0.39568, 0.04825, 0.48061, 0.17950, -0.31847, -0.21811, 0.38024, 0.05211, 0.32233, -0.06756, -0.12546, 0.46131, 0.16020, -0.25285, 0.29531, -0.44972, 0.17950, -0.16406 },
		.{ 0.22583, -0.46131, -0.27601, -0.00579, 0.12932, -0.47289, -0.09844, 0.10230, -0.28759, -0.12160, -0.49219, -0.24127, 0.44586, -0.11388, -0.45358, -0.27215, -0.17178, -0.07528, -0.47675, 0.43042, -0.02509, -0.27215, -0.19108, 0.19881, -0.49219, -0.37252, 0.33392, -0.00193, -0.33006, -0.20267, 0.48061, 0.34164 },
		.{ -0.22969, 0.42270, -0.12160, 0.31075, 0.46903, -0.22583, 0.27215, -0.02509, 0.03281, 0.40340, 0.25671, 0.08686, 0.00965, 0.29145, -0.41112, 0.14090, 0.24513, 0.34164, 0.08686, -0.14862, 0.27601, -0.42656, 0.48447, 0.09844, 0.26443, -0.27987, 0.05597, -0.10230, 0.43428, 0.08686, 0.02895, -0.38024 },
		.{ 0.15634, 0.09458, -0.36480, 0.18336, -0.05211, -0.40726, 0.36866, -0.33778, -0.19881, 0.16020, -0.37638, -0.16020, -0.29917, 0.20267, 0.41884, -0.01737, -0.34936, -0.24127, 0.02509, 0.20653, -0.36480, -0.08686, 0.01737, -0.33778, 0.41498, -0.03667, 0.37638, -0.17178, -0.47289, 0.26829, -0.28759, -0.05597 },
		.{ 0.35708, 0.00193, 0.25285, -0.15634, -0.30303, 0.06369, 0.22197, 0.45358, -0.43814, 0.30303, -0.04053, 0.46517, 0.35322, -0.21039, 0.06756, -0.14090, 0.37638, -0.43042, 0.45744, -0.29531, 0.39568, 0.14862, 0.23741, -0.13704, -0.21425, 0.16406, -0.40726, 0.22583, 0.13318, 0.38796, -0.12932, -0.43428 },
		.{ -0.31461, -0.20653, 0.46131, -0.45358, 0.39568, -0.24513, -0.14090, 0.11002, -0.08300, -0.26829, 0.05211, -0.46517, -0.09844, -0.39568, -0.32619, -0.06369, 0.16792, 0.28373, 0.11388, -0.04439, -0.18336, -0.44200, 0.35322, -0.26057, -0.46517, 0.31075, -0.07914, -0.34164, -0.24513, -0.02123, 0.19108, 0.44200 },
		.{ 0.04825, -0.07914, -0.39954, 0.12160, 0.29145, 0.00965, -0.37638, 0.32233, 0.20267, -0.17564, 0.39182, 0.12160, 0.18336, 0.32619, 0.26057, 0.49219, -0.48447, -0.20653, -0.10616, -0.38796, 0.31847, 0.07528, -0.01737, 0.44586, 0.11774, 0.02509, 0.47289, 0.07142, 0.33392, -0.38410, -0.17950, 0.28373 },
};

/// Packs a rendered float sample at an output coordinate and colour channel so
/// UINT8 quantization reproduces the pinned decoder oracle's spatial contract.
/// The per-channel offsets (23 horizontally, 13 vertically) are upstream's way
/// of decorrelating the blue-noise pattern between colour channels.
pub fn scaleRenderedToU8(value: f32, x: usize, y: usize, c: usize) u8 {
	const dither = rendered_dither[(y + c * 13) % 32][(x + c * 23) % 32];
	const scaled = clampNormalizedSample(value) * 255.0 + dither;
	const clamped = std.math.clamp(scaled, 0.0, 255.0);
	const lower_float = @floor(clamped);
	const lower: u8 = @intFromFloat(lower_float);
	const fraction = clamped - lower_float;
	if (fraction < 0.5 or lower == 255) return lower;
	if (fraction > 0.5) return lower + 1;
	return if (lower & 1 == 0) lower else lower + 1;
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

test "rendered uint8 scaling reproduces libjxl v0.12.0 blue-noise dither" {
	// Expectations computed from an independent C implementation of upstream
	// MakeUnsigned<uint8_t> over the extracted 32x32 table, not from this code.
	const halfway = 1.5 / 255.0;
	try std.testing.expectEqual(@as(u8, 1), scaleRenderedToU8(halfway, 0, 0, 0));
	try std.testing.expectEqual(@as(u8, 2), scaleRenderedToU8(halfway, 1, 0, 0));
	try std.testing.expectEqual(@as(u8, 1), scaleRenderedToU8(halfway, 4, 0, 0));
	try std.testing.expectEqual(@as(u8, 2), scaleRenderedToU8(halfway, 0, 1, 0));
	// Same coordinate, different colour channel: exercises the (c*23, c*13)
	// offsets that v0.11.x's channel-independent ordered dither did not have.
	try std.testing.expectEqual(@as(u8, 2), scaleRenderedToU8(halfway, 0, 0, 1));
	try std.testing.expectEqual(@as(u8, 1), scaleRenderedToU8(halfway, 0, 0, 2));
	const fixture_tie: f32 = @bitCast(@as(u32, 0x3edd4141));
	try std.testing.expectEqual(@as(u8, 111), scaleRenderedToU8(fixture_tie, 1216, 69, 0));
}
