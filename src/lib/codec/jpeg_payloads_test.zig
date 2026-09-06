const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("jpeg_coefficients_fixture.zig");
const payloads = @import("jpeg_payloads.zig");
fn check(comptime samples: type, expected_icc: usize) !void {
	const allocator = std.testing.allocator;
	var parsed = try jxl.codec.container.extractCodestreamAndBoxes(allocator, &samples.bytes_0);
	defer parsed.deinit(allocator);
	var output: ?*jxl.codec.jpeg_reconstruction.Data = null;
	for (parsed.boxes) |*box| if (box.reconstruction) |*data| {
		output = data;
	};
	try std.testing.expect(output != null);
	var exif: []const u8 = &.{};
	var xmp: []const u8 = &.{};
	for (parsed.boxes) |*box| {
		const kind = try box.effectiveBoxType(true);
		if (std.mem.eql(u8, &kind, "Exif") or std.mem.eql(u8, &kind, "xml ")) try box.ensureDecompressed(allocator);
		if (std.mem.eql(u8, &kind, "Exif")) exif = box.effectiveContents(true);
		if (std.mem.eql(u8, &kind, "xml ")) xmp = box.effectiveContents(true);
	}
	if (expected_icc == 0) {
		try std.testing.expect(exif.len > 4);
		try std.testing.expect(xmp.len > 0);
	}
	if (exif.len != 0) {
		try std.testing.expectError(error.GenericError, payloads.setExif(output.?, &.{ 0, 0, 0 }));
		try std.testing.expectError(error.GenericError, payloads.setExif(output.?, exif[0 .. exif.len - 1]));
		try payloads.setExif(output.?, exif);
	}
	if (xmp.len != 0) {
		try std.testing.expectError(error.GenericError, payloads.setXmp(output.?, xmp[0 .. xmp.len - 1]));
		try payloads.setXmp(output.?, xmp);
	}
	var br = jxl.base.bit_reader.BitReader.init(parsed.codestream[2..]);
	var metadata = jxl.codec.image_metadata.CodecMetadata{};
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	const icc = if (metadata.m.color_encoding.want_icc) try jxl.codec.icc_codec.decompressICCFromBitReader(allocator, &br) else &.{};
	defer allocator.free(icc);
	var icc_chunks: usize = 0;
	for (output.?.apps) |app| if (app.kind == .icc) {
		icc_chunks += 1;
	};
	try std.testing.expectEqual(expected_icc, icc_chunks);
	if (expected_icc != 0) try std.testing.expect(icc.len > 0);
	if (expected_icc != 0) try std.testing.expectError(error.GenericError, payloads.setICC(output.?, icc[0 .. icc.len - 1]));
	try payloads.setICC(output.?, icc);
	metadata.embedded_icc = icc;
	try br.jumpToByteBoundary();
	var decoder = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
	defer decoder.deinit();
	decoder.jpeg_output = output;
	try decoder.decodeFrame(parsed.codestream[2 + br.totalBitsConsumed() / 8 ..]);
	const bytes = try @import("jpeg_writer.zig").write(allocator, output.?);
	defer allocator.free(bytes);
	try std.testing.expectEqualSlices(u8, &samples.jpeg_0, bytes);
}
test "JPEG external Exif and XMP payloads reconstruct the original JPEG" {
	try check(fixture, 0);
}
test "JPEG external ICC profile restores two original marker chunks" {
	try check(@import("jpeg_writer_metadata_fixture.zig"), 2);
}

fn populateAllocationCase(allocator: std.mem.Allocator) !void {
	var parsed = try jxl.codec.container.extractCodestreamAndBoxes(allocator, &fixture.bytes_0);
	defer parsed.deinit(allocator);
	var output: ?*jxl.codec.jpeg_reconstruction.Data = null;
	for (parsed.boxes) |*box| if (box.reconstruction) |*data| {
		output = data;
	};
	try std.testing.expect(output != null);
	try payloads.populate(allocator, output.?, &.{}, parsed.boxes);
}
test "JPEG payload restoration releases allocations on compressed metadata failure" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, populateAllocationCase, .{});
}
