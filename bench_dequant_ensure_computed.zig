// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// Kernel benchmark for VarDCT dequant table materialization.
// First live path: DCT8 library `GetQuantWeights` (distance-band Mult,
// radial sqrt, geometric interpolate) plus invert. Larger DCT sizes and
// public-C VarDCT decode vs libjxl are later scenarios; `./bm` will not
// seed history until one of those is worth quoting.

const std = @import("std");
const dec_frame = @import("src/lib/codec/dec_frame.zig");
const BitReader = @import("src/lib/base/bit_reader.zig").BitReader;
const sf = @import("src/lib/base/soft_float.zig");

const testing = std.testing;

pub const WorkloadConfig = struct {
	repeat: usize = 1,
};

pub const WorkloadResult = struct {
	checksum: u64 = 0,
	cells: u64 = 0,
};

fn mixChecksum(hash: *u64, value: u64) void {
	hash.* ^=
		value +% 0x9E3779B97F4A7C15 +%
		(hash.* << 6) +%
		(hash.* >> 2);
}

pub fn runDequantBenchmark(allocator: std.mem.Allocator, cfg: WorkloadConfig) !WorkloadResult {
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = dec_frame.DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(allocator, &br, .{});
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(dec_frame.AcStrategyType.dct));

	var result = WorkloadResult{};
	var n: usize = 0;
	while (n < cfg.repeat) : (n += 1) {
		matrices.computed_mask = 0;
		try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(dec_frame.AcStrategyType.dct));
		for (0..3) |c| {
			const table = matrices.matrix(.dct, c);
			result.cells += table.len;
			for (table) |w| {
				mixChecksum(&result.checksum, @bitCast(w.m));
				mixChecksum(&result.checksum, @as(u64, @bitCast(@as(i64, w.e))));
			}
		}
	}
	return result;
}

fn parseArgs(args: []const []const u8) !struct {
	cfg: WorkloadConfig,
	print_checksum: bool,
	expect_checksum: ?u64,
	scaling: bool,
} {
	var cfg = WorkloadConfig{};
	var print_checksum = false;
	var expect_checksum: ?u64 = null;
	var scaling = false;

	var i: usize = 1;
	while (i < args.len) : (i += 1) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--repeat")) {
			i += 1;
			if (i >= args.len) return error.InvalidArgs;
			cfg.repeat = try std.fmt.parseInt(usize, args[i], 10);
			continue;
		}
		if (std.mem.eql(u8, arg, "--print-checksum")) {
			print_checksum = true;
			continue;
		}
		if (std.mem.eql(u8, arg, "--expect-checksum")) {
			i += 1;
			if (i >= args.len) return error.InvalidArgs;
			expect_checksum = try std.fmt.parseInt(u64, args[i], 16);
			continue;
		}
		if (std.mem.eql(u8, arg, "--scaling")) {
			scaling = true;
			continue;
		}
		return error.InvalidArgs;
	}

	return .{
		.cfg = cfg,
		.print_checksum = print_checksum,
		.expect_checksum = expect_checksum,
		.scaling = scaling,
	};
}

fn cpuTimeNs(io: std.Io) u64 {
	const ts = std.Io.Timestamp.now(io, .cpu_process);
	return @as(u64, @intCast(ts.nanoseconds));
}

fn twoBandParams() dec_frame.DctQuantWeightParams {
	var params = dec_frame.DctQuantWeightParams{ .num_distance_bands = 2 };
	var c: usize = 0;
	while (c < 3) : (c += 1) {
		params.distance_bands[c][0] = sf.fromInt(100);
		params.distance_bands[c][1] = sf.fromInt(1);
	}
	return params;
}

/// complexity: O(rows·cols). The scaling gate holds `cols` fixed and doubles
/// `rows`, so cell count (and time) should double.
fn runGetQuantWeights(allocator: std.mem.Allocator, rows: usize) !void {
	const cols: usize = 16;
	const params = twoBandParams();
	const buf = try allocator.alloc(sf.Fixed, 3 * rows * cols);
	defer allocator.free(buf);
	try dec_frame.getQuantWeights(rows, cols, params, buf);
	std.mem.doNotOptimizeAway(buf[0].m);
	std.mem.doNotOptimizeAway(buf[buf.len - 1].m);
}

fn growthRatio(allocator: std.mem.Allocator, io: std.Io, base_rows: usize) !f64 {
	const sizes = [_]usize{ base_rows, base_rows * 2, base_rows * 4, base_rows * 8 };
	var t: [4]u64 = undefined;
	for (sizes, 0..) |n, i| {
		var best: u64 = std.math.maxInt(u64);
		var k: usize = 0;
		while (k < 5) : (k += 1) {
			const s = cpuTimeNs(io);
			try runGetQuantWeights(allocator, n);
			const d = cpuTimeNs(io) - s;
			if (d < best) best = d;
		}
		t[i] = best;
	}
	var r = [_]f64{
		@as(f64, @floatFromInt(t[1])) / @as(f64, @floatFromInt(t[0])),
		@as(f64, @floatFromInt(t[2])) / @as(f64, @floatFromInt(t[1])),
		@as(f64, @floatFromInt(t[3])) / @as(f64, @floatFromInt(t[2])),
	};
	std.mem.sort(f64, &r, {}, std.sort.asc(f64));
	return r[1];
}

pub fn main(init: std.process.Init) !void {
	const allocator = std.heap.page_allocator;
	const io = init.io;
	const args = try init.minimal.args.toSlice(init.arena.allocator());

	const parsed = try parseArgs(args);
	if (parsed.scaling) {
		const ratio = try growthRatio(allocator, io, 16);
		var stderr_buffer: [512]u8 = undefined;
		var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
		const stderr = &stderr_writer.interface;
		try stderr.print("getQuantWeights growth {d:.2}x per doubling (linear gate 2.8)\n", .{ratio});
		try stderr.flush();
		if (ratio >= 2.8) return error.ComplexityRegression;
		return;
	}
	const result = try runDequantBenchmark(allocator, parsed.cfg);

	if (parsed.expect_checksum) |expected| {
		if (result.checksum != expected) return error.ChecksumMismatch;
	}

	if (parsed.print_checksum) {
		var stdout_buffer: [4096]u8 = undefined;
		var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
		const stdout = &stdout_writer.interface;
		try stdout.print("{x}\n", .{result.checksum});
		try stdout.flush();
	}
}

test "dequant DCT8 library EnsureComputed checksum is stable" {
	const result = try runDequantBenchmark(testing.allocator, .{ .repeat = 1 });
	try testing.expectEqual(@as(u64, 192), result.cells);
	const x0 = sf.div(sf.fromInt(1), sf.fromInt(3150));
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = dec_frame.DequantMatrices{};
	defer matrices.deinit(testing.allocator);
	try matrices.decode(testing.allocator, &br, .{});
	try matrices.ensureComputed(testing.allocator, @as(u32, 1) << @intFromEnum(dec_frame.AcStrategyType.dct));
	try testing.expectEqual(x0, matrices.matrix(.dct, 0)[0]);
	try testing.expectEqual(@as(u64, 0x82731ce8a23584ec), result.checksum);
}
