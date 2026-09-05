const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const fixture = @import("large_quant_fixture.zig");
test "large VarDCT dequant matrices match upstream samples for all six strategies" {
	var matrices = jxl.codec.dec_frame.DequantMatrices{};
	defer matrices.deinit(std.testing.allocator);
	try matrices.ensureComputed(std.testing.allocator, ((@as(u32, 1) << 27) - 1) ^ ((@as(u32, 1) << 21) - 1));
	for (21..27) |raw| for (0..3) |c| {
		const matrix = matrices.matrix(@enumFromInt(raw), c);
		for (fixture.samples[raw - 21][c], 0..) |expected, i| {
			const index = if (i == 0) 0 else if (i == 1) matrix.len - 1 else (i * 4051 + 17) % matrix.len;
			const want = sf.div(sf.fromInt(expected), sf.fromInt(@as(i64, 1) << 40));
			const delta = sf.sub(matrix[index], want);
			const abs = if (delta.m < 0) sf.neg(delta) else delta;
			try std.testing.expect(sf.cmp(abs, sf.div(want, sf.fromInt(100000))) <= 0);
		}
	};
}
