const std = @import("std");
const fast = @import("lib/base/binary32.zig");
const exact = @import("lib/base/binary32_wide_control.zig");
const Mode = enum { native, wide, scalar64 };
fn calculate(comptime mode: Mode, a: u32, b: u32, c: u32) u32 {
	return switch (mode) {
		.native => @bitCast(@mulAdd(f32, @bitCast(a), @bitCast(b), @bitCast(c))),
		.wide => exact.fma(a, b, c),
		.scalar64 => fast.fma(a, b, c),
	};
}
fn batch(comptime mode: Mode, a: []const u32, b: []const u32, c: []const u32, output: []u32) void {
	for (a, b, c, output) |x, y, z, *dest| dest.* = calculate(mode, x, y, z);
	std.mem.doNotOptimizeAway(output);
}
fn measure(comptime mode: Mode, init: std.process.Init, writer: *std.Io.Writer) !void {
	const count = 4096;
	const repeat = 1024;
	const storage = try init.gpa.alloc(u32, count * 4);
	defer init.gpa.free(storage);
	const a = storage[0..count];
	const b = storage[count..][0..count];
	const c = storage[2 * count ..][0..count];
	const output = storage[3 * count ..];
	var rng = std.Random.DefaultPrng.init(0x4a584c);
	for (a, b, c) |*x, *y, *z| {
		x.* = @bitCast(@as(f32, @floatFromInt(@as(i64, rng.random().int(u12)) - 2048)) / 1024);
		y.* = @bitCast(@as(f32, @floatFromInt(@as(i64, rng.random().int(u12)) + 1)) / 1024);
		z.* = @bitCast(@as(f32, @floatFromInt(@as(i64, rng.random().int(u12)) - 2048)) / 1024);
	}
	for (0..8) |_| batch(mode, a, b, c, output);
	for (a, b, c, output) |x, y, z, got| if (got != calculate(.native, x, y, z)) return error.IncorrectKernel;
	const wall_start = std.Io.Timestamp.now(init.io, .awake).nanoseconds;
	const cpu_start = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds;
	for (0..repeat) |_| batch(mode, a, b, c, output);
	const cpu = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds - cpu_start;
	const wall = std.Io.Timestamp.now(init.io, .awake).nanoseconds - wall_start;
	var checksum: u64 = 0;
	for (output) |value| checksum +%= value;
	try writer.print("{{\"mode\":\"{s}\",\"count\":{d},\"repeat\":{d},\"cpu_ns\":{d},\"wall_ns\":{d},\"checksum\":{d}}}\n", .{ @tagName(mode), count, repeat, cpu, wall, checksum });
	try writer.flush();
}
pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) return error.BenchmarkRequiresReleaseFast;
	var buffer: [4096]u8 = undefined;
	var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
	inline for (comptime std.meta.tags(Mode)) |mode| try measure(mode, init, &stdout.interface);
}
