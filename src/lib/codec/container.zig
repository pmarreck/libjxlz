const std = @import("std");
const brotli = @import("../base/brotli.zig");

pub const signature_box = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };
pub const ftyp_payload = [_]u8{ 'j', 'x', 'l', ' ', 0, 0, 0, 0, 'j', 'x', 'l', ' ' };
pub const Box = struct {
	box_type: [4]u8,
	contents: []const u8,
};

pub const OwnedBox = struct {
	box_type: [4]u8,
	raw_size: u64,
	contents: []u8,
	decompressed_box_type: ?[4]u8 = null,
	decompressed_contents: ?[]u8 = null,

	pub fn deinit(self: *OwnedBox, allocator: std.mem.Allocator) void {
		if (self.decompressed_contents) |contents| allocator.free(contents);
		allocator.free(self.contents);
		self.* = .{
			.box_type = undefined,
			.raw_size = 0,
			.contents = &.{},
			.decompressed_box_type = null,
			.decompressed_contents = null,
		};
	}

	/// Returns the box type the public API should report in either raw or
	/// transparent-brotli mode without forcing the caller to parse `brob`.
	pub fn effectiveBoxType(self: *const OwnedBox, decompressed: bool) ![4]u8 {
		if (!decompressed or !std.mem.eql(u8, &self.box_type, "brob")) return self.box_type;
		if (self.decompressed_box_type) |box_type| return box_type;
		if (self.contents.len < 4) return error.GenericError;
		return .{ self.contents[0], self.contents[1], self.contents[2], self.contents[3] };
	}

	pub fn effectiveContents(self: *const OwnedBox, decompressed: bool) []const u8 {
		if (decompressed) {
			if (self.decompressed_contents) |contents| return contents;
		}
		return self.contents;
	}

	/// Lazily expands `brob` payloads so decoder box iteration can stay raw by
	/// default while still supporting transparent metadata decompression on
	/// demand.
	pub fn ensureDecompressed(self: *OwnedBox, allocator: std.mem.Allocator) !void {
		if (!std.mem.eql(u8, &self.box_type, "brob")) return;
		if (self.decompressed_contents != null) return;
		if (self.contents.len < 4) return error.GenericError;
		self.decompressed_box_type = .{ self.contents[0], self.contents[1], self.contents[2], self.contents[3] };
		self.decompressed_contents = try brotli.decompress(allocator, self.contents[4..]);
	}
};

pub const ParsedContainer = struct {
	codestream: []u8,
	boxes: []OwnedBox,

	pub fn deinit(self: *ParsedContainer, allocator: std.mem.Allocator) void {
		allocator.free(self.codestream);
		for (self.boxes) |*box| box.deinit(allocator);
		allocator.free(self.boxes);
		self.* = .{
			.codestream = &.{},
			.boxes = &.{},
		};
	}
};

const ParsedBoxHeader = struct {
	box_type: [4]u8,
	raw_size: u64,
	payload: []const u8,
	next_offset: usize,
};

/// Parses one BMFF box header, including the `size == 0` open-ended and
/// `size == 1` extended-size forms, so container logic can stay size-form agnostic.
fn parseBoxHeader(container_bytes: []const u8, offset: usize) !ParsedBoxHeader {
	if (offset + 8 > container_bytes.len) return error.GenericError;

	const size32 = std.mem.readInt(u32, @ptrCast(container_bytes[offset .. offset + 4]), .big);
	const box_type: [4]u8 = .{
		container_bytes[offset + 4],
		container_bytes[offset + 5],
		container_bytes[offset + 6],
		container_bytes[offset + 7],
	};

	var raw_size: u64 = size32;
	var payload_offset = offset + 8;
	if (size32 == 0) {
		raw_size = container_bytes.len - offset;
	} else if (size32 == 1) {
		if (offset + 16 > container_bytes.len) return error.GenericError;
		raw_size = std.mem.readInt(u64, @ptrCast(container_bytes[offset + 8 .. offset + 16]), .big);
		payload_offset = offset + 16;
		if (raw_size < 16) return error.GenericError;
	} else if (size32 < 8) {
		return error.GenericError;
	}

	const end_u64 = @as(u64, offset) + raw_size;
	if (end_u64 > container_bytes.len) return error.GenericError;
	const end: usize = @intCast(end_u64);
	if (payload_offset > end) return error.GenericError;

	return .{
		.box_type = box_type,
		.raw_size = raw_size,
		.payload = container_bytes[payload_offset..end],
		.next_offset = end,
	};
}

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
	var parsed = try extractCodestreamAndBoxes(allocator, container_bytes);
	defer parsed.deinit(allocator);
	return allocator.dupe(u8, parsed.codestream);
}

