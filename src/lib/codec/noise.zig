//! Deterministic JPEG XL noise synthesis in Fixed.
const std = @import("std");
const sf = @import("../base/soft_float.zig");
const Error = @import("../base/status.zig").JxlError;
const BitReader = @import("../base/bit_reader.zig").BitReader;
const Image = @import("vardct_filters.zig").Image;
pub const Params = struct {
	lut: [8]u16 = @splat(0),
	pub fn decode(br: *BitReader) Error!Params {
		var out = Params{};
		for (&out.lut) |*value| value.* = @intCast(br.readBits(10));
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		return out;
	}
	pub fn hasAny(self: Params) bool {
		for (self.lut) |value| if (value > 1) return true;
		return false;
	}
	fn strength(self: Params, x: sf.Fixed) sf.Fixed {
		const scaled = sf.mul(x, sf.fromInt(6));
		if (scaled.m <= 0) return sf.div(sf.fromInt(self.lut[0]), sf.fromInt(1024));
		if (sf.cmp(scaled, sf.fromInt(7)) >= 0) return sf.div(sf.fromInt(self.lut[7]), sf.fromInt(1024));
		const index: usize = @intCast(sf.toIntTrunc(scaled));
		const fraction = sf.sub(scaled, sf.fromInt(@intCast(index)));
		return sf.div(sf.add(sf.fromInt(self.lut[index]), sf.mul(sf.fromInt(@as(i32, self.lut[index + 1]) - self.lut[index]), fraction)), sf.fromInt(1024));
	}
};
pub const Seed = struct { visible: u32 = 1, nonvisible: u32 = 0, group_dim: usize = 256 };
const Rng = struct {
	a: [8]u64,
	b: [8]u64,
	fn mix(input: u64) u64 {
		var z = input;
		z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
		z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
		return z ^ (z >> 31);
	}
	fn init(seed: Seed, x: u32, y: u32) Rng {
		var out: Rng = undefined;
		out.a[0] = mix(((@as(u64, seed.visible) << 32) | seed.nonvisible) +% 0x9e3779b97f4a7c15);
		out.b[0] = mix(((@as(u64, x) << 32) | y) +% 0x9e3779b97f4a7c15);
		for (1..8) |i| {
			out.a[i] = mix(out.a[i - 1]);
			out.b[i] = mix(out.b[i - 1]);
		}
		return out;
	}
	fn fill(self: *Rng) [16]u32 {
		var output: [16]u32 = undefined;
		for (0..8) |i| {
			var a = self.a[i];
			const b = self.b[i];
			const value = a +% b;
			self.a[i] = b;
			a ^= a << 23;
			self.b[i] = a ^ b ^ (a >> 18) ^ (b >> 5);
			output[i * 2] = @as(u32, @truncate(value)) >> 9;
			output[i * 2 + 1] = @as(u32, @truncate(value >> 32)) >> 9;
		}
		return output;
	}
};
fn mirror(value: isize, size: usize) usize {
	const n: isize = @intCast(size);
	const wrapped = @mod(value, 2 * n);
	return @intCast(if (wrapped < n) wrapped else 2 * n - 1 - wrapped);
}
fn convolve(raw: []const u32, width: usize, height: usize, c: usize, x: usize, y: usize) sf.Fixed {
	var sum: i64 = 0;
	for (0..5) |dy| for (0..5) |dx| {
		if (dx == 2 and dy == 2) continue;
		const px = mirror(@as(isize, @intCast(x)) + @as(isize, @intCast(dx)) - 2, width);
		const py = mirror(@as(isize, @intCast(y)) + @as(isize, @intCast(dy)) - 2, height);
		sum += raw[(c * height + py) * width + px];
	};
	const center: i64 = raw[(c * height + y) * width + x];
	// The omitted constant 1 cancels because the kernel sums to zero.
	return sf.div(sf.fromInt(sum - 24 * center), sf.fromInt(25 * (@as(i64, 1) << 21)));
}
pub fn apply(allocator: std.mem.Allocator, image: Image, params: Params, seed: Seed, cfl: [2]sf.Fixed) Error!void {
	try image.validate();
	if (seed.group_dim == 0) return error.GenericError;
	if (!params.hasAny()) return;
	const width = image.width;
	const height = image.height;
	const raw = try allocator.alloc(u32, image.data.len);
	defer allocator.free(raw);
	var gy: usize = 0;
	while (gy < height) : (gy += seed.group_dim) {
		var gx: usize = 0;
		while (gx < width) : (gx += seed.group_dim) {
			var rng = Rng.init(seed, @intCast(gx), @intCast(gy));
			const w = @min(seed.group_dim, width - gx);
			const h = @min(seed.group_dim, height - gy);
			for (0..3) |c| for (0..h) |y| {
				var x: usize = 0;
				while (x < w) : (x += 16) {
					const batch = rng.fill();
					const count = @min(16, w - x);
					@memcpy(raw[(c * height + gy + y) * width + gx + x ..][0..count], batch[0..count]);
				}
			};
		}
	}
	const area = width * height;
	for (0..height) |y| for (0..width) |x| {
		const p = y * width + x;
		const original_x = image.data[p];
		const original_y = image.data[area + p];
		var noise: [3]sf.Fixed = undefined;
		for (&noise, 0..) |*value, c| value.* = sf.mul(convolve(raw, width, height, c, x, y), sf.parse("0.22").?);
		const red = sf.mul(params.strength(sf.div(sf.add(original_y, original_x), sf.fromInt(2))), sf.div(sf.add(noise[0], sf.mul(sf.fromInt(127), noise[2])), sf.fromInt(128)));
		const green = sf.mul(params.strength(sf.div(sf.sub(original_y, original_x), sf.fromInt(2))), sf.div(sf.add(noise[1], sf.mul(sf.fromInt(127), noise[2])), sf.fromInt(128)));
		const sum = sf.add(red, green);
		image.data[p] = sf.add(original_x, sf.add(sf.sub(red, green), sf.mul(cfl[0], sum)));
		image.data[area + p] = sf.add(original_y, sum);
		image.data[2 * area + p] = sf.add(image.data[2 * area + p], sf.mul(cfl[1], sum));
	};
}

