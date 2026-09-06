//! Restore JPEG application payloads separated into JPEG XL metadata boxes.
const Data = @import("jpeg_reconstruction.zig").Data;
const std = @import("std");
const container = @import("container.zig");
const brotli = @import("../base/brotli.zig");
const Error = @import("../base/status.zig").JxlError;
const exif_header_size = 3 + "Exif\x00\x00".len;
const xmp_header_size = 3 + "http://ns.adobe.com/xap/1.0/\x00".len;
pub fn setICC(data: *Data, bytes: []const u8) Error!void {
	const header_size = 17;
	var expected: usize = 0;
	var chunks: usize = 0;
	for (data.apps) |app| if (app.kind == .icc) {
		if (app.data.len < header_size) return error.GenericError;
		expected += app.data.len - header_size;
		chunks += 1;
	};
	if (chunks == 0) return;
	if (bytes.len != expected) return error.GenericError;
	var offset: usize = 0;
	for (data.apps) |app| if (app.kind == .icc) {
		const count = app.data.len - header_size;
		@memcpy(app.data[header_size..], bytes[offset..][0..count]);
		offset += count;
	};
}
pub fn setExif(data: *Data, bytes: []const u8) Error!void {
	if (bytes.len < 4) return error.GenericError;
	for (data.apps) |app| if (app.kind == .exif) {
		if (app.data.len < exif_header_size or app.data.len - exif_header_size != bytes.len - 4) return error.GenericError;
		@memcpy(app.data[exif_header_size..], bytes[4..]);
		return;
	};
	return error.GenericError;
}
pub fn setXmp(data: *Data, bytes: []const u8) Error!void {
	for (data.apps) |app| if (app.kind == .xmp) {
		if (app.data.len < xmp_header_size or app.data.len - xmp_header_size != bytes.len) return error.GenericError;
		@memcpy(app.data[xmp_header_size..], bytes);
		return;
	};
	return error.GenericError;
}
pub fn populate(allocator: std.mem.Allocator, data: *Data, icc: []const u8, boxes: []const container.OwnedBox) Error!void {
	try setICC(data, icc);
	inline for (.{
		.{ .kind = .exif, .box = "Exif", .header = exif_header_size, .prefix = 4 },
		.{ .kind = .xmp, .box = "xml ", .header = xmp_header_size, .prefix = 0 },
	}) |field| {
		var required: ?usize = null;
		for (data.apps) |app| if (app.kind == field.kind) {
			if (required != null or app.data.len < field.header) return error.GenericError;
			required = app.data.len - field.header + field.prefix;
		};
		if (required) |expected| {
			var found = false;
			for (boxes) |box| {
				const kind = box.effectiveBoxType(true) catch return error.GenericError;
				if (!std.mem.eql(u8, &kind, field.box)) continue;
				if (found) return error.GenericError;
				found = true;
				var owned: ?[]u8 = null;
				defer if (owned) |bytes| allocator.free(bytes);
				const bytes = if (std.mem.eql(u8, &box.box_type, "brob") and box.decompressed_contents == null) blk: {
					owned = try brotli.decompressBounded(allocator, box.contents[4..], expected);
					break :blk owned.?;
				} else box.effectiveContents(true);
				if (bytes.len != expected) return error.GenericError;
				if (field.kind == .exif) try setExif(data, bytes) else try setXmp(data, bytes);
			}
			if (!found) return error.GenericError;
		}
	}
}
