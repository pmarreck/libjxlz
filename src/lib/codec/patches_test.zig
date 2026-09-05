const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const patch = @import("patches.zig");
const fixture = @import("patches_fixture.zig");
fn checkHeight(allocator: std.mem.Allocator, comptime count: usize, height: usize) !void {
	@setEvalBranchQuota(20000);
	inline for (0..count) |id| {
		const extras = id / 8;
		const channels = 3 + extras;
		const data = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const expected = @field(fixture, "pixels_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const storage = try allocator.alloc(sf.Fixed, 4 * 8 * 6 * channels);
		defer allocator.free(storage);
		var refs: [4]patch.Reference = undefined;
		for (&refs, 0..) |*ref, r| {
			const values = storage[r * 8 * 6 * channels ..][0 .. 8 * 6 * channels];
			for (0..channels) |c| for (0..6) |y| for (0..8) |x| {
				values[(c * 6 + y) * 8 + x] = sf.div(sf.fromInt(@as(i64, @intCast((x * 3 + y * 7 + c * 5 + r * 11) % 19)) - 4), sf.fromInt(8));
			};
			ref.* = .{ .image = .{ .width = 8, .height = 6, .channels = channels, .data = values }, .pre_color = true };
		}
		const before = try allocator.dupe(sf.Fixed, storage);
		defer allocator.free(before);
		var br = jxl.base.bit_reader.BitReader.init(&data);
		var dictionary = try patch.Dictionary.decode(allocator, &br, 16, 12, extras, &refs);
		defer dictionary.deinit();
		try std.testing.expectEqual(@field(fixture, "bits_" ++ std.fmt.comptimePrint("{d}", .{id})), br.totalBitsConsumed());
		try std.testing.expectEqual(@field(fixture, "refs_" ++ std.fmt.comptimePrint("{d}", .{id})), dictionary.refs);
		try std.testing.expectEqual(@field(fixture, "uses_" ++ std.fmt.comptimePrint("{d}", .{id})), dictionary.uses_extra);
		try std.testing.expectEqual(5, dictionary.positions.items.len);
		const output = try allocator.alloc(sf.Fixed, 16 * height * channels);
		defer allocator.free(output);
		for (0..channels) |c| for (0..height) |y| for (0..16) |x| {
			output[(c * height + y) * 16 + x] = sf.div(sf.fromInt(@as(i64, @intCast((x * 5 + y * 3 + c * 7) % 17)) - 3), sf.fromInt(8));
		};
		var info: [extras]patch.blend.Extra = undefined;
		for (&info, 0..) |*item, e| item.* = .{ .is_alpha = extras != 2 or e != 0, .associated = id % 2 != 0 };
		try dictionary.apply(.{ .width = 16, .height = height, .channels = channels, .data = output }, &refs, &info);
		for (output, 0..) |actual, index| {
			const wanted = expected[(index / (16 * height) * 12 + (index / 16) % height) * 16 + index % 16];
			const delta = sf.sub(actual, sf.div(sf.fromInt(wanted), sf.fromInt(1 << 16)));
			try std.testing.expect(sf.cmp(if (delta.m < 0) sf.neg(delta) else delta, sf.div(sf.fromInt(2), sf.fromInt(1 << 16))) <= 0);
		}
		try std.testing.expectEqualSlices(sf.Fixed, before, storage);
	}
}
test "patch dictionaries match upstream parsing and every blended pixel" {
	try checkHeight(std.testing.allocator, 24, 12);
}
test "patch dictionaries clip padded destinations to visible rows" {
	try checkHeight(std.testing.allocator, 24, 9);
}
fn one(allocator: std.mem.Allocator) !void {
	try checkHeight(allocator, 1, 12);
}
test "patch dictionary allocation failures release all state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, one, .{});
}
fn references(allocator: std.mem.Allocator, channels: usize) !struct { storage: []sf.Fixed, refs: [4]patch.Reference } {
	const storage = try allocator.alloc(sf.Fixed, 4 * 8 * 6 * channels);
	@memset(storage, sf.Fixed.zero);
	var refs: [4]patch.Reference = undefined;
	for (&refs, 0..) |*ref, r| ref.* = .{ .image = .{ .width = 8, .height = 6, .channels = channels, .data = storage[r * 8 * 6 * channels ..][0 .. 8 * 6 * channels] }, .pre_color = true };
	return .{ .storage = storage, .refs = refs };
}
test "patch dictionaries reject truncated prefixes and unavailable reference sets" {
	@setEvalBranchQuota(20000);
	inline for (0..24) |id| {
		const data = @field(fixture, "bytes_" ++ std.fmt.comptimePrint("{d}", .{id}));
		const owned = try references(std.testing.allocator, 3 + id / 8);
		defer std.testing.allocator.free(owned.storage);
		for (0..data.len) |end| {
			var br = jxl.base.bit_reader.BitReader.init(data[0..end]);
			if (patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, id / 8, &owned.refs)) |value| {
				var result = value;
				result.deinit();
				return error.TestUnexpectedResult;
			} else |err| try std.testing.expect(err == error.NotEnoughBytes or err == error.GenericError);
		}
		const mask = @field(fixture, "refs_" ++ std.fmt.comptimePrint("{d}", .{id}));
		for (0..4) |slot| {
			var missing = owned.refs;
			missing[slot] = .{};
			var br = jxl.base.bit_reader.BitReader.init(&data);
			if (mask & (@as(u8, 1) << @as(u3, @intCast(slot))) != 0) {
				try std.testing.expectError(error.GenericError, patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, id / 8, &missing));
			} else {
				var result = try patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, id / 8, &missing);
				result.deinit();
			}
			var post_color = owned.refs;
			post_color[slot].pre_color = false;
			br = jxl.base.bit_reader.BitReader.init(&data);
			if (mask & (@as(u8, 1) << @as(u3, @intCast(slot))) != 0) {
				try std.testing.expectError(error.GenericError, patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, id / 8, &post_color));
			} else {
				var result = try patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, id / 8, &post_color);
				result.deinit();
			}
		}
	}
}
test "patch application rejects aliased references before modifying any pixel" {
	var owned = try references(std.testing.allocator, 3);
	defer std.testing.allocator.free(owned.storage);
	var br = jxl.base.bit_reader.BitReader.init(&fixture.bytes_0);
	var dictionary = try patch.Dictionary.decode(std.testing.allocator, &br, 16, 12, 0, &owned.refs);
	defer dictionary.deinit();
	const output = try std.testing.allocator.alloc(sf.Fixed, 16 * 12 * 3);
	defer std.testing.allocator.free(output);
	@memset(output, sf.fromInt(7));
	owned.refs[1].image.?.data = output[0 .. 8 * 6 * 3];
	try std.testing.expectError(error.GenericError, dictionary.apply(.{ .width = 16, .height = 12, .channels = 3, .data = output }, &owned.refs, &.{}));
	for (output) |value| try std.testing.expectEqual(sf.fromInt(7), value);
}
test "patch sampling classifies equal and unequal factor sets" {
	var dictionary = patch.Dictionary{ .allocator = std.testing.allocator };
	defer dictionary.deinit();
	const factors = [_]u32{ 1, 2, 4, 8 };
	var accepted: usize = 0;
	var rejected: usize = 0;
	for ([_]bool{ false, true }) |uses| for (factors) |color| for (factors) |a| for (factors) |b| {
		dictionary.uses_extra = uses;
		if (uses and color != 1 and (a != color or b != color)) {
			try std.testing.expectError(error.GenericError, dictionary.validateSampling(color, &.{ a, b }));
			rejected += 1;
		} else {
			try dictionary.validateSampling(color, &.{ a, b });
			accepted += 1;
		}
	};
	try std.testing.expectEqual(83, accepted);
	try std.testing.expectEqual(45, rejected);
}
