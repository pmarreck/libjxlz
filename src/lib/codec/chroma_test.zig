const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const Chroma = @import("frame_header.zig").YCbCrChromaSubsampling;
const fixture = @import("chroma_fixture.zig");

test "chroma sampling 64 upstream wire combinations" {
	for (fixture.cases, 0..) |expected, wire| {
		const data = [_]u8{@intCast(wire)};
		var br = BitReader.init(&data);
		const chroma = Chroma.readFromBitStream(&br);
		var actual: [9]u8 = undefined;
		for (0..3) |c| {
			actual[2 * c] = chroma.hShift(c);
			actual[2 * c + 1] = chroma.vShift(c);
		}
		actual[6] = chroma.maxHShift();
		actual[7] = chroma.maxVShift();
		actual[8] = @intFromBool(chroma.is444());
		try std.testing.expectEqualSlices(u8, &expected, &actual);
		try std.testing.expectEqual(@as(usize, 6), br.totalBitsConsumed());
		try br.close();
	}
}
