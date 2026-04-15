const std = @import("std");

pub const signature_box = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };
pub const ftyp_payload = [_]u8{ 'j', 'x', 'l', ' ', 0, 0, 0, 0, 'j', 'x', 'l', ' ' };
pub const Box = struct {
	box_type: [4]u8,
	contents: []const u8,
};

fn appendU32BE(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
	var bytes: [4]u8 = undefined;
	std.mem.writeInt(u32, &bytes, value, .big);
	try list.appendSlice(allocator, &bytes);
}

fn appendBox(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime box_type: [4]u8, payload: []const u8) !void {
	const size = 8 + payload.len;
	if (size > std.math.maxInt(u32)) return error.Unsupported;
	try appendU32BE(list, allocator, @intCast(size));
	try list.appendSlice(allocator, &box_type);
	try list.appendSlice(allocator, payload);
}

fn appendBoxRuntime(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, box_type: [4]u8, payload: []const u8) !void {
	const size = 8 + payload.len;
	if (size > std.math.maxInt(u32)) return error.Unsupported;
	try appendU32BE(list, allocator, @intCast(size));
	try list.appendSlice(allocator, &box_type);
	try list.appendSlice(allocator, payload);
}

/// Wraps a raw codestream in the minimal BMFF container layout used by simple
/// JPEG XL files: signature box, `ftyp`, then a single `jxlc` codestream box.
pub fn wrapCodestream(allocator: std.mem.Allocator, codestream: []const u8) ![]u8 {
	return wrapCodestreamWithBoxes(allocator, codestream, &.{});
}

/// Wraps a raw codestream in the minimal BMFF container plus any already-owned
/// metadata boxes that should precede the codestream box.
pub fn wrapCodestreamWithBoxes(allocator: std.mem.Allocator, codestream: []const u8, boxes: []const Box) ![]u8 {
	var list: std.ArrayListUnmanaged(u8) = .{};
	defer list.deinit(allocator);

	try list.appendSlice(allocator, &signature_box);
	try appendBox(&list, allocator, .{ 'f', 't', 'y', 'p' }, &ftyp_payload);
	for (boxes) |box| {
		try appendBoxRuntime(&list, allocator, box.box_type, box.contents);
	}
	try appendBox(&list, allocator, .{ 'j', 'x', 'l', 'c' }, codestream);
	return list.toOwnedSlice(allocator);
}

/// Extracts the first complete codestream payload from a minimal JPEG XL
/// container, accepting either a single `jxlc` box or a sequential `jxlp`
/// series with the high-bit "last fragment" marker.
pub fn extractCodestream(allocator: std.mem.Allocator, container_bytes: []const u8) ![]u8 {
	if (container_bytes.len < signature_box.len) return error.GenericError;
	if (!std.mem.eql(u8, container_bytes[0..signature_box.len], &signature_box)) return error.GenericError;

	var offset: usize = signature_box.len;
	var partial: std.ArrayListUnmanaged(u8) = .{};
	defer partial.deinit(allocator);
	var saw_jxlp = false;
	var saw_last_jxlp = false;
	var next_jxlp_index: u32 = 0;
	while (offset + 8 <= container_bytes.len) {
		const size = std.mem.readInt(u32, @ptrCast(container_bytes[offset .. offset + 4]), .big);
		if (size < 8) return error.GenericError;
		if (size == 0 or size == 1) return error.Unsupported;
		const end = offset + size;
		if (end > container_bytes.len) return error.GenericError;
		const box_type = container_bytes[offset + 4 .. offset + 8];
		const payload = container_bytes[offset + 8 .. end];

		if (std.mem.eql(u8, box_type, "jxlc")) {
			if (saw_jxlp) return error.GenericError;
			return allocator.dupe(u8, payload);
		}
		if (std.mem.eql(u8, box_type, "jxlp")) {
			if (saw_last_jxlp) return error.GenericError;
			if (payload.len < 4) return error.GenericError;
			var index = std.mem.readInt(u32, @ptrCast(payload[0..4]), .big);
			const is_last = (index & 0x8000_0000) != 0;
			index &= 0x7FFF_FFFF;
			if (index != next_jxlp_index) return error.GenericError;
			next_jxlp_index += 1;
			saw_jxlp = true;
			if (is_last) saw_last_jxlp = true;
			try partial.appendSlice(allocator, payload[4..]);
		}

		offset = end;
	}

	if (saw_jxlp and saw_last_jxlp) return partial.toOwnedSlice(allocator);
	return error.GenericError;
}

const testing = std.testing;

test "wrapCodestream and extractCodestream round-trip" {
	const codestream = [_]u8{ 0xFF, 0x0A, 0x01, 0x02, 0x03, 0x04 };
	const wrapped = try wrapCodestream(testing.allocator, &codestream);
	defer testing.allocator.free(wrapped);

	try testing.expect(std.mem.eql(u8, wrapped[0..signature_box.len], &signature_box));
	const extracted = try extractCodestream(testing.allocator, wrapped);
	defer testing.allocator.free(extracted);
	try testing.expectEqualSlices(u8, &codestream, extracted);
}

test "extractCodestream reconstructs split jxlp payloads" {
	var wrapped: [56]u8 = undefined;
	@memcpy(wrapped[0..12], &signature_box);
	@memcpy(wrapped[12..32], &[_]u8{
		0x00, 0x00, 0x00, 0x14,
		'f', 't', 'y', 'p',
		'j', 'x', 'l', ' ',
		0x00, 0x00, 0x00, 0x00,
		'j', 'x', 'l', ' ',
	});
	@memcpy(wrapped[32..44], &[_]u8{
		0x00, 0x00, 0x00, 0x0C,
		'j', 'x', 'l', 'p',
		0x00, 0x00, 0x00, 0x00,
	});
	@memcpy(wrapped[44..56], &[_]u8{
		0x00, 0x00, 0x00, 0x0C,
		'j', 'x', 'l', 'p',
		0x80, 0x00, 0x00, 0x01,
	});

	const extracted = try extractCodestream(testing.allocator, &wrapped);
	defer testing.allocator.free(extracted);
	try testing.expectEqualSlices(u8, &.{}, extracted);
}
