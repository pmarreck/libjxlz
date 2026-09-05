const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("progressive_dc_fixture.zig");
fn metadataFrom(allocator: std.mem.Allocator, data: []const u8) !*jxl.codec.image_metadata.CodecMetadata {
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	errdefer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	return metadata;
}
fn check(allocator: std.mem.Allocator, data: []const u8, offsets: []const usize) !void {
	const metadata = try metadataFrom(allocator, data);
	defer allocator.destroy(metadata);
	var state = jxl.codec.decode_session.Session.init(allocator);
	defer state.deinit();
	for (offsets, 0..) |offset, i| {
		const end = if (i + 1 < offsets.len) offsets[i + 1] else data.len;
		try std.testing.expectEqual(end - offset, try jxl.codec.dec_frame.frameByteCount(allocator, metadata, data[offset..]));
		var dec = try state.decode(metadata, data[offset..end]);
		defer dec.deinit();
		try std.testing.expectEqual(offsets.len - 1 - i, dec.frame_header.dc_level);
		try std.testing.expectEqual(i != 0, dec.frame_header.flags & jxl.codec.frame_header.FrameFlags.use_dc_frame != 0);
		if (i + 1 < offsets.len) try std.testing.expect(state.dc_refs[dec.frame_header.dc_level - 1] != null);
	}
}
test "progressive DC sessions preserve each upstream reference level" {
	@setEvalBranchQuota(20000);
	inline for (0..10) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, check, .{ std.testing.allocator, &@field(fixture, "bytes_" ++ key), &@field(fixture, "offsets_" ++ key) });
	}
}
fn one(allocator: std.mem.Allocator) !void {
	try check(allocator, &fixture.bytes_0, &fixture.offsets_0);
}
test "progressive DC allocation failures release partial references" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, one, .{});
}
test "progressive DC rejects missing and wrongly sized reference frames" {
	@setEvalBranchQuota(20000);
	inline for (0..10) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		const data = @field(fixture, "bytes_" ++ key);
		const offsets = @field(fixture, "offsets_" ++ key);
		const metadata = try metadataFrom(std.testing.allocator, &data);
		defer std.testing.allocator.destroy(metadata);
		for (1..offsets.len) |i| {
			var missing = jxl.codec.decode_session.Session.init(std.testing.allocator);
			defer missing.deinit();
			try std.testing.expectError(error.GenericError, missing.decode(metadata, data[offsets[i]..]));
		}
		var state = jxl.codec.decode_session.Session.init(std.testing.allocator);
		defer state.deinit();
		for (offsets[0 .. offsets.len - 1], 0..) |offset, i| {
			var frame = try state.decode(metadata, data[offset..offsets[i + 1]]);
			frame.deinit();
		}
		state.dc_refs[0].?.width += 1;
		try std.testing.expectError(error.GenericError, state.decode(metadata, data[offsets[offsets.len - 1]..]));
	}
}
test "progressive DC modular frames reject unavailable higher references" {
	@setEvalBranchQuota(20000);
	inline for (0..4) |id| {
		const data = @field(fixture, "missing_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const metadata = try metadataFrom(std.testing.allocator, &data);
		defer std.testing.allocator.destroy(metadata);
		var state = jxl.codec.decode_session.Session.init(std.testing.allocator);
		defer state.deinit();
		try std.testing.expectError(error.GenericError, state.decode(metadata, data[fixture.offsets_8[0]..]));
	}
}
