// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// Encoder-side modular prepass benchmark. This models predictor selection and
// hybrid-uint tokenization so future `cjxlz` work can be profiled before a full
// bitstream writer exists.

const std = @import("std");
const lib = @import("src/lib/root.zig");

const Rng = lib.base.random.Rng;
const packSigned = lib.base.pack_signed.packSigned;
const HybridUintConfig = lib.entropy.hybrid_uint.HybridUintConfig;
const Predictor = lib.modular.options.Predictor;
const pixel_type = lib.modular.options.pixel_type;
const pixel_type_w = lib.modular.options.pixel_type_w;
const kNumModularPredictors = lib.modular.options.kNumModularPredictors;
const modular_image = lib.modular.modular_image;
const weighted = lib.modular.weighted;
const context_predict = lib.modular.context_predict;

const testing = std.testing;

pub const BookkeepingMode = enum {
    instrumented,
    minimal,
};

pub const WorkloadConfig = struct {
    width: usize = 48,
    height: usize = 32,
    channels: usize = 3,
    repeat: usize = 2,
    seed: u64 = 7,
    bookkeeping: BookkeepingMode = .instrumented,
};

pub const WorkloadResult = struct {
    checksum: u64 = 0,
    sample_count: u64 = 0,
    total_nbits: u64 = 0,
    predictor_hits: [kNumModularPredictors]u64 = [_]u64{0} ** kNumModularPredictors,

    pub fn totalPredictorHits(self: WorkloadResult) u64 {
        var total: u64 = 0;
        for (self.predictor_hits) |hits| total += hits;
        return total;
    }
};

const kPredictors = [_]Predictor{
    .zero,
    .left,
    .top,
    .average0,
    .select,
    .gradient,
    .weighted,
    .top_right,
    .top_left,
    .left_left,
    .average1,
    .average2,
    .average3,
    .average4,
};

fn mixChecksum(hash: *u64, value: u64) void {
    hash.* ^=
        value +% 0x9E3779B97F4A7C15 +%
        (hash.* << 6) +%
        (hash.* >> 2);
}

fn clampSyntheticSample(value: i64) pixel_type {
    return @intCast(std.math.clamp(value, 0, 1023));
}

/// Builds a repeatable synthetic RGB-ish image with gradients, checker bands,
/// and noise so predictor ranking/token shapes are varied but stable.
fn fillSyntheticImage(image: *modular_image.Image, seed: u64) void {
    var rng = Rng.init(seed);
    for (image.channels.items, 0..) |*channel, channel_index| {
        for (0..channel.h) |y| {
            var row = channel.row(y);
            for (0..channel.w) |x| {
                const xi: i64 = @intCast(x);
                const yi: i64 = @intCast(y);
                const ci: i64 = @intCast(channel_index);
                const ramp = @as(i64, @intCast((x * (13 + channel_index * 3) +
                    y * (17 + channel_index * 5) +
                    ((x * y) >> 4)) & 1023));
                const checker = if ((((x >> 5) + (y >> 5) + channel_index) & 1) == 0) @as(i64, 96) else -96;
                const ripple = @as(i64, @intCast(((x ^ (y * 3) ^ (channel_index * 17)) & 127))) - 63;
                const curve = ((xi * xi) >> 7) - ((yi * yi) >> 8) + (ci * 41);
                const noise = rng.uniformI(-20, 21);
                row[x] = clampSyntheticSample(ramp + checker + ripple + curve + noise);
            }
        }
    }
}

fn resetWeightedState(state: *weighted.State) void {
    state.prediction = .{ 0, 0, 0, 0 };
    state.pred = 0;
    state.wp_prop = 0;
    inline for (0..weighted.kNumPredictors) |i| {
        @memset(state.pred_error_bufs[i], 0);
    }
    @memset(state.error_storage, 0);
}

fn absDiff(a: pixel_type_w, b: pixel_type_w) u64 {
    return @intCast(if (a >= b) a - b else b - a);
}

fn predictorGuess(
    predictor: Predictor,
    left: pixel_type_w,
    top: pixel_type_w,
    toptop: pixel_type_w,
    topleft: pixel_type_w,
    topright: pixel_type_w,
    leftleft: pixel_type_w,
    toprightright: pixel_type_w,
    wp_pred: pixel_type_w,
) pixel_type_w {
    return context_predict.predictOne(
        predictor,
        left,
        top,
        toptop,
        topleft,
        topright,
        leftleft,
        toprightright,
        wp_pred,
    );
}

