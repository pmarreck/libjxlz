const std = @import("std");
const jxl = @import("../root.zig");
const fixture = @import("float_frame_fixture.zig");
fn check(allocator: std.mem.Allocator, data: []const u8, expected: []const u32, colors: usize, id: usize, linear: bool) !void {
	const metadata = try allocator.create(jxl.codec.image_metadata.CodecMetadata);
	defer allocator.destroy(metadata);
	metadata.* = .{};
	var br = jxl.base.bit_reader.BitReader.init(data[2..]);
	metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
	metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
	metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
	try br.jumpToByteBoundary();
	try br.close();
	var session = jxl.codec.decode_session.Session.init(allocator);
	defer session.deinit();
	var dec = try session.decode(metadata, data[2 + br.totalBitsConsumed() / 8 ..]);
	defer dec.deinit();
	const image = dec.rendered_image orelse return error.TestUnexpectedResult;
	const xyb = metadata.m.xyb_encoded and !dec.rendered_in_output_space;
	const params = try jxl.codec.xyb.opsinParams(&metadata.m, &metadata.transform_data);
	const channels = colors + metadata.m.num_extra_channels;
	for (0..image.ysize) |y| for (0..image.xsize) |x| {
		const rgb = if (xyb and linear) jxl.codec.xyb.xybToLinearRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params) else if (xyb) try jxl.codec.xyb.toOutputRgb(image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x], &params, &metadata.m) else [3]f32{ image.rowConst(y, 0)[x], image.rowConst(y, 1)[x], image.rowConst(y, 2)[x] };
		for (0..channels) |c| {
			const actual = if (c < colors) rgb[c] else image.rowConst(y, 3 + c - colors)[x];
			const wanted: f32 = @bitCast(expected[(y * image.xsize + x) * channels + c]);
			// Upstream's rational sRGB approximation diverges from the power formula
			// above 1. Linear output is checked separately at the tighter tolerance.
			const tolerance: f32 = if (xyb and !linear and c < colors and @abs(wanted) > 1) 1.0 / 255.0 else 0.0001;
			if (!std.math.isFinite(actual) or @abs(actual - wanted) > tolerance) {
				std.debug.print("float frame id={d} x={d} y={d} c={d} actual={d} expected={d}\n", .{ id, x, y, c, actual, wanted });
				return error.TestUnexpectedResult;
			}
		}
	};
}
test "floating color and extra frames match upstream output" {
	@setEvalBranchQuota(50000);
	inline for (0..20) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, check, .{ std.testing.allocator, &@field(fixture, "codestream_" ++ key), &@field(fixture, "float_bits_" ++ key), @as(usize, if (id == 6 or id == 7) 1 else 3), id, false });
	}
}
test "float linear XYB output matches upstream before transfer conversion" {
	@setEvalBranchQuota(50000);
	inline for (8..16) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, check, .{ std.testing.allocator, &@field(fixture, "codestream_" ++ key), &@field(fixture, "linear_bits_" ++ key), @as(usize, 3), id, true });
	}
}
fn allocationCase(allocator: std.mem.Allocator, comptime id: usize) !void {
	const key = std.fmt.comptimePrint("{d}", .{id});
	try check(allocator, &@field(fixture, "codestream_" ++ key), &@field(fixture, "float_bits_" ++ key), 3, id, false);
}
test "floating frame allocation failures release modular and VarDCT state" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
		fn run(a: std.mem.Allocator) !void {
			try allocationCase(a, 3);
		}
	}.run, .{});
	try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
		fn run(a: std.mem.Allocator) !void {
			try allocationCase(a, 13);
		}
	}.run, .{});
}