test "noise random batches match upstream seeds and wraparound" {
	const fixture = @import("noise_fixture.zig");
	for (fixture.seeds, fixture.random) |seed, expected| {
		var rng = Rng.init(.{ .visible = seed[0], .nonvisible = seed[1] }, seed[2], seed[3]);
		for (0..4) |batch| try std.testing.expectEqualSlices(u32, expected[batch * 16 ..][0..16], &rng.fill());
	}
}
fn checkStage(allocator: std.mem.Allocator, input: []const i32, expected: []const i32, id: usize) !void {
	const widths = [_]usize{ 1, 7, 16, 17, 31, 33, 65, 257 };
	const heights = [_]usize{ 1, 9, 3, 5, 2, 17, 3, 2 };
	const groups = [_]usize{ 1, 8, 16, 32, 256, 16, 32, 256 };
	const pixels = try allocator.alloc(sf.Fixed, input.len);
	defer allocator.free(pixels);
	for (input, pixels) |value, *dest| dest.* = sf.div(sf.fromInt(value), sf.fromInt(65536));
	var params = Params{};
	for (&params.lut, 0..) |*value, i| value.* = @intCast(if (id == 0) 0 else (id * 31 + i * 71) % 1024);
	try apply(allocator, .{ .width = widths[id], .height = heights[id], .data = pixels }, params, .{ .visible = @intCast(id + 1), .nonvisible = @intCast(id * 3), .group_dim = groups[id] }, .{ sf.Fixed.zero, sf.fromInt(1) });
	for (pixels, expected, 0..) |actual, wanted, index| {
		const difference = sf.sub(actual, sf.div(sf.fromInt(wanted), sf.fromInt(1 << 24)));
		const magnitude = if (difference.m < 0) sf.neg(difference) else difference;
		if (sf.cmp(magnitude, sf.parse("0.00000762939453125").?) > 0) {
			std.debug.print("noise stage id={d} sample={d}\n", .{ id, index });
			return error.TestUnexpectedResult;
		}
	}
}
test "noise convolution and intensity lookup match upstream stages" {
	@setEvalBranchQuota(20000);
	const fixture = @import("noise_fixture.zig");
	inline for (0..8) |id| {
		const key = std.fmt.comptimePrint("{d}", .{id});
		try @call(.never_inline, checkStage, .{ std.testing.allocator, &@field(fixture, "input_" ++ key), &@field(fixture, "output_" ++ key), id });
	}
}
test "noise parameter decoding rejects every truncated prefix" {
	const bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
	var full = BitReader.init(&bytes);
	const params = try Params.decode(&full);
	try std.testing.expectEqual([_]u16{@as(u16, 1023)} ** 8, params.lut);
	try std.testing.expectEqual(80, full.totalBitsConsumed());
	for (0..bytes.len) |size| {
		var truncated = BitReader.init(bytes[0..size]);
		try std.testing.expectError(error.NotEnoughBytes, Params.decode(&truncated));
	}
}
fn allocationCase(allocator: std.mem.Allocator) !void {
	const fixture = @import("noise_fixture.zig");
	try checkStage(allocator, &fixture.input_1, &fixture.output_1, 1);
}
test "noise allocation failures release random planes" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}