/// Simulates the future modular encoder's hot prepass: predictor sweep, best
/// predictor choice by residual magnitude, and hybrid-uint tokenization.
fn runChannelEncodePrep(
    comptime bookkeeping: BookkeepingMode,
    channel: *const modular_image.Channel,
    wp_state: *weighted.State,
    hybrid: HybridUintConfig,
    result: *WorkloadResult,
) void {
    for (0..channel.h) |y| {
        const row = channel.rowConst(y);
        const top_row = if (y > 0) channel.rowConst(y - 1) else &[_]pixel_type{};
        const top2_row = if (y > 1) channel.rowConst(y - 2) else &[_]pixel_type{};

        for (0..channel.w) |x| {
            const value: pixel_type_w = row[x];
            const left: pixel_type_w = if (x > 0) row[x - 1] else 0;
            const leftleft: pixel_type_w = if (x > 1) row[x - 2] else left;
            const top: pixel_type_w = if (y > 0) top_row[x] else 0;
            const toptop: pixel_type_w = if (y > 1) top2_row[x] else top;
            const topleft: pixel_type_w = if (y > 0 and x > 0) top_row[x - 1] else top;
            const topright: pixel_type_w = if (y > 0 and x + 1 < channel.w) top_row[x + 1] else top;
            const toprightright: pixel_type_w = if (y > 0 and x + 2 < channel.w) top_row[x + 2] else topright;

            const wp_pred = wp_state.predictNoProps(
                x,
                y,
                channel.w,
                top,
                left,
                topright,
                topleft,
                toptop,
            );

            var best_predictor: Predictor = .zero;
            var best_guess: pixel_type_w = predictorGuess(
                .zero,
                left,
                top,
                toptop,
                topleft,
                topright,
                leftleft,
                toprightright,
                wp_pred,
            );
            var best_abs = absDiff(value, best_guess);

            inline for (kPredictors[1..]) |predictor| {
                const guess = predictorGuess(
                    predictor,
                    left,
                    top,
                    toptop,
                    topleft,
                    topright,
                    leftleft,
                    toprightright,
                    wp_pred,
                );
                const abs_residual = absDiff(value, guess);
                if (abs_residual < best_abs) {
                    best_abs = abs_residual;
                    best_guess = guess;
                    best_predictor = predictor;
                }
            }

            const residual: i32 = @intCast(value - best_guess);
            const packed_value = packSigned(residual);
            const encoded = hybrid.encode(packed_value);

            result.sample_count += 1;
            result.total_nbits += encoded.nbits;
            if (comptime bookkeeping == .instrumented) {
                const predictor_index: usize = @intFromEnum(best_predictor);
                result.predictor_hits[predictor_index] += 1;

                mixChecksum(&result.checksum, predictor_index);
                mixChecksum(&result.checksum, packed_value);
                mixChecksum(&result.checksum, encoded.token);
                mixChecksum(&result.checksum, encoded.nbits);
                mixChecksum(&result.checksum, encoded.bits);
                mixChecksum(&result.checksum, @bitCast(value));
                mixChecksum(&result.checksum, @bitCast(@as(i64, wp_state.getWPProp())));
            }

            wp_state.updateErrors(value, x, y, channel.w);
        }
    }
}

fn finalizeMinimalChecksum(result: *WorkloadResult) void {
    result.checksum = 0xCBF29CE484222325;
    mixChecksum(&result.checksum, result.sample_count);
    mixChecksum(&result.checksum, result.total_nbits);
}

fn runSyntheticEncodePrepMode(
    comptime bookkeeping: BookkeepingMode,
    allocator: std.mem.Allocator,
    cfg: WorkloadConfig,
) !WorkloadResult {
    var image = try modular_image.Image.create(allocator, cfg.width, cfg.height, 10, cfg.channels);
    defer image.deinit();
    fillSyntheticImage(&image, cfg.seed);

    var wp_states = try allocator.alloc(weighted.State, cfg.channels);
    defer {
        for (wp_states) |*state| state.deinit();
        allocator.free(wp_states);
    }
    for (0..cfg.channels) |i| {
        wp_states[i] = try weighted.State.init(allocator, weighted.Header{}, cfg.width, cfg.height);
    }

    var result = WorkloadResult{
        .checksum = 0xCBF29CE484222325,
    };
    const hybrid = HybridUintConfig.initDefault();

    for (0..cfg.repeat) |_| {
        for (image.channels.items, 0..) |*channel, channel_index| {
            resetWeightedState(&wp_states[channel_index]);
            runChannelEncodePrep(bookkeeping, channel, &wp_states[channel_index], hybrid, &result);
        }
    }

    if (comptime bookkeeping == .minimal) {
        finalizeMinimalChecksum(&result);
    }

    return result;
}

