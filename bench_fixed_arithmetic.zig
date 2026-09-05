const std = @import("std");
const sf = @import("src/lib/base/soft_float.zig");
pub const Operation = enum { add, multiply, divide, stencil };
fn calculate(comptime T: type, comptime op: Operation, a: T, b: T, c: T) T {
	if (T == sf.Fixed) return switch (op) {
		.add => sf.add(a, b),
		.multiply => sf.mul(a, b),
		.divide => sf.div(a, b),
		.stencil => sf.add(sf.mul(sf.add(a, c), comptime from(T, 256)), sf.mul(b, comptime from(T, 512))),
	};
	return switch (op) {
		.add => a + b,
		.multiply => a * b,
		.divide => a / b,
		.stencil => (a + c) * 0.25 + b * 0.5,
	};
}
fn from(comptime T: type, numerator: i64) T {
	return if (T == sf.Fixed) sf.div(sf.fromInt(numerator), sf.fromInt(1024)) else @as(T, @floatFromInt(numerator)) / 1024;
}
fn real(comptime T: type, value: T) f64 {
	return if (T == sf.Fixed) @as(f64, @floatFromInt(value.m)) * std.math.exp2(@as(f64, @floatFromInt(value.e - 62))) else value;
}
test "arithmetic benchmark kernels agree with independent scalar expectations" {
	inline for (.{ sf.Fixed, f32, f64 }) |T| {
		const a = from(T, -1536);
		const b = from(T, 2048);
		const c = from(T, 512);
		try std.testing.expectApproxEqAbs(@as(f64, 0.5), real(T, calculate(T, .add, a, b, c)), 0.000001);
		try std.testing.expectApproxEqAbs(@as(f64, -3), real(T, calculate(T, .multiply, a, b, c)), 0.000001);
		try std.testing.expectApproxEqAbs(@as(f64, -0.75), real(T, calculate(T, .divide, a, b, c)), 0.000001);
		try std.testing.expectApproxEqAbs(@as(f64, 0.75), real(T, calculate(T, .stencil, a, b, c)), 0.000001);
	}
}

// O(n), independent pixels. Native controls may auto-vectorize.
fn batch(comptime T: type, comptime op: Operation, a: []const T, b: []const T, c: []const T, output: []T) void {
	for (a, b, c, output) |av, bv, cv, *dest| dest.* = calculate(T, op, av, bv, cv);
	std.mem.doNotOptimizeAway(output);
}
fn measure(comptime T: type, comptime op: Operation, init: std.process.Init, count: usize, repeat: usize, writer: *std.Io.Writer) !void {
	const storage = try init.gpa.alloc(T, count * 4);
	defer init.gpa.free(storage);
	const a = storage[0..count];
	const b = storage[count..][0..count];
	const c = storage[2 * count ..][0..count];
	const output = storage[3 * count ..];
	var rng = std.Random.DefaultPrng.init(0x4a584c);
	for (a, b, c) |*av, *bv, *cv| {
		av.* = from(T, @as(i64, rng.random().int(u12)) - 2048);
		bv.* = from(T, @as(i64, rng.random().int(u12)) + 1);
		cv.* = from(T, @as(i64, rng.random().int(u12)) - 2048);
	}
	for (0..8) |_| batch(T, op, a, b, c, output);
	var max_error: f64 = 0;
	for (a, b, c, output) |av, bv, cv, actual| {
		const expected = calculate(f64, op, real(T, av), real(T, bv), real(T, cv));
		const delta = @abs(real(T, actual) - expected);
		if (!std.math.isFinite(real(T, actual)) or delta > 0.0001) return error.IncorrectKernel;
		max_error = @max(max_error, delta);
	}
	const wall_start = std.Io.Timestamp.now(init.io, .awake).nanoseconds;
	const cpu_start = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds;
	for (0..repeat) |_| batch(T, op, a, b, c, output);
	const cpu_ns = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds - cpu_start;
	const wall_ns = std.Io.Timestamp.now(init.io, .awake).nanoseconds - wall_start;
	var checksum: f64 = 0;
	for (output) |value| checksum += real(T, value);
	try writer.print("{{\"type\":\"{s}\",\"operation\":\"{s}\",\"count\":{d},\"repeat\":{d},\"cpu_ns\":{d},\"wall_ns\":{d},\"max_error\":{d},\"checksum\":{d}}}\n", .{ if (T == sf.Fixed) "Fixed" else @typeName(T), @tagName(op), count, repeat, cpu_ns, wall_ns, max_error, checksum });
	try writer.flush();
}
pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) return error.BenchmarkRequiresReleaseFast;
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len == 2 and std.mem.eql(u8, args[1], "--vardct-fixture")) {
		try std.Io.File.stdout().writeStreamingAll(init.io, &@import("src/lib/codec/vardct_frame_fixture.zig").bytes_3);
		return;
	}
	if (args.len != 4) return error.ExpectedTypeCountRepeat;
	const count = try std.fmt.parseInt(usize, args[2], 10);
	const repeat = try std.fmt.parseInt(usize, args[3], 10);
	if (count == 0 or count > 1 << 20 or repeat == 0) return error.InvalidSize;
	var buffer: [4096]u8 = undefined;
	var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
	inline for (.{ sf.Fixed, f32, f64 }) |T| {
		if (std.mem.eql(u8, args[1], if (T == sf.Fixed) "Fixed" else @typeName(T))) {
			inline for (comptime std.meta.tags(Operation)) |op| try measure(T, op, init, count, repeat, &stdout.interface);
			return;
		}
	}
	return error.UnknownType;
}
