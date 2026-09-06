const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("jpeg_coefficients_synthetic_fixture.zig");
const writer = @import("jpeg_writer.zig");
fn check(allocator: std.mem.Allocator, comptime samples: type, comptime id: usize, progressive: bool) !void {
	const key = std.fmt.comptimePrint("{d}", .{id});
	var parsed = try jxl.codec.container.extractCodestreamAndBoxes(allocator, &@field(samples, "bytes_" ++ key));
	defer parsed.deinit(allocator);
	var output: ?*jxl.codec.jpeg_reconstruction.Data = null;
	for (parsed.boxes) |*box| if (box.reconstruction) |*data| {
		output = data;
	};
	try std.testing.expect(output != null);
	var br = jxl.base.bit_reader.BitReader.init(parsed.codestream[2..]);
	var metadata = jxl.codec.image_metadata.CodecMetadata{};
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	var decoder = jxl.codec.dec_frame.FrameDecoder.init(allocator, &metadata);
	defer decoder.deinit();
	decoder.jpeg_output = output;
	try decoder.decodeFrame(parsed.codestream[2 + br.totalBitsConsumed() / 8 ..]);
	try std.testing.expectEqual(progressive, std.mem.indexOfScalar(u8, output.?.markers, 0xc2) != null);
	if (progressive) {
		try std.testing.expect(output.?.scans.len > 1);
		try std.testing.expect(output.?.scans[output.?.scans.len - 1].ah != 0);
	}
	const bytes = try writer.write(allocator, output.?);
	defer allocator.free(bytes);
	try std.testing.expectEqualSlices(u8, &@field(samples, "jpeg_" ++ key), bytes);
}
test "JPEG writer reproduces upstream sequential JPEG bytes" {
	inline for (0..80) |id| {
		errdefer std.debug.print("JPEG writer record {d}\n", .{id});
		try check(std.testing.allocator, fixture, id, false);
	}
}
test "JPEG writer reproduces upstream progressive scan and refinement bytes" {
	inline for (0..80) |id| {
		errdefer std.debug.print("JPEG progressive writer record {d}\n", .{id});
		try check(std.testing.allocator, @import("jpeg_writer_progressive_fixture.zig"), id, true);
	}
}
test "JPEG writer preserves padding zero runs and marker payloads" {
	inline for (0..16) |id| {
		errdefer std.debug.print("JPEG detailed writer record {d}\n", .{id});
		try check(std.testing.allocator, @import("jpeg_writer_details_fixture.zig"), id, true);
	}
}
fn allocationCase(allocator: std.mem.Allocator) !void {
	try check(allocator, @import("jpeg_writer_details_fixture.zig"), 1, true);
}
test "JPEG writer releases allocations when output or refinement buffers fail" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

test "JPEG writer splits maximum progressive EOB runs with and without refinement bits" {
	const samples = @import("jpeg_writer_eob_fixture.zig");
	inline for (0..2) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		const components = @field(samples, "components_" ++ key);
		try std.testing.expect(components[0][3] * components[0][4] > 32767);
		try check(std.testing.allocator, samples, id, true);
	}
}
