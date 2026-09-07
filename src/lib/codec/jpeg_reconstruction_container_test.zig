const std = @import("std");
const container = @import("container.zig");
const fixture = @import("jpeg_reconstruction_fixture.zig");
const allocator = std.testing.allocator;
test "container retains parsed JPEG reconstruction metadata" {
	const wrapped = try container.wrapCodestreamWithBoxes(allocator, &.{ 255, 10, 0 }, &.{.{ .box_type = "jbrd".*, .contents = &fixture.bytes_0 }});
	defer allocator.free(wrapped);
	var parsed = try container.extractCodestreamAndBoxes(allocator, wrapped);
	defer parsed.deinit(allocator);
	try std.testing.expect(parsed.boxes[2].reconstruction != null);
	try std.testing.expectEqualSlices(u8, &fixture.markers_0, parsed.boxes[2].reconstruction.?.markers);
}
test "container rejects truncated JPEG reconstruction metadata" {
	const wrapped = try container.wrapCodestreamWithBoxes(allocator, &.{ 255, 10, 0 }, &.{.{ .box_type = "jbrd".*, .contents = fixture.bytes_0[0 .. fixture.bytes_0.len - 1] }});
	defer allocator.free(wrapped);
	if (container.extractCodestreamAndBoxes(allocator, wrapped)) |result| {
		var parsed = result;
		parsed.deinit(allocator);
		return error.AcceptedTruncatedReconstruction;
	} else |err| try std.testing.expectEqual(error.InvalidContainer, err);
}
fn allocationCase(memory: std.mem.Allocator, wrapped: []const u8) !void {
	var parsed = try container.extractCodestreamAndBoxes(memory, wrapped);
	defer parsed.deinit(memory);
}
test "container reconstruction ownership survives every allocation failure" {
	const wrapped = try container.wrapCodestreamWithBoxes(allocator, &.{ 255, 10, 0 }, &.{.{ .box_type = "jbrd".*, .contents = &fixture.bytes_4 }});
	defer allocator.free(wrapped);
	try std.testing.checkAllAllocationFailures(allocator, allocationCase, .{wrapped});
}
