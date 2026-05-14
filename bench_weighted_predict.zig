const std = @import("std");

const weighted = @import("src/lib/modular/weighted.zig");
const options = @import("src/lib/modular/options.zig");

const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;

const seed: u64 = 0xcbf29ce484222325;

const WorkloadMode = enum {
    generic_null_props,
    no_props,
};

fn mix(acc: *u64, value: u64) void {
    acc.* = (acc.* ^ value) *% 0x100000001b3;
}

fn mixI32(acc: *u64, value: i32) void {
    const bits: u32 = @bitCast(value);
    mix(acc, bits);
}

fn mixI64(acc: *u64, value: i64) void {
    const bits: u64 = @bitCast(value);
    mix(acc, bits);
}

fn syntheticPixel(x: usize, y: usize) pixel_type {
    const xi: i32 = @intCast(x);
    const yi: i32 = @intCast(y);
    const base = xi * 37 - yi * 19;
    const cross = @as(i32, @intCast((x * y) % 29)) * 11;
    const parity = @as(i32, @intCast((x ^ y) & 15));
    return base + cross + parity - 512;
}

fn resetState(state: *weighted.State) void {
    state.prediction = .{ 0, 0, 0, 0 };
    state.pred = 0;
    state.wp_prop = 0;
    for (0..weighted.kNumPredictors) |i| {
        @memset(state.pred_error_bufs[i], 0);
    }
    @memset(state.error_storage, 0);
}

/// Keeps the benchmark able to compare the generic null-properties callsite
/// against the explicit encoder-side `predictNoProps` path without changing the
/// surrounding synthetic workload.
fn predictForMode(
    state: *weighted.State,
    mode: WorkloadMode,
    x: usize,
    y: usize,
    width: usize,
    top: pixel_type_w,
    left: pixel_type_w,
    topright: pixel_type_w,
    topleft: pixel_type_w,
    toptop: pixel_type_w,
) pixel_type_w {
    return switch (mode) {
        .generic_null_props => state.predict(x, y, width, top, left, topright, topleft, toptop, null, 0),
        .no_props => state.predictNoProps(x, y, width, top, left, topright, topleft, toptop),
    };
}

/// Runs the synthetic weighted-predictor workload in one of two callsite modes
/// so future tuning can measure the real encoder `predictNoProps` path against
/// the older generic-null-properties route.
fn runWorkloadMode(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    repeat: usize,
    mode: WorkloadMode,
) !u64 {
    var state = try weighted.State.init(allocator, weighted.Header{}, width, height);
    defer state.deinit();

    const decoded = try allocator.alloc(pixel_type, width * height);
    defer allocator.free(decoded);

    var checksum: u64 = seed;
    var rep: usize = 0;
    while (rep < repeat) : (rep += 1) {
        @memset(decoded, 0);
        resetState(&state);

        for (0..height) |y| {
            const row = decoded[y * width ..][0..width];
            const prev_row = if (y > 0) decoded[(y - 1) * width ..][0..width] else &[_]pixel_type{};
            const prev2_row = if (y > 1) decoded[(y - 2) * width ..][0..width] else &[_]pixel_type{};

            for (0..width) |x| {
                const left: pixel_type_w = if (x > 0) row[x - 1] else if (y > 0) prev_row[x] else 0;
                const top: pixel_type_w = if (y > 0) prev_row[x] else left;
                const topleft: pixel_type_w = if (x > 0 and y > 0) prev_row[x - 1] else left;
                const topright: pixel_type_w = if (x + 1 < width and y > 0) prev_row[x + 1] else top;
                const toptop: pixel_type_w = if (y > 1) prev2_row[x] else top;

                const pred = predictForMode(&state, mode, x, y, width, top, left, topright, topleft, toptop);
                const value = syntheticPixel(x, y);
                row[x] = value;
                state.updateErrors(value, x, y, width);

                mixI64(&checksum, pred);
                mixI32(&checksum, value);
            }
        }
    }

    return checksum;
}

fn parseMode(arg: []const u8) !WorkloadMode {
    if (std.mem.eql(u8, arg, "generic") or std.mem.eql(u8, arg, "generic_null_props")) {
        return .generic_null_props;
    }
    if (std.mem.eql(u8, arg, "no_props")) {
        return .no_props;
    }
    return error.InvalidArgs;
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var repeat: usize = 1;
    var width: usize = 600;
    var height: usize = 300;
    var mode: WorkloadMode = .generic_null_props;
    var print_checksum = false;
    var arg_i: usize = 1;
    while (arg_i < args.len and std.mem.startsWith(u8, args[arg_i], "--")) {
        if (std.mem.eql(u8, args[arg_i], "--repeat")) {
            if (arg_i + 1 >= args.len) return error.InvalidArgs;
            repeat = try std.fmt.parseInt(usize, args[arg_i + 1], 10);
            if (repeat == 0) return error.InvalidArgs;
            arg_i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[arg_i], "--width")) {
            if (arg_i + 1 >= args.len) return error.InvalidArgs;
            width = try std.fmt.parseInt(usize, args[arg_i + 1], 10);
            if (width == 0) return error.InvalidArgs;
            arg_i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[arg_i], "--height")) {
            if (arg_i + 1 >= args.len) return error.InvalidArgs;
            height = try std.fmt.parseInt(usize, args[arg_i + 1], 10);
            if (height == 0) return error.InvalidArgs;
            arg_i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[arg_i], "--mode")) {
            if (arg_i + 1 >= args.len) return error.InvalidArgs;
            mode = try parseMode(args[arg_i + 1]);
            arg_i += 2;
            continue;
        }
        if (std.mem.eql(u8, args[arg_i], "--print-checksum")) {
            print_checksum = true;
            arg_i += 1;
            continue;
        }
        return error.InvalidArgs;
    }
    if (arg_i != args.len) return error.InvalidArgs;

    const checksum = try runWorkloadMode(allocator, width, height, repeat, mode);
    if (print_checksum or checksum == 0xDEADBEEFDEADBEEF) {
        std.debug.print("checksum={x}\n", .{checksum});
    }
}

test "weighted predictor workload checksum stays stable" {
    const checksum = try runWorkloadMode(std.testing.allocator, 32, 24, 2, .generic_null_props);
    try std.testing.expectEqual(@as(u64, 0x2d36a9a2826f8f4d), checksum);
}

test "weighted predictor no-props workload matches generic null-properties path" {
    const generic = try runWorkloadMode(std.testing.allocator, 32, 24, 2, .generic_null_props);
    const no_props = try runWorkloadMode(std.testing.allocator, 32, 24, 2, .no_props);
    try std.testing.expectEqual(generic, no_props);
}

test "weighted predictor no-props workload checksum stays stable" {
    const checksum = try runWorkloadMode(std.testing.allocator, 32, 24, 2, .no_props);
    try std.testing.expectEqual(@as(u64, 0x2d36a9a2826f8f4d), checksum);
}
