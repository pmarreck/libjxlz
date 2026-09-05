const std = @import("std");
const metadata_mod = @import("image_metadata.zig");
const color = @import("color_encoding.zig");
const xyb = @import("xyb.zig");
const fixture = @import("color_matrix_fixture.zig");
fn metadataFor(metadata: *metadata_mod.ImageMetadata, id: usize) void {
	metadata.* = .{};
	metadata.xyb_encoded = true;
	metadata.tone_mapping.intensity_target = if (id % 2 == 0) 255 else 1000;
	metadata.color_encoding = .{};
	metadata.color_encoding.tf.transfer_function = .linear;
	metadata.color_encoding.color_space = if (id >= 32) .gray else .rgb;
	metadata.color_encoding.primaries = ([_]color.Primaries{ .srgb, .p3, .bt2100, .custom })[if (id >= 32) 0 else id / 8];
	metadata.color_encoding.white_point = ([_]color.WhitePoint{ .d65, .e, .dci, .custom })[(id / 2) % 4];
	metadata.color_encoding.white = .{ .x = 321000, .y = 345000 };
	metadata.color_encoding.red = .{ .x = 670000, .y = 330000 };
	metadata.color_encoding.green = .{ .x = 210000, .y = 710000 };
	metadata.color_encoding.blue = .{ .x = 140000, .y = 80000 };
}
test "output matrix matches upstream primaries white points and custom opsin" {
	@setEvalBranchQuota(20000);
	const metadata = try std.testing.allocator.create(metadata_mod.ImageMetadata);
	defer std.testing.allocator.destroy(metadata);
	inline for (0..40) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		metadataFor(metadata, id);
		var transform = metadata_mod.CustomTransformData{};
		const source = @field(fixture, "source_" ++ key);
		transform.opsin_inverse_matrix.custom = id % 2 != 0;
		if (id % 2 != 0) {
			for (0..3) |r| for (0..3) |c| {
				transform.opsin_inverse_matrix.inverse_matrix[r][c] = @bitCast(source[r][c]);
			};
		}
		const params = try xyb.opsinParams(metadata, &transform);
		const expected = @field(fixture, "matrix_" ++ key);
		const expected_luminance = @field(fixture, "luminance_" ++ key);
		for (params.luminances, expected_luminance) |actual, bits| try std.testing.expectApproxEqAbs(@as(f32, @bitCast(bits)), actual, 0.000001);
		for (params.inverse_matrix, expected) |row, bits| for (row, bits) |actual, raw| {
			const wanted: f32 = @bitCast(raw);
			if (!std.math.isFinite(actual) or @abs(actual - wanted) > 0.00001 + 0.000001 * @abs(wanted)) {
				std.debug.print("matrix id={d} actual={d} expected={d}\n", .{ id, actual, wanted });
				return error.TestUnexpectedResult;
			}
		};
	}
}

test "structured coordinates match upstream standard and custom profiles" {
	@setEvalBranchQuota(20000);
	const metadata = try std.testing.allocator.create(metadata_mod.ImageMetadata);
	defer std.testing.allocator.destroy(metadata);
	inline for (0..40) |id| {
		metadataFor(metadata, id);
		const white = metadata.color_encoding.whitePointXY();
		const primaries = metadata.color_encoding.primariesXY();
		const expected = @field(fixture, std.fmt.comptimePrint("original_xy_{d}", .{id}));
		for (white, expected[0..2]) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, actual, 0.000000001);
		if (id < 32) {
			for (primaries[0], expected[2..4]) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, actual, 0.000000001);
			for (primaries[1], expected[4..6]) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, actual, 0.000000001);
			for (primaries[2], expected[6..8]) |actual, wanted| try std.testing.expectApproxEqAbs(wanted, actual, 0.000000001);
		}
	}
}