/// Runs a deterministic synthetic modular-encoder workload over future hot
/// loops so benchmarks can track predictor/tokenization costs before full ANS
/// writing exists.
pub fn runSyntheticEncodePrep(allocator: std.mem.Allocator, cfg: WorkloadConfig) !WorkloadResult {
    if (cfg.width == 0 or cfg.height == 0 or cfg.channels == 0 or cfg.repeat == 0) {
        return error.InvalidConfig;
    }
    return switch (cfg.bookkeeping) {
        .instrumented => runSyntheticEncodePrepMode(.instrumented, allocator, cfg),
        .minimal => runSyntheticEncodePrepMode(.minimal, allocator, cfg),
    };
}

fn printUsage(file: std.fs.File) !void {
    try file.writeAll(
        "Usage: bench_modular_encode_prep [--repeat N] [--width N] [--height N]\n" ++
            "\t[--channels N] [--seed N] [--print-checksum] [--expect-checksum HEX]\n" ++
            "\t[--print-profile] [--bookkeeping instrumented|minimal]\n",
    );
}

fn parsePositive(comptime T: type, arg: []const u8, name: []const u8) !T {
    const value = try std.fmt.parseUnsigned(T, arg, 10);
    if (value == 0) {
        std.debug.print("{s} must be > 0\n", .{name});
        return error.InvalidArguments;
    }
    return value;
}

fn printProfile(result: WorkloadResult) void {
    std.debug.print("samples={d} total_nbits={d} checksum={x:0>16}\n", .{
        result.sample_count,
        result.total_nbits,
        result.checksum,
    });
    for (kPredictors, 0..) |predictor, index| {
        const hits = result.predictor_hits[index];
        if (hits == 0) continue;
        std.debug.print("{s}\t{d}\n", .{ @tagName(predictor), hits });
    }
}

pub fn main() !void {
    if (comptime @import("builtin").mode == .Debug) {
        std.debug.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cfg = WorkloadConfig{};
    var print_checksum = false;
    var print_profile = false;
    var expected_checksum: ?u64 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try printUsage(std.fs.File.stdout());
            return;
        } else if (std.mem.eql(u8, arg, "--repeat")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cfg.repeat = try parsePositive(usize, args[i], "--repeat");
        } else if (std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cfg.width = try parsePositive(usize, args[i], "--width");
        } else if (std.mem.eql(u8, arg, "--height")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cfg.height = try parsePositive(usize, args[i], "--height");
        } else if (std.mem.eql(u8, arg, "--channels")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cfg.channels = try parsePositive(usize, args[i], "--channels");
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            cfg.seed = try std.fmt.parseUnsigned(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--bookkeeping")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, args[i], "instrumented")) {
                cfg.bookkeeping = .instrumented;
            } else if (std.mem.eql(u8, args[i], "minimal")) {
                cfg.bookkeeping = .minimal;
            } else {
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--print-checksum")) {
            print_checksum = true;
        } else if (std.mem.eql(u8, arg, "--print-profile")) {
            print_profile = true;
        } else if (std.mem.eql(u8, arg, "--expect-checksum")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            expected_checksum = try std.fmt.parseUnsigned(u64, args[i], 16);
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            try printUsage(std.fs.File.stderr());
            return error.InvalidArguments;
        }
    }

    const result = try runSyntheticEncodePrep(allocator, cfg);
    if (print_checksum) {
        std.debug.print("{x:0>16}\n", .{result.checksum});
    }
    if (print_profile) {
        printProfile(result);
    }
    if (expected_checksum) |expected| {
        if (result.checksum != expected) {
            std.debug.print("checksum mismatch: expected {x:0>16}, got {x:0>16}\n", .{
                expected,
                result.checksum,
            });
            return error.ChecksumMismatch;
        }
    }
}

test "encoder prepass predictor hits cover every sample" {
    const result = try runSyntheticEncodePrep(testing.allocator, .{});
    try testing.expectEqual(@as(u64, 48 * 32 * 3 * 2), result.sample_count);
    try testing.expectEqual(result.sample_count, result.totalPredictorHits());
}

test "encoder prepass minimal bookkeeping preserves core totals" {
    const instrumented = try runSyntheticEncodePrep(testing.allocator, .{});
    const minimal = try runSyntheticEncodePrep(testing.allocator, .{
        .bookkeeping = .minimal,
    });
    try testing.expectEqual(instrumented.sample_count, minimal.sample_count);
    try testing.expectEqual(instrumented.total_nbits, minimal.total_nbits);
    try testing.expectEqual(@as(u64, 0), minimal.totalPredictorHits());
}

test "encoder prepass checksum stays stable" {
    const result = try runSyntheticEncodePrep(testing.allocator, .{});
    try testing.expectEqual(@as(u64, 0x503a7abf436bb4fc), result.checksum);
}

test "encoder prepass minimal checksum stays stable" {
    const result = try runSyntheticEncodePrep(testing.allocator, .{
        .bookkeeping = .minimal,
    });
    try testing.expectEqual(@as(u64, 0x2c1a6fb5a404b318), result.checksum);
}
