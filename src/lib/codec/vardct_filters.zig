//! Gaborish and EPF over planar Fixed pixels with mirrored image borders.
const std = @import("std");
const sf = @import("../root.zig").base.soft_float;
const JxlError = @import("../root.zig").base.status.JxlError;
const one = sf.fromInt(1);
const inv_sigma_num = sf.parse("-1.1715728752538099024").?;
const min_sigma = sf.parse("-3.90524291751269967465540850526868").?;
pub const Params = struct {
	gaborish: [3][2]sf.Fixed = @splat(.{ sf.mul(sf.parse("1.1").?, sf.parse("0.104699568").?), sf.mul(sf.parse("1.1").?, sf.parse("0.055680538").?) }),
	channel_scale: [3]sf.Fixed = .{ sf.fromInt(40), sf.fromInt(5), sf.parse("3.5").? },
	pass0_scale: sf.Fixed = sf.parse("0.9").?,
	pass2_scale: sf.Fixed = sf.parse("6.5").?,
	border_multiplier: sf.Fixed = sf.div(sf.fromInt(2), sf.fromInt(3)),
	quant_mul: sf.Fixed = sf.parse("0.46").?,
	sharp_lut: [8]sf.Fixed = blk: {
		@setEvalBranchQuota(10000);
		var values: [8]sf.Fixed = undefined;
		for (&values, 0..) |*v, i| v.* = sf.div(sf.fromInt(i), sf.fromInt(7));
		break :blk values;
	},
	pub fn fromHeader(header: @import("../root.zig").codec.loop_filter.LoopFilter) JxlError!Params {
		var result = Params{};
		if (header.gab_custom) {
			result.gaborish = .{ .{ try fromF32(header.gab_x_weight1), try fromF32(header.gab_x_weight2) }, .{ try fromF32(header.gab_y_weight1), try fromF32(header.gab_y_weight2) }, .{ try fromF32(header.gab_b_weight1), try fromF32(header.gab_b_weight2) } };
		}
		if (header.epf_weight_custom) for (header.epf_channel_scale, &result.channel_scale) |value, *dest| {
			dest.* = try fromF32(value);
		};
		if (header.epf_sigma_custom) {
			result.pass0_scale = try fromF32(header.epf_pass0_sigma_scale);
			result.pass2_scale = try fromF32(header.epf_pass2_sigma_scale);
			result.border_multiplier = try fromF32(header.epf_border_sad_mul);
			result.quant_mul = try fromF32(header.epf_quant_mul);
		}
		if (header.epf_sharp_custom) for (header.epf_sharp_lut, &result.sharp_lut) |value, *dest| {
			dest.* = try fromF32(value);
		};
		return result;
	}
};

fn fromF32(value: f32) JxlError!sf.Fixed {
	const bits: u32 = @bitCast(value);
	const exponent = (bits >> 23) & 255;
	if (exponent == 255) return error.GenericError;
	const magnitude: i64 = (bits & 0x7fffff) | @as(u32, if (exponent == 0) 0 else 1 << 23);
	return sf.norm(if (bits >> 31 != 0) -magnitude else magnitude, if (exponent == 0) -87 else @as(i32, @intCast(exponent)) - 88);
}