/// Extracts the codestream plus any already-owned non-codestream BMFF boxes
/// from the current minimal container surface.
pub fn extractCodestreamAndBoxes(allocator: std.mem.Allocator, container_bytes: []const u8) !ParsedContainer {
	if (container_bytes.len < signature_box.len) return error.GenericError;
	if (!std.mem.eql(u8, container_bytes[0..signature_box.len], &signature_box)) return error.GenericError;

	var offset: usize = signature_box.len;
	var partial: std.ArrayListUnmanaged(u8) = .{};
	defer partial.deinit(allocator);
	var owned_boxes: std.ArrayListUnmanaged(OwnedBox) = .{};
	defer {
		for (owned_boxes.items) |*box| box.deinit(allocator);
		owned_boxes.deinit(allocator);
	}
	var codestream: ?[]u8 = null;
	var saw_jxlp = false;
	var saw_last_jxlp = false;
	var next_jxlp_index: u32 = 0;
	while (offset + 8 <= container_bytes.len) {
		const header = try parseBoxHeader(container_bytes, offset);
		const payload = header.payload;

		if (std.mem.eql(u8, &header.box_type, "jxlc")) {
			if (saw_jxlp) return error.GenericError;
			if (codestream != null) return error.GenericError;
			codestream = try allocator.dupe(u8, payload);
		} else if (std.mem.eql(u8, &header.box_type, "jxlp")) {
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
		} else if (!std.mem.eql(u8, &header.box_type, "ftyp")) {
			try owned_boxes.append(allocator, .{
				.box_type = header.box_type,
				.raw_size = header.raw_size,
				.contents = try allocator.dupe(u8, payload),
			});
		}

		offset = header.next_offset;
	}

	if (codestream == null and saw_jxlp and saw_last_jxlp) {
		codestream = try partial.toOwnedSlice(allocator);
	}
	if (codestream == null) return error.GenericError;

	const result = ParsedContainer{
		.codestream = codestream.?,
		.boxes = try owned_boxes.toOwnedSlice(allocator),
	};
	return result;
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

test "extractCodestream accepts final open-ended jxlc box" {
	const codestream = [_]u8{ 0xFF, 0x0A, 0x11, 0x22, 0x33 };
	var wrapped: std.ArrayListUnmanaged(u8) = .{};
	defer wrapped.deinit(testing.allocator);

	try wrapped.appendSlice(testing.allocator, &signature_box);
	try appendBox(&wrapped, testing.allocator, .{ 'f', 't', 'y', 'p' }, &ftyp_payload);
	try appendU32BE(&wrapped, testing.allocator, 0);
	try wrapped.appendSlice(testing.allocator, "jxlc");
	try wrapped.appendSlice(testing.allocator, &codestream);

	const extracted = try extractCodestream(testing.allocator, wrapped.items);
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

test "extractCodestreamAndBoxes preserves metadata boxes" {
	const codestream = [_]u8{ 0xFF, 0x0A, 0x01, 0x02 };
	const wrapped = try wrapCodestreamWithBoxes(testing.allocator, &codestream, &.{
		.{ .box_type = .{ 'x', 'm', 'l', ' ' }, .contents = "<x/>" },
		.{ .box_type = .{ 'E', 'x', 'i', 'f' }, .contents = "abcd" },
	});
	defer testing.allocator.free(wrapped);

	var parsed = try extractCodestreamAndBoxes(testing.allocator, wrapped);
	defer parsed.deinit(testing.allocator);

	try testing.expectEqualSlices(u8, &codestream, parsed.codestream);
	try testing.expectEqual(@as(usize, 2), parsed.boxes.len);
	try testing.expectEqualSlices(u8, "xml ", &parsed.boxes[0].box_type);
	try testing.expectEqualSlices(u8, "<x/>", parsed.boxes[0].contents);
	try testing.expectEqual(@as(u64, 12), parsed.boxes[0].raw_size);
	try testing.expectEqualSlices(u8, "Exif", &parsed.boxes[1].box_type);
	try testing.expectEqualSlices(u8, "abcd", parsed.boxes[1].contents);
	try testing.expectEqual(@as(u64, 12), parsed.boxes[1].raw_size);
}

test "extractCodestream handles extended-size BMFF boxes" {
	const codestream = [_]u8{ 0xFF, 0x0A, 0x44, 0x55 };
	var wrapped: std.ArrayListUnmanaged(u8) = .{};
	defer wrapped.deinit(testing.allocator);

	try wrapped.appendSlice(testing.allocator, &signature_box);
	try appendBox(&wrapped, testing.allocator, .{ 'f', 't', 'y', 'p' }, &ftyp_payload);
	try appendU32BE(&wrapped, testing.allocator, 1);
	try wrapped.appendSlice(testing.allocator, "jxlc");
	var extended_size: [8]u8 = undefined;
	std.mem.writeInt(u64, &extended_size, 16 + codestream.len, .big);
	try wrapped.appendSlice(testing.allocator, &extended_size);
	try wrapped.appendSlice(testing.allocator, &codestream);

	var parsed = try extractCodestreamAndBoxes(testing.allocator, wrapped.items);
	defer parsed.deinit(testing.allocator);

	try testing.expectEqualSlices(u8, &codestream, parsed.codestream);
}
