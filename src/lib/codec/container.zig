const std = @import("std");

pub const signature_box = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };
pub const ftyp_payload = [_]u8{ 'j', 'x', 'l', ' ', 0, 0, 0, 0, 'j', 'x', 'l', ' ' };

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

/// Wraps a raw codestream in the minimal BMFF container layout used by simple
/// JPEG XL files: signature box, `ftyp`, then a single `jxlc` codestream box.
pub fn wrapCodestream(allocator: std.mem.Allocator, codestream: []const u8) ![]u8 {
	var list: std.ArrayListUnmanaged(u8) = .{};
	defer list.deinit(allocator);

	try list.appendSlice(allocator, &signature_box);
	try appendBox(&list, allocator, .{ 'f', 't', 'y', 'p' }, &ftyp_payload);
	try appendBox(&list, allocator, .{ 'j', 'x', 'l', 'c' }, codestream);
	return list.toOwnedSlice(allocator);
}

/// Extracts the first complete `jxlc` payload from a minimal JPEG XL container.
/// This intentionally rejects `jxlp`, large-size boxes, and open-ended boxes.
pub fn extractCodestream(container_bytes: []const u8) ![]const u8 {
	if (container_bytes.len < signature_box.len) return error.GenericError;
	if (!std.mem.eql(u8, container_bytes[0..signature_box.len], &signature_box)) return error.GenericError;

	var offset: usize = signature_box.len;
	while (offset + 8 <= container_bytes.len) {
		const size = std.mem.readInt(u32, @ptrCast(container_bytes[offset .. offset + 4]), .big);
		if (size < 8) return error.GenericError;
		if (size == 0 or size == 1) return error.Unsupported;
		const end = offset + size;
		if (end > container_bytes.len) return error.GenericError;
		const box_type = container_bytes[offset + 4 .. offset + 8];
		const payload = container_bytes[offset + 8 .. end];

		if (std.mem.eql(u8, box_type, "jxlc")) return payload;
		if (std.mem.eql(u8, box_type, "jxlp")) return error.Unsupported;

		offset = end;
	}

	return error.GenericError;
}

const testing = std.testing;

test "wrapCodestream and extractCodestream round-trip" {
	const codestream = [_]u8{ 0xFF, 0x0A, 0x01, 0x02, 0x03, 0x04 };
	const wrapped = try wrapCodestream(testing.allocator, &codestream);
	defer testing.allocator.free(wrapped);

	try testing.expect(std.mem.eql(u8, wrapped[0..signature_box.len], &signature_box));
	const extracted = try extractCodestream(wrapped);
	try testing.expectEqualSlices(u8, &codestream, extracted);
}