pub fn inverseSigma(quant_scale: sf.Fixed, quant: u32, sharp: sf.Fixed, quant_mul: sf.Fixed) JxlError!sf.Fixed {
	if (quant_scale.m <= 0 or quant == 0) return error.GenericError;
	const sigma_quant = sf.div(quant_mul, sf.mul(sf.mul(quant_scale, sf.fromInt(quant)), inv_sigma_num));
	const raw = sf.mul(sigma_quant, sharp);
	const ceiling = sf.parse("-0.0001").?;
	return sf.div(one, if (sf.cmp(raw, ceiling) < 0) raw else ceiling);
}
pub const Image = struct {
	width: usize,
	height: usize,
	data: []sf.Fixed,
	fn validate(self: Image) JxlError!void {
		if (self.width == 0 or self.height == 0 or self.width > std.math.maxInt(isize) / 2 or self.height > std.math.maxInt(isize) / 2) return error.GenericError;
		const area = std.math.mul(usize, self.width, self.height) catch return error.GenericError;
		const size = std.math.mul(usize, area, 3) catch return error.GenericError;
		if (self.data.len != size) return error.GenericError;
	}
	fn at(self: Image, c: usize, x: isize, y: isize) sf.Fixed {
		return self.data[c * self.width * self.height + mirror(y, self.height) * self.width + mirror(x, self.width)];
	}
};
fn mirror(coordinate: isize, size: usize) usize {
	const n: isize = @intCast(size);
	const wrapped = @mod(coordinate, 2 * n);
	return @intCast(if (wrapped < n) wrapped else 2 * n - 1 - wrapped);
}
pub fn gaborish(allocator: std.mem.Allocator, image: Image, params: Params) JxlError!void {
	try image.validate();
	var weights: [3][3]sf.Fixed = undefined;
	for (params.gaborish, 0..) |w, c| {
		const denominator = sf.add(one, sf.mul(sf.fromInt(4), sf.add(w[0], w[1])));
		const magnitude = if (denominator.m < 0) sf.neg(denominator) else denominator;
		if (sf.cmp(magnitude, sf.parse("0.00000001").?) < 0) return error.GenericError;
		weights[c] = .{ sf.div(one, denominator), sf.div(w[0], denominator), sf.div(w[1], denominator) };
	}
	const output = try allocator.alloc(sf.Fixed, image.data.len);
	defer allocator.free(output);
	for (0..3) |c| for (0..image.height) |uy| for (0..image.width) |ux| {
		const x: isize = @intCast(ux);
		const y: isize = @intCast(uy);
		const sides = sf.add(sf.add(image.at(c, x - 1, y), image.at(c, x + 1, y)), sf.add(image.at(c, x, y - 1), image.at(c, x, y + 1)));
		const corners = sf.add(sf.add(image.at(c, x - 1, y - 1), image.at(c, x + 1, y - 1)), sf.add(image.at(c, x - 1, y + 1), image.at(c, x + 1, y + 1)));
		output[(c * image.height + uy) * image.width + ux] = sf.add(sf.mul(image.at(c, x, y), weights[c][0]), sf.add(sf.mul(sides, weights[c][1]), sf.mul(corners, weights[c][2])));
	};
	@memcpy(image.data, output);
}
const Offset = struct { x: isize, y: isize };
const adjacent = [4]Offset{ .{ .x = 0, .y = -1 }, .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
const plus = [5]Offset{ .{ .x = 0, .y = 0 }, .{ .x = -1, .y = 0 }, .{ .x = 0, .y = -1 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 } };
const wide = [12]Offset{ .{ .x = 0, .y = -2 }, .{ .x = -1, .y = -1 }, .{ .x = 0, .y = -1 }, .{ .x = 1, .y = -1 }, .{ .x = -2, .y = 0 }, .{ .x = -1, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = -1, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 2 } };
pub fn epf(allocator: std.mem.Allocator, image: Image, params: Params, sigma: []const sf.Fixed, stage: u2) JxlError!void {
	try image.validate();
	const blocks_width = (image.width + 7) / 8;
	if (stage > 2 or sigma.len != blocks_width * ((image.height + 7) / 8)) return error.GenericError;
	const output = try allocator.dupe(sf.Fixed, image.data);
	defer allocator.free(output);
	const offsets: []const Offset = if (stage == 0) &wide else &adjacent;
	const patch: []const Offset = if (stage == 2) plus[0..1] else &plus;
	const stage_scale = sf.mul(sf.parse("1.65").?, switch (stage) {
		0 => params.pass0_scale,
		1 => one,
		2 => params.pass2_scale,
		else => unreachable,
	});
	for (0..image.height) |uy| for (0..image.width) |ux| {
		const block_sigma = sigma[(uy / 8) * blocks_width + ux / 8];
		if (sf.cmp(block_sigma, min_sigma) < 0) continue;
		const x: isize = @intCast(ux);
		const y: isize = @intCast(uy);
		const border = ux % 8 == 0 or ux % 8 == 7 or uy % 8 == 0 or uy % 8 == 7;
		const multiplier = sf.mul(block_sigma, sf.mul(stage_scale, if (border) params.border_multiplier else one));
		var weight_sum = one;
		var sums: [3]sf.Fixed = .{ image.at(0, x, y), image.at(1, x, y), image.at(2, x, y) };
		for (offsets) |offset| {
			var sad = sf.Fixed.zero;
			for (0..3) |c| {
				var channel_sad = sf.Fixed.zero;
				for (patch) |p| {
					const delta = sf.sub(image.at(c, x + p.x, y + p.y), image.at(c, x + p.x + offset.x, y + p.y + offset.y));
					channel_sad = sf.add(channel_sad, if (delta.m < 0) sf.neg(delta) else delta);
				}
				sad = sf.add(sad, sf.mul(channel_sad, params.channel_scale[c]));
			}
			const weight = sf.add(one, sf.mul(sad, multiplier));
			if (weight.m <= 0) continue;
			weight_sum = sf.add(weight_sum, weight);
			for (&sums, 0..) |*sum, c| sum.* = sf.add(sum.*, sf.mul(weight, image.at(c, x + offset.x, y + offset.y)));
		}
		for (sums, 0..) |sum, c| output[(c * image.height + uy) * image.width + ux] = sf.div(sum, weight_sum);
	};
	@memcpy(image.data, output);
}
