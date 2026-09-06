const std = @import("std");
const jpeg = @import("jpeg_reconstruction.zig");
const fixture = @import("jpeg_reconstruction_fixture.zig");
test "JPEG reconstruction header preserves upstream marker and component counts" {
	inline for (0..6) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		var parsed = try jpeg.parse(std.testing.allocator, &@field(fixture, "bytes_" ++ key));
		defer parsed.deinit();
		const counts = &@field(fixture, "counts_" ++ key);
		try std.testing.expectEqualSlices(u8, &@field(fixture, "markers_" ++ key), parsed.markers);
		try std.testing.expectEqual(counts[0], parsed.components.len);
		try std.testing.expectEqual(counts[1], parsed.quant.len);
		try std.testing.expectEqual(counts[4], parsed.apps.len);
		try std.testing.expectEqual(counts[5], parsed.comments.len);
		for (parsed.components, &@field(fixture, "components_" ++ key)) |actual, expected| {
			try std.testing.expectEqual(expected[0], actual.id);
			try std.testing.expectEqual(expected[1], actual.quant_index);
		}
		for (parsed.quant, &@field(fixture, "quant_" ++ key)) |actual, expected| {
			try std.testing.expectEqual(expected[0], actual.precision);
			try std.testing.expectEqual(expected[1], actual.index);
			try std.testing.expectEqual(expected[2], @intFromBool(actual.is_last));
		}
		for (parsed.apps, &@field(fixture, "app_info_" ++ key)) |actual, expected| {
			try std.testing.expectEqual(expected[0], @intFromEnum(actual.kind));
			try std.testing.expectEqual(expected[1], actual.length);
		}
	}
}
test "JPEG reconstruction Huffman tables match every upstream count and symbol" {
	inline for (0..6) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		var parsed = try jpeg.parse(std.testing.allocator, &@field(fixture, "bytes_" ++ key));
		defer parsed.deinit();
		try std.testing.expectEqual(@field(fixture, "counts_" ++ key)[2], parsed.huffman.len);
		for (parsed.huffman, &@field(fixture, "huff_info_" ++ key), &@field(fixture, "huff_counts_" ++ key), &@field(fixture, "huff_values_" ++ key)) |actual, info, counts, values| {
			try std.testing.expectEqual(info[0], actual.slot_id);
			try std.testing.expectEqual(info[1], @intFromBool(actual.is_last));
			try std.testing.expectEqualSlices(u32, &counts, &actual.counts);
			try std.testing.expectEqualSlices(u32, &values, &actual.values);
		}
	}
}
test "JPEG reconstruction header rejects truncated marker prefixes" {
	for (0..3) |length| try std.testing.expectError(error.GenericError, jpeg.parse(std.testing.allocator, fixture.bytes_0[0..length]));
}
test "JPEG reconstruction scans and restart controls match upstream" {
	inline for (0..6) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		var parsed = try jpeg.parse(std.testing.allocator, &@field(fixture, "bytes_" ++ key));
		defer parsed.deinit();
		const expected_scans = &@field(fixture, "scans_" ++ key);
		try std.testing.expectEqual(expected_scans.len, parsed.scans.len);
		try std.testing.expectEqual(@field(fixture, "counts_" ++ key)[7], parsed.restart_interval);
		inline for (expected_scans, 0..) |expected, i| {
			const actual = parsed.scans[i];
			try std.testing.expectEqual(expected[0], actual.components.len);
			try std.testing.expectEqualSlices(u32, expected[1..], &.{ actual.ss, actual.se, actual.al, actual.ah, actual.last_needed_pass });
			for (actual.components, 0..) |component, c| try std.testing.expectEqualSlices(u32, &@field(fixture, "scan_components_" ++ key)[i][c], &.{ component.component, component.ac_table, component.dc_table });
			const scan_key = std.fmt.comptimePrint("{d}_{d}", .{ id, i });
			try std.testing.expectEqualSlices(u32, &@field(fixture, "reset_" ++ scan_key), actual.reset_points);
			const zeros = &@field(fixture, "zeros_" ++ scan_key);
			try std.testing.expectEqual(zeros.len, actual.extra_zero_runs.len);
			for (zeros, actual.extra_zero_runs) |zero, run| try std.testing.expectEqualSlices(u32, &zero, &.{ run.block, run.count });
		}
		try std.testing.expectEqualSlices(u8, &@field(fixture, "padding_" ++ key), parsed.padding);
		try std.testing.expectEqual(@field(fixture, "has_zero_padding_" ++ key), parsed.has_zero_padding_bit);
	}
}
test "JPEG reconstruction restores every upstream metadata payload byte" {
	inline for (0..6) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		var parsed = try jpeg.parse(std.testing.allocator, &@field(fixture, "bytes_" ++ key));
		defer parsed.deinit();
		inline for (0..@field(fixture, "counts_" ++ key)[4]) |i| try std.testing.expectEqualSlices(u8, &@field(fixture, std.fmt.comptimePrint("app_{d}_{d}", .{ id, i })), parsed.apps[i].data);
		inline for (0..@field(fixture, "counts_" ++ key)[5]) |i| try std.testing.expectEqualSlices(u8, &@field(fixture, std.fmt.comptimePrint("comment_{d}_{d}", .{ id, i })), parsed.comments[i].data);
		inline for (0..@field(fixture, "counts_" ++ key)[6]) |i| try std.testing.expectEqualSlices(u8, &@field(fixture, std.fmt.comptimePrint("inter_{d}_{d}", .{ id, i })), parsed.inter_marker[i]);
		try std.testing.expectEqualSlices(u8, &@field(fixture, "tail_" ++ key), parsed.tail);
	}
}
fn accepts(bytes: []const u8) !bool {
	var data = jpeg.parse(std.testing.allocator, bytes) catch |err| switch (err) {
		error.GenericError => return false,
		else => return err,
	};
	data.deinit();
	return true;
}
test "JPEG reconstruction mutation and truncation acceptance matches upstream over complete sets" {
	inline for (0..6) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		var bytes = @field(fixture, "bytes_" ++ key);
		const mutations = @field(fixture, "mutation_accept_" ++ key);
		try std.testing.expectEqual(bytes.len * 8, mutations.len);
		for (mutations, 0..) |expected, bit| {
			bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
			const actual = try accepts(&bytes);
			bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
			if (actual != expected) std.debug.print("record {d}, mutation bit {d}: upstream {any}, ours {any}\n", .{ id, bit, expected, actual });
			try std.testing.expectEqual(expected, actual);
		}
		for (@field(fixture, "truncation_accept_" ++ key), 0..) |expected, length| try std.testing.expectEqual(expected, try accepts(bytes[0..length]));
	}
}
fn allocationCase(allocator: std.mem.Allocator, bytes: []const u8) !void {
	var data = try jpeg.parse(allocator, bytes);
	defer data.deinit();
}
test "JPEG reconstruction releases owned data at every allocation failure" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{&fixture.bytes_4});
}
test "JPEG reconstruction rejects unused bytes after the compressed payload" {
	const allocator = std.testing.allocator;
	const bytes = try allocator.alloc(u8, fixture.bytes_0.len + 1);
	defer allocator.free(bytes);
	@memcpy(bytes[0..fixture.bytes_0.len], &fixture.bytes_0);
	for (0..256) |extra| {
		bytes[bytes.len - 1] = @intCast(extra);
		try std.testing.expect(!try accepts(bytes));
	}
}
