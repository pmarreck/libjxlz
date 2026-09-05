// Transform reading: TransformId, SqueezeParams, Transform.
// Transliterated from lib/jxl/modular/transform/transform.h/.cc
// and lib/jxl/modular/transform/squeeze_params.h/.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("../codec/field_coders.zig");
const options = @import("options.zig");
const Predictor = options.Predictor;

pub const TransformId = enum(u32) {
    rct = 0,
    palette = 1,
    squeeze = 2,
    invalid = 3,
};

pub const SqueezeParams = struct {
    horizontal: bool = false,
    in_place: bool = false,
    begin_c: u32 = 0,
    num_c: u32 = 2,

    pub fn readFromBitStream(br: *BitReader) SqueezeParams {
        var sp = SqueezeParams{};
        sp.horizontal = br.readBits(1) != 0;
        sp.in_place = br.readBits(1) != 0;
        // begin_c: U32(Bits(3), BitsOffset(6,8), BitsOffset(10,72), BitsOffset(13,1096))
        const bc_enc = fc.U32Enc.init(fc.bits(3), fc.bitsOffset(6, 8), fc.bitsOffset(10, 72), fc.bitsOffset(13, 1096));
        sp.begin_c = fc.U32Coder.read(bc_enc, br);
        // num_c: U32(Val(1), Val(2), Val(3), BitsOffset(4,4))
        const nc_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.bitsOffset(4, 4));
        sp.num_c = fc.U32Coder.read(nc_enc, br);
        return sp;
    }
};

pub const Transform = struct {
    id: TransformId = .invalid,
    begin_c: u32 = 0,
    rct_type: u32 = 6, // default YCoCg
    num_c: u32 = 3,
    nb_colors: u32 = 256,
    nb_deltas: u32 = 0,
    predictor: Predictor = .zero,
    squeezes: []SqueezeParams = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn readFromBitStream(br: *BitReader, allocator: std.mem.Allocator) JxlError!Transform {
        var t = Transform{};
        t.allocator = allocator;

        // TransformId: U32(Val(0), Val(1), Val(2), Val(3))
        const id_sel = br.readBits(2);
        t.id = std.enums.fromInt(TransformId, @as(u32, @intCast(id_sel))) orelse return error.GenericError;
        if (t.id == .invalid) return error.GenericError;

        // begin_c (for RCT and Palette)
        if (t.id == .rct or t.id == .palette) {
            const bc_enc = fc.U32Enc.init(fc.bits(3), fc.bitsOffset(6, 8), fc.bitsOffset(10, 72), fc.bitsOffset(13, 1096));
            t.begin_c = fc.U32Coder.read(bc_enc, br);
        }

        // rct_type (for RCT only)
        if (t.id == .rct) {
            const rt_enc = fc.U32Enc.init(fc.val(6), fc.bits(2), fc.bitsOffset(4, 2), fc.bitsOffset(6, 10));
            t.rct_type = fc.U32Coder.read(rt_enc, br);
            if (t.rct_type >= 42) return error.GenericError;
        }

        // Palette fields
        if (t.id == .palette) {
            const nc_enc = fc.U32Enc.init(fc.val(1), fc.val(3), fc.val(4), fc.bitsOffset(13, 1));
            t.num_c = fc.U32Coder.read(nc_enc, br);

            const nbc_enc = fc.U32Enc.init(fc.bitsOffset(8, 0), fc.bitsOffset(10, 256), fc.bitsOffset(12, 1280), fc.bitsOffset(16, 5376));
            t.nb_colors = fc.U32Coder.read(nbc_enc, br);

            const nbd_enc = fc.U32Enc.init(fc.val(0), fc.bitsOffset(8, 1), fc.bitsOffset(10, 257), fc.bitsOffset(16, 1281));
            t.nb_deltas = fc.U32Coder.read(nbd_enc, br);

            const pred_val: u32 = @intCast(br.readBits(4));
            t.predictor = std.enums.fromInt(Predictor, pred_val) orelse return error.GenericError;
            if (@intFromEnum(t.predictor) >= @intFromEnum(Predictor.best)) return error.GenericError;
        }

        // Squeeze params
        if (t.id == .squeeze) {
            const ns_enc = fc.U32Enc.init(fc.val(0), fc.bitsOffset(4, 1), fc.bitsOffset(6, 9), fc.bitsOffset(8, 41));
            const num_squeezes = fc.U32Coder.read(ns_enc, br);
            if (num_squeezes > 0) {
                const sq = try allocator.alloc(SqueezeParams, num_squeezes);
                for (sq) |*s| {
                    s.* = SqueezeParams.readFromBitStream(br);
                }
                t.squeezes = sq;
            }
        }

        return t;
    }

    pub fn deinit(self: *Transform) void {
        if (self.allocator) |alloc| {
            if (self.squeezes.len > 0) {
                alloc.free(self.squeezes);
                self.squeezes = &.{};
            }
        }
    }
};

// ── Inverse Transforms ──

const modular_image = @import("modular_image.zig");
const Channel = modular_image.Channel;
const Image = modular_image.Image;
const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;
const context_predict = @import("context_predict.zig");
const weighted = @import("weighted.zig");

inline fn pixelAdd(a: pixel_type, b: pixel_type) pixel_type {
    return @bitCast(@as(u32, @bitCast(a)) +% @as(u32, @bitCast(b)));
}

inline fn pixelSub(a: pixel_type, b: pixel_type) pixel_type {
    return @bitCast(@as(u32, @bitCast(a)) -% @as(u32, @bitCast(b)));
}

// ── Inverse RCT ──

fn fwdRCTRow(comptime transform_type: u3, in0: []const pixel_type, in1: []const pixel_type, in2: []const pixel_type, out0: []pixel_type, out1: []pixel_type, out2: []pixel_type) void {
    const second = transform_type >> 1;
    const third = transform_type & 1;

    for (0..in0.len) |x| {
        const First = in0[x];
        var Second_v = in1[x];
        var Third_v = in2[x];

        if (transform_type == 6) {
            const R = First;
            const G = Second_v;
            const B = Third_v;
            const o1 = pixelSub(R, B);
            const tmp = pixelAdd(B, o1 >> 1);
            const o2 = pixelSub(G, tmp);
            out0[x] = pixelAdd(tmp, o2 >> 1);
            out1[x] = o1;
            out2[x] = o2;
            continue;
        }

        if (second == 1) {
            Second_v = pixelSub(Second_v, First);
        } else if (second == 2) {
            Second_v = pixelSub(Second_v, pixelAdd(First, Third_v) >> 1);
        }
        if (third != 0) Third_v = pixelSub(Third_v, First);

        out0[x] = First;
        out1[x] = Second_v;
        out2[x] = Third_v;
    }
}

pub fn fwdRCT(image: *Image, begin_c: usize, rct_type: u32) JxlError!void {
    if (rct_type == 0) return;

    const permutation: usize = rct_type / 7;
    if (permutation >= 6) return error.GenericError;
    const custom: u3 = @intCast(rct_type % 7);

    const m = begin_c;
    if (m + 2 >= image.channels.items.len) return error.GenericError;

    const w = image.channels.items[m].w;
    const h = image.channels.items[m].h;
    if (image.channels.items[m + 1].w != w or image.channels.items[m + 2].w != w) return error.GenericError;
    if (image.channels.items[m + 1].h != h or image.channels.items[m + 2].h != h) return error.GenericError;

    const allocator = image.allocator;
    const buf0 = try allocator.alloc(pixel_type, w);
    defer allocator.free(buf0);
    const buf1 = try allocator.alloc(pixel_type, w);
    defer allocator.free(buf1);
    const buf2 = try allocator.alloc(pixel_type, w);
    defer allocator.free(buf2);

    const p0 = permutation % 3;
    const p1 = (permutation + 1 + permutation / 3) % 3;
    const p2 = (permutation + 2 -| (permutation / 3)) % 3;

    for (0..h) |y| {
        const in0 = image.channels.items[m + p0].rowConst(y);
        const in1 = image.channels.items[m + p1].rowConst(y);
        const in2 = image.channels.items[m + p2].rowConst(y);

        switch (custom) {
            inline 0, 1, 2, 3, 4, 5, 6 => |ct| fwdRCTRow(ct, in0, in1, in2, buf0, buf1, buf2),
            else => unreachable,
        }

        @memcpy(image.channels.items[m].row(y), buf0);
        @memcpy(image.channels.items[m + 1].row(y), buf1);
        @memcpy(image.channels.items[m + 2].row(y), buf2);
    }
}

fn invRCTRow(comptime transform_type: u3, in0: []const pixel_type, in1: []const pixel_type, in2: []const pixel_type, out0: []pixel_type, out1: []pixel_type, out2: []pixel_type) void {
    const second = transform_type >> 1;
    const third = transform_type & 1;

    for (0..in0.len) |x| {
        if (transform_type == 6) {
            // YCoCg
            var Y = in0[x];
            const Co = in1[x];
            const Cg = in2[x];
            Y = pixelAdd(Y, -(Cg >> 1));
            const G = pixelAdd(Cg, Y);
            const B = pixelAdd(Y, -(Co >> 1));
            const R = pixelAdd(B, Co);
            out0[x] = R;
            out1[x] = G;
            out2[x] = B;
        } else {
            var First = in0[x];
            var Second_v = in1[x];
            var Third_v = in2[x];
            if (third != 0) Third_v = pixelAdd(Third_v, First);
            if (second == 1) {
                Second_v = pixelAdd(Second_v, First);
            } else if (second == 2) {
                Second_v = pixelAdd(Second_v, pixelAdd(First, Third_v) >> 1);
            }
            _ = &First;
            out0[x] = First;
            out1[x] = Second_v;
            out2[x] = Third_v;
        }
    }
}

pub fn invRCT(image: *Image, begin_c: usize, rct_type: u32) JxlError!void {
    if (rct_type == 0) return; // noop

    const permutation: usize = rct_type / 7;
    if (permutation >= 6) return error.GenericError;
    const custom: u3 = @intCast(rct_type % 7);

    const m = begin_c;
    if (m + 2 >= image.channels.items.len) return error.GenericError;

    const w = image.channels.items[m].w;
    const h = image.channels.items[m].h;

    if (custom == 0) {
        // Permute-only: swap channel data pointers
        // For simplicity, swap the underlying data
        const tmp0 = image.channels.items[m].data;
        const tmp1 = image.channels.items[m + 1].data;
        const tmp2 = image.channels.items[m + 2].data;
        image.channels.items[m + (permutation % 3)].data = tmp0;
        image.channels.items[m + ((permutation + 1 + permutation / 3) % 3)].data = tmp1;
        image.channels.items[m + ((permutation + 2 -| (permutation / 3)) % 3)].data = tmp2;
        return;
    }

    // Apply inverse RCT row by row
    for (0..h) |y| {
        const in0 = image.channels.items[m].rowConst(y);
        const in1 = image.channels.items[m + 1].rowConst(y);
        const in2 = image.channels.items[m + 2].rowConst(y);

        // We need temp buffers for in-place operation with permutation
        var buf0: [4096]pixel_type = undefined;
        var buf1: [4096]pixel_type = undefined;
        var buf2: [4096]pixel_type = undefined;

        // For images wider than 4096, fall back to allocator
        if (w > 4096) {
            // For large images, operate in-place (only works if permutation is identity)
            if (permutation == 0) {
                const o0 = image.channels.items[m].row(y);
                const o1 = image.channels.items[m + 1].row(y);
                const o2 = image.channels.items[m + 2].row(y);
                switch (custom) {
                    inline 0, 1, 2, 3, 4, 5, 6 => |ct| invRCTRow(ct, in0, in1, in2, o0, o1, o2),
                    else => unreachable,
                }
            }
            continue;
        }

        switch (custom) {
            inline 0, 1, 2, 3, 4, 5, 6 => |ct| invRCTRow(ct, in0, in1, in2, buf0[0..w], buf1[0..w], buf2[0..w]),
            else => unreachable,
        }

        // Apply permutation
        const dst0 = image.channels.items[m + (permutation % 3)].row(y);
        const dst1 = image.channels.items[m + ((permutation + 1 + permutation / 3) % 3)].row(y);
        const dst2 = image.channels.items[m + ((permutation + 2 -| (permutation / 3)) % 3)].row(y);
        @memcpy(dst0, buf0[0..w]);
        @memcpy(dst1, buf1[0..w]);
        @memcpy(dst2, buf2[0..w]);
    }
}

// ── Squeeze tendency + inverse ──

pub fn smoothTendency(B: pixel_type_w, a: pixel_type_w, n: pixel_type_w) pixel_type_w {
    var diff: pixel_type_w = 0;
    if (B >= a and a >= n) {
        diff = @divTrunc(4 * B - 3 * n - a + 6, 12);
        if (diff - (diff & 1) > 2 * (B - a)) diff = 2 * (B - a) + 1;
        if (diff + (diff & 1) > 2 * (a - n)) diff = 2 * (a - n);
    } else if (B <= a and a <= n) {
        diff = @divTrunc(4 * B - 3 * n - a - 6, 12);
        if (diff + (diff & 1) < 2 * (B - a)) diff = 2 * (B - a) - 1;
        if (diff - (diff & 1) < 2 * (a - n)) diff = 2 * (a - n);
    }
    return diff;
}

pub fn invVSqueeze(image: *Image, c: u32, rc: u32) JxlError!void {
    const chin = &image.channels.items[c];
    const chin_residual = &image.channels.items[rc];

    if (chin_residual.h == 0) {
        chin.vshift -= 1;
        return;
    }

    const out_h = chin.h + chin_residual.h;
    const allocator = chin.allocator orelse return error.GenericError;
    var chout = try Channel.create(allocator, chin.w, out_h, chin.hshift, chin.vshift - 1);
    errdefer chout.deinit();

    if (chin_residual.w == 0) {
        image.channels.items[c].deinit();
        image.channels.items[c] = chout;
        return;
    }

    for (0..chin_residual.h) |y| {
        const p_residual = chin_residual.rowConst(y);
        const p_avg = chin.rowConst(y);
        const p_navg = chin.rowConst(if (y + 1 < chin.h) y + 1 else y);
        var p_out = chout.row(y << 1);
        var p_nout = chout.row((y << 1) + 1);
        const p_pout: []const pixel_type = if (y > 0) chout.rowConst((y << 1) - 1) else p_avg;

        for (0..chin.w) |x| {
            const avg: pixel_type_w = p_avg[x];
            const next_avg: pixel_type_w = p_navg[x];
            const top: pixel_type_w = p_pout[x];
            const tendency = smoothTendency(top, avg, next_avg);
            const diff = @as(pixel_type_w, p_residual[x]) + tendency;
            const out: pixel_type = @intCast(avg + @divTrunc(diff, 2));
            p_out[x] = out;
            p_nout[x] = @intCast(@as(pixel_type_w, out) - diff);
        }
    }

    // Last row for odd height
    if (out_h & 1 != 0) {
        const y = chin.h - 1;
        const p_avg = chin.rowConst(y);
        var p_out = chout.row(y << 1);
        @memcpy(p_out[0..chin.w], p_avg[0..chin.w]);
    }

    image.channels.items[c].deinit();
    image.channels.items[c] = chout;
}

pub fn invHSqueeze(image: *Image, c: u32, rc: u32) JxlError!void {
    const chin = &image.channels.items[c];
    const chin_residual = &image.channels.items[rc];

    if (chin_residual.w == 0) {
        chin.hshift -= 1;
        return;
    }

    const out_w = chin.w + chin_residual.w;
    const allocator = chin.allocator orelse return error.GenericError;
    var chout = try Channel.create(allocator, out_w, chin.h, chin.hshift - 1, chin.vshift);
    errdefer chout.deinit();

    if (chin_residual.h == 0) {
        image.channels.items[c].deinit();
        image.channels.items[c] = chout;
        return;
    }

    for (0..chin.h) |y| {
        const p_residual = chin_residual.rowConst(y);
        const p_avg = chin.rowConst(y);
        var p_out = chout.row(y);

        for (0..chin_residual.w) |x| {
            const avg: pixel_type_w = p_avg[x];
            const next_avg: pixel_type_w = if (x + 1 < chin.w) p_avg[x + 1] else avg;
            const left: pixel_type_w = if (x > 0) p_out[(x << 1) - 1] else avg;
            const tendency = smoothTendency(left, avg, next_avg);
            const diff = @as(pixel_type_w, p_residual[x]) + tendency;
            const A: pixel_type = @intCast(avg + @divTrunc(diff, 2));
            p_out[x << 1] = A;
            p_out[(x << 1) + 1] = @intCast(@as(pixel_type_w, A) - diff);
        }
        if (out_w & 1 != 0) p_out[out_w - 1] = p_avg[chin.w - 1];
    }

    image.channels.items[c].deinit();
    image.channels.items[c] = chout;
}

pub fn invSqueeze(image: *Image, parameters: []const SqueezeParams) JxlError!void {
    // Apply in reverse order
    var i: isize = @intCast(parameters.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const param = parameters[@intCast(i)];
        const beginc = param.begin_c;
        const endc = param.begin_c + param.num_c - 1;

        const offset: u32 = if (param.in_place) endc + 1 else @intCast(image.channels.items.len + beginc - endc - 1);

        if (beginc < image.nb_meta_channels) {
            if (image.nb_meta_channels >= param.num_c) {
                image.nb_meta_channels -= param.num_c;
            }
        }

        var c = beginc;
        while (c <= endc) : (c += 1) {
            const rc = offset + c - beginc;
            if (rc >= image.channels.items.len) return error.GenericError;

            if (param.horizontal) {
                try invHSqueeze(image, c, rc);
            } else {
                try invVSqueeze(image, c, rc);
            }
        }

        // Remove residual channels
        const remove_start = offset;
        const remove_count = endc - beginc + 1;
        var j: usize = 0;
        while (j < remove_count) : (j += 1) {
            if (remove_start < image.channels.items.len) {
                var ch = image.channels.orderedRemove(remove_start);
                ch.deinit();
            }
        }
    }
}

// ── MetaSqueeze: forward transform that modifies channel structure ──

const kMaxFirstPreviewSize: usize = 8;

inline fn averagePixel(a: pixel_type, b: pixel_type) pixel_type {
    const sum: pixel_type_w = @as(pixel_type_w, a) + @as(pixel_type_w, b) + @as(pixel_type_w, @intCast(@intFromBool(a > b)));
    return @intCast(sum >> 1);
}

pub fn fwdHSqueeze(image: *Image, c: usize, rc: usize) JxlError!void {
    const chin = image.channels.items[c];
    const allocator = chin.allocator orelse return error.GenericError;

    var chout = try Channel.create(allocator, (chin.w + 1) / 2, chin.h, chin.hshift + 1, chin.vshift);
    errdefer chout.deinit();
    var chout_residual = try Channel.create(allocator, chin.w - chout.w, chout.h, chin.hshift + 1, chin.vshift);
    errdefer chout_residual.deinit();
    chout.component = chin.component;
    chout_residual.component = chin.component;

    for (0..chout.h) |y| {
        const p_in = chin.rowConst(y);
        const p_out = chout.row(y);
        const p_res = chout_residual.row(y);
        for (0..chout_residual.w) |x| {
            const A = p_in[x * 2];
            const B = p_in[x * 2 + 1];
            const avg = averagePixel(A, B);
            p_out[x] = avg;

            const diff = pixelSub(A, B);
            var next_avg = avg;
            if (x + 1 < chout_residual.w) {
                const C = p_in[x * 2 + 2];
                const D = p_in[x * 2 + 3];
                next_avg = averagePixel(C, D);
            } else if ((chin.w & 1) != 0) {
                next_avg = p_in[x * 2 + 2];
            }
            const left = if (x > 0) p_in[x * 2 - 1] else avg;
            const tendency = smoothTendency(left, avg, next_avg);
            p_res[x] = @intCast(@as(pixel_type_w, diff) - tendency);
        }
        if ((chin.w & 1) != 0) {
            const x = chout.w - 1;
            p_out[x] = p_in[x * 2];
        }
    }

    image.channels.items[c].deinit();
    image.channels.items[c] = chout;
    try image.channels.insert(allocator, rc, chout_residual);
}

pub fn fwdVSqueeze(image: *Image, c: usize, rc: usize) JxlError!void {
    const chin = image.channels.items[c];
    const allocator = chin.allocator orelse return error.GenericError;

    var chout = try Channel.create(allocator, chin.w, (chin.h + 1) / 2, chin.hshift, chin.vshift + 1);
    errdefer chout.deinit();
    var chout_residual = try Channel.create(allocator, chin.w, chin.h - chout.h, chin.hshift, chin.vshift + 1);
    errdefer chout_residual.deinit();
    chout.component = chin.component;
    chout_residual.component = chin.component;

    for (0..chout_residual.h) |y| {
        const p_in = chin.rowConst(y * 2);
        const p_out = chout.row(y);
        const p_res = chout_residual.row(y);
        for (0..chout.w) |x| {
            const A = p_in[x];
            const B = chin.rowConst(y * 2 + 1)[x];
            const avg = averagePixel(A, B);
            p_out[x] = avg;

            const diff = pixelSub(A, B);
            var next_avg = avg;
            if (y + 1 < chout_residual.h) {
                const C = chin.rowConst(y * 2 + 2)[x];
                const D = chin.rowConst(y * 2 + 3)[x];
                next_avg = averagePixel(C, D);
            } else if ((chin.h & 1) != 0) {
                next_avg = chin.rowConst(y * 2 + 2)[x];
            }
            const top = if (y > 0) chin.rowConst(y * 2 - 1)[x] else avg;
            const tendency = smoothTendency(top, avg, next_avg);
            p_res[x] = @intCast(@as(pixel_type_w, diff) - tendency);
        }
    }

    if ((chin.h & 1) != 0) {
        const y = chout.h - 1;
        const p_in = chin.rowConst(y * 2);
        const p_out = chout.row(y);
        @memcpy(p_out, p_in);
    }

    image.channels.items[c].deinit();
    image.channels.items[c] = chout;
    try image.channels.insert(allocator, rc, chout_residual);
}

pub fn fwdSqueeze(image: *Image, parameters: []const SqueezeParams) JxlError!void {
    for (parameters) |param| {
        try checkMetaSqueezeParams(param, image.channels.items.len);
        const beginc = param.begin_c;
        const endc = param.begin_c + param.num_c - 1;
        const offset: usize = if (param.in_place) endc + 1 else image.channels.items.len;

        var c = beginc;
        while (c <= endc) : (c += 1) {
            const rc = offset + c - beginc;
            if (param.horizontal) {
                try fwdHSqueeze(image, c, rc);
            } else {
                try fwdVSqueeze(image, c, rc);
            }
        }
    }
}

pub fn defaultSqueezeParameters(allocator: std.mem.Allocator, image: *const Image) ![]SqueezeParams {
    var params: std.ArrayList(SqueezeParams) = .empty;
    errdefer params.deinit(allocator);

    const nb_channels = image.channels.items.len - image.nb_meta_channels;
    var w = image.channels.items[image.nb_meta_channels].w;
    var h = image.channels.items[image.nb_meta_channels].h;

    const wide = (w > h);

    // 4:2:0 chroma squeeze
    if (nb_channels > 2 and
        image.channels.items[image.nb_meta_channels + 1].w == w and
        image.channels.items[image.nb_meta_channels + 1].h == h)
    {
        try params.append(allocator, .{
            .horizontal = true,
            .in_place = false,
            .begin_c = @intCast(image.nb_meta_channels + 1),
            .num_c = 2,
        });
        try params.append(allocator, .{
            .horizontal = false,
            .in_place = false,
            .begin_c = @intCast(image.nb_meta_channels + 1),
            .num_c = 2,
        });
    }

    var sp = SqueezeParams{
        .begin_c = @intCast(image.nb_meta_channels),
        .num_c = @intCast(nb_channels),
        .in_place = true,
        .horizontal = false,
    };

    if (!wide) {
        if (h > kMaxFirstPreviewSize) {
            sp.horizontal = false;
            try params.append(allocator, sp);
            h = (h + 1) / 2;
        }
    }
    while (w > kMaxFirstPreviewSize or h > kMaxFirstPreviewSize) {
        if (w > kMaxFirstPreviewSize) {
            sp.horizontal = true;
            try params.append(allocator, sp);
            w = (w + 1) / 2;
        }
        if (h > kMaxFirstPreviewSize) {
            sp.horizontal = false;
            try params.append(allocator, sp);
            h = (h + 1) / 2;
        }
    }

    return params.toOwnedSlice(allocator);
}

fn checkMetaSqueezeParams(param: SqueezeParams, num_channels: usize) JxlError!void {
    const c1 = param.begin_c;
    const c2 = param.begin_c + param.num_c - 1;
    if (c1 >= num_channels or c2 >= num_channels or c2 < c1) {
        return error.GenericError;
    }
}

pub fn metaSqueeze(image: *Image, squeezes: *[]SqueezeParams, allocator: std.mem.Allocator) JxlError!void {
    // If no squeeze params provided, generate defaults
    if (squeezes.len == 0) {
        const defaults = try defaultSqueezeParameters(allocator, image);
        squeezes.* = defaults;
    }

    for (squeezes.*) |param| {
        checkMetaSqueezeParams(param, image.channels.items.len) catch return error.GenericError;
        try image.channels.ensureUnusedCapacity(allocator, param.num_c);
        const horizontal = param.horizontal;
        const in_place = param.in_place;
        const beginc = param.begin_c;
        const endc = param.begin_c + param.num_c - 1;

        if (beginc < image.nb_meta_channels) {
            if (endc >= image.nb_meta_channels) return error.GenericError;
            if (!in_place) return error.GenericError;
            image.nb_meta_channels += param.num_c;
        }

        const offset: usize = if (in_place) endc + 1 else image.channels.items.len;

        var c = beginc;
        while (c <= endc) : (c += 1) {
            const ch = &image.channels.items[c];
            if (ch.hshift > 30 or ch.vshift > 30) return error.GenericError;
            var w = ch.w;
            var h = ch.h;
            if (w == 0 or h == 0) return error.GenericError;

            if (horizontal) {
                ch.w = (w + 1) / 2;
                if (ch.hshift >= 0) ch.hshift += 1;
                w = w - (w + 1) / 2;
            } else {
                ch.h = (h + 1) / 2;
                if (ch.vshift >= 0) ch.vshift += 1;
                h = h - (h + 1) / 2;
            }
            try ch.shrink();

            var placeholder = try Channel.create(allocator, w, h, ch.hshift, ch.vshift);
            placeholder.component = ch.component;
            image.channels.insertAssumeCapacity(offset + (c - beginc), placeholder);
        }
    }
}

// ── MetaPalette: forward transform that modifies channel structure for palette ──

fn checkEqualChannels(image: *const Image, begin_c: usize, end_c: usize) JxlError!void {
    if (end_c >= image.channels.items.len) return error.GenericError;
    const w = image.channels.items[begin_c].w;
    const h = image.channels.items[begin_c].h;
    var c = begin_c + 1;
    while (c <= end_c) : (c += 1) {
        if (image.channels.items[c].w != w or image.channels.items[c].h != h) {
            return error.GenericError;
        }
    }
}

/// Applies the narrow explicit palette transform: exact first-seen color tuples,
/// zero deltas, and an index channel that `invPalette` can reconstruct losslessly.
pub fn fwdPalette(image: *Image, begin_c: u32, end_c: u32, allocator: std.mem.Allocator) JxlError!Transform {
	if (begin_c > end_c or end_c >= image.channels.items.len) return error.GenericError;
	try checkEqualChannels(image, begin_c, end_c);

	const num_channels: usize = end_c - begin_c + 1;
	const source = &image.channels.items[begin_c];
	if (source.w == 0 or source.h == 0) return error.GenericError;

	const total = source.w * source.h;
	const original = try allocator.alloc(pixel_type, total * num_channels);
	defer allocator.free(original);
	for (0..num_channels) |c| {
		const channel = &image.channels.items[begin_c + c];
		@memcpy(original[c * total ..][0..total], channel.data[0..total]);
	}

	const IndexChoice = union(enum) {
		explicit: u32,
		implicit: u32,
	};

	var palette_values: std.ArrayList(pixel_type) = .empty;
	defer palette_values.deinit(allocator);
	const indices = try allocator.alloc(pixel_type, total);
	defer allocator.free(indices);
	const choices = try allocator.alloc(IndexChoice, total);
	defer allocator.free(choices);
	const bit_depth = @min(image.bitdepth, 24);
	const frequent_implicit_threshold: usize = 10;
	var implicit_counts = [_]usize{0} ** @as(usize, @intCast(kImplicitPaletteSize));

	if (num_channels <= kRgbChannels) {
		for (0..total) |pixel_index| {
			var color_buf: [kRgbChannels]pixel_type = .{ 0, 0, 0 };
			for (0..num_channels) |c| {
				color_buf[c] = original[c * total + pixel_index];
			}
			if (findImplicitPaletteOffset(color_buf[0..num_channels], bit_depth)) |implicit_offset| {
				implicit_counts[implicit_offset] += 1;
			}
		}
	}

	for (0..total) |pixel_index| {
		var color_buf: [kRgbChannels]pixel_type = .{ 0, 0, 0 };
		if (num_channels <= kRgbChannels) {
			for (0..num_channels) |c| {
				color_buf[c] = original[c * total + pixel_index];
			}
			if (findImplicitPaletteOffset(color_buf[0..num_channels], bit_depth)) |implicit_offset| {
				if (implicit_counts[implicit_offset] <= frequent_implicit_threshold) {
					choices[pixel_index] = .{ .implicit = implicit_offset };
					continue;
				}
			}
		}

		var found_index: ?u32 = null;
		const num_colors = @divExact(palette_values.items.len, num_channels);
		color_search: for (0..num_colors) |color_index| {
			for (0..num_channels) |c| {
				if (palette_values.items[color_index * num_channels + c] != original[c * total + pixel_index]) {
					continue :color_search;
				}
			}
			found_index = @intCast(color_index);
			break;
		}

		const palette_index = found_index orelse blk: {
			const new_index: u32 = @intCast(palette_values.items.len / num_channels);
			for (0..num_channels) |c| {
				try palette_values.append(allocator, original[c * total + pixel_index]);
			}
			break :blk new_index;
		};
		choices[pixel_index] = .{ .explicit = palette_index };
	}

	const nb_colors: u32 = @intCast(palette_values.items.len / num_channels);
	const explicit_remap = try reorderExplicitPaletteByLuma(palette_values.items, num_channels, allocator);
	defer allocator.free(explicit_remap);
	try metaPalette(image, begin_c, end_c, nb_colors, 0, allocator);

	const palette_channel = &image.channels.items[0];
	if (palette_channel.h != num_channels or palette_channel.w != nb_colors) return error.GenericError;
	for (0..num_channels) |c| {
		for (0..nb_colors) |color_index| {
			palette_channel.row(c)[color_index] = palette_values.items[color_index * num_channels + c];
		}
	}

	for (0..total) |pixel_index| {
		indices[pixel_index] = switch (choices[pixel_index]) {
			.explicit => |palette_index| @intCast(explicit_remap[palette_index]),
			.implicit => |implicit_offset| @intCast(nb_colors + implicit_offset),
		};
	}

	const index_channel = &image.channels.items[begin_c + 1];
	@memcpy(index_channel.data[0..total], indices);

	return .{
		.id = .palette,
		.begin_c = begin_c,
		.num_c = end_c - begin_c + 1,
		.nb_colors = nb_colors,
		.nb_deltas = 0,
		.predictor = .zero,
		.allocator = allocator,
	};
}

fn predictPaletteSlowPath(channel: *const Channel, x: usize, y: usize, predictor: Predictor) pixel_type {
	const row = channel.rowConst(y);
	const left: pixel_type = if (x > 0) row[x - 1] else 0;
	return switch (predictor) {
		.zero => 0,
		.left => left,
		.gradient => blk: {
			const top: pixel_type = if (y > 0) channel.rowConst(y - 1)[x] else left;
			const topleft: pixel_type = if (x > 0 and y > 0) channel.rowConst(y - 1)[x - 1] else left;
			break :blk context_predict.clampedGradient(left, top, topleft);
		},
		else => left,
	};
}

/// Applies the first delta-palette encode slice: caller-supplied explicit delta tuples
/// and the same simplified predictor family the current decoder slow path already supports.
pub fn fwdPaletteWithDeltas(
	image: *Image,
	begin_c: u32,
	end_c: u32,
	delta_values: []const pixel_type,
	predictor: Predictor,
	allocator: std.mem.Allocator,
) JxlError!Transform {
	if (begin_c > end_c or end_c >= image.channels.items.len) return error.GenericError;
	if (delta_values.len == 0) return error.GenericError;
	try checkEqualChannels(image, begin_c, end_c);

	const num_channels: usize = end_c - begin_c + 1;
	if (@rem(delta_values.len, num_channels) != 0) return error.GenericError;
	const num_delta_tuples = @divExact(delta_values.len, num_channels);

	const source = &image.channels.items[begin_c];
	if (source.w == 0 or source.h == 0) return error.GenericError;

	var explicit_values: std.ArrayList(pixel_type) = .empty;
	defer explicit_values.deinit(allocator);
	const total = source.w * source.h;
	const indices = try allocator.alloc(pixel_type, total);
	defer allocator.free(indices);
	const bit_depth = @min(image.bitdepth, 24);

	const IndexChoice = union(enum) {
		delta: u32,
		explicit: u32,
		implicit: u32,
	};
	const choices = try allocator.alloc(IndexChoice, total);
	defer allocator.free(choices);

	for (0..source.h) |y| {
		for (0..source.w) |x| {
			const pixel_index = y * source.w + x;

			var found_delta: ?u32 = null;
			delta_search: for (0..num_delta_tuples) |delta_index| {
				for (0..num_channels) |c| {
					const channel = &image.channels.items[begin_c + c];
					const actual = channel.rowConst(y)[x];
					const pred = predictPaletteSlowPath(channel, x, y, predictor);
					const residual = actual - pred;
					if (delta_values[delta_index * num_channels + c] != residual) {
						continue :delta_search;
					}
				}
				found_delta = @intCast(delta_index);
				break;
			}
			if (found_delta) |delta_index| {
				choices[pixel_index] = .{ .delta = delta_index };
				continue;
			}

			var color_buf: [kRgbChannels]pixel_type = .{ 0, 0, 0 };
			if (num_channels <= kRgbChannels) {
				for (0..num_channels) |c| {
					color_buf[c] = image.channels.items[begin_c + c].rowConst(y)[x];
				}
				if (findImplicitPaletteOffset(color_buf[0..num_channels], bit_depth)) |implicit_offset| {
					choices[pixel_index] = .{ .implicit = implicit_offset };
					continue;
				}
			}

			var explicit_index: ?u32 = null;
			explicit_search: for (0..@divExact(explicit_values.items.len, num_channels)) |palette_index| {
				for (0..num_channels) |c| {
					const actual = image.channels.items[begin_c + c].rowConst(y)[x];
					if (explicit_values.items[palette_index * num_channels + c] != actual) {
						continue :explicit_search;
					}
				}
				explicit_index = @intCast(palette_index);
				break;
			}
			const palette_index = explicit_index orelse blk: {
				const new_index: u32 = @intCast(explicit_values.items.len / num_channels);
				for (0..num_channels) |c| {
					const actual = image.channels.items[begin_c + c].rowConst(y)[x];
					try explicit_values.append(allocator, actual);
				}
				break :blk new_index;
			};
			choices[pixel_index] = .{ .explicit = palette_index };
		}
	}

	const nb_colors: u32 = @intCast(explicit_values.items.len / num_channels);
	const nb_deltas: u32 = @intCast(num_delta_tuples);
	const explicit_remap = try reorderExplicitPaletteByLuma(explicit_values.items, num_channels, allocator);
	defer allocator.free(explicit_remap);
	try metaPalette(image, begin_c, end_c, nb_colors, nb_deltas, allocator);

	const palette_channel = &image.channels.items[0];
	if (palette_channel.h != num_channels or palette_channel.w != nb_colors + nb_deltas) return error.GenericError;
	for (0..num_channels) |c| {
		for (0..num_delta_tuples) |delta_index| {
			palette_channel.row(c)[delta_index] = delta_values[delta_index * num_channels + c];
		}
		for (0..nb_colors) |color_index| {
			palette_channel.row(c)[num_delta_tuples + color_index] = explicit_values.items[color_index * num_channels + c];
		}
	}

	for (0..total) |pixel_index| {
		indices[pixel_index] = switch (choices[pixel_index]) {
			.delta => |delta_index| @intCast(delta_index),
			.explicit => |palette_index| @intCast(num_delta_tuples + explicit_remap[palette_index]),
			.implicit => |implicit_offset| @intCast(num_delta_tuples + nb_colors + implicit_offset),
		};
	}

	const index_channel = &image.channels.items[begin_c + 1];
	@memcpy(index_channel.data[0..total], indices);

	return .{
		.id = .palette,
		.begin_c = begin_c,
		.num_c = @intCast(num_channels),
		.nb_colors = nb_colors,
		.nb_deltas = nb_deltas,
		.predictor = predictor,
		.allocator = allocator,
	};
}

const DeltaTupleCandidate = struct {
	values: []pixel_type,
	count: usize,
	first_seen: usize,
};

const DeltaBucketCandidate = struct {
	values: []pixel_type,
	total_count: usize,
	representative_index: usize,
	first_seen: usize,
};

fn deinitDeltaTupleCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList(DeltaTupleCandidate)) void {
	for (candidates.items) |candidate| {
		allocator.free(candidate.values);
	}
	candidates.deinit(allocator);
}

fn deinitDeltaBucketCandidates(allocator: std.mem.Allocator, buckets: *std.ArrayList(DeltaBucketCandidate)) void {
	for (buckets.items) |bucket| {
		allocator.free(bucket.values);
	}
	buckets.deinit(allocator);
}

fn roundIntSymmetric(value: pixel_type, div: pixel_type) pixel_type {
	if (value < 0) return -roundIntSymmetric(-value, div);
	return @divTrunc(value + @divTrunc(div, 2), div);
}

/// Measures how far a rounded delta bucket sits from zero so the palette
/// chooser can break frequency ties in favor of more meaningful residuals.
fn deltaBucketDistance(values: []const pixel_type) f64 {
	var squared_sum: f64 = 0;
	for (values) |value| {
		const f = @as(f64, @floatFromInt(value));
		squared_sum += f * f;
	}
	return @sqrt(squared_sum);
}

fn explicitPaletteLuma(values: []const pixel_type, num_channels: usize, color_index: usize) f32 {
	const base = color_index * num_channels;
	const r = @as(f32, @floatFromInt(values[base + 0]));
	const g = @as(f32, @floatFromInt(values[base + 1]));
	const b = @as(f32, @floatFromInt(values[base + 2]));
	return 0.299 * r + 0.587 * g + 0.114 * b;
}

/// Reorders explicit RGB palette rows by luma and returns an old-index to
/// new-index remap so callers can rewrite palette references after sorting.
fn reorderExplicitPaletteByLuma(
	values: []pixel_type,
	num_channels: usize,
	allocator: std.mem.Allocator,
) JxlError![]u32 {
	const nb_colors = @divExact(values.len, num_channels);
	const remap = try allocator.alloc(u32, nb_colors);
	errdefer allocator.free(remap);
	for (0..nb_colors) |color_index| {
		remap[color_index] = @intCast(color_index);
	}
	if (num_channels < 3 or nb_colors <= 1) return remap;

	var sorted = try allocator.alloc(pixel_type, values.len);
	defer allocator.free(sorted);
	var inverse_remap = try allocator.alloc(u32, nb_colors);
	defer allocator.free(inverse_remap);

	var i: usize = 1;
	while (i < nb_colors) : (i += 1) {
		const current = remap[i];
		const current_luma = explicitPaletteLuma(values, num_channels, current);
		var j = i;
		while (j > 0) {
			const prev = remap[j - 1];
			if (explicitPaletteLuma(values, num_channels, prev) <= current_luma) break;
			remap[j] = prev;
			j -= 1;
		}
		remap[j] = current;
	}

	for (remap, 0..) |old_index, new_index| {
		inverse_remap[old_index] = @intCast(new_index);
		for (0..num_channels) |c| {
			sorted[new_index * num_channels + c] = values[old_index * num_channels + c];
		}
	}
	@memcpy(values, sorted);
	@memcpy(remap, inverse_remap);
	return remap;
}

/// Collects the most common predictor residual tuples in first-seen order so
/// the first auto-delta palette slice can stay deterministic and testable.
fn chooseCommonDeltaTuples(
	image: *const Image,
	begin_c: u32,
	end_c: u32,
	max_deltas: usize,
	predictor: Predictor,
	allocator: std.mem.Allocator,
) JxlError![]pixel_type {
	if (max_deltas == 0) return error.GenericError;
	if (begin_c > end_c or end_c >= image.channels.items.len) return error.GenericError;
	try checkEqualChannels(image, begin_c, end_c);

	const num_channels: usize = end_c - begin_c + 1;
	const source = &image.channels.items[begin_c];
	var residual: []pixel_type = try allocator.alloc(pixel_type, num_channels);
	defer allocator.free(residual);

	var candidates: std.ArrayList(DeltaTupleCandidate) = .empty;
	defer deinitDeltaTupleCandidates(allocator, &candidates);

	var first_seen: usize = 0;
	for (0..source.h) |y| {
		for (0..source.w) |x| {
			for (0..num_channels) |c| {
				const channel = &image.channels.items[begin_c + c];
				const actual = channel.rowConst(y)[x];
				const pred = predictPaletteSlowPath(channel, x, y, predictor);
				residual[c] = actual - pred;
			}

			var found = false;
			for (candidates.items) |*candidate| {
				if (std.mem.eql(pixel_type, candidate.values, residual)) {
					candidate.count += 1;
					found = true;
					break;
				}
			}
			if (!found) {
				try candidates.append(allocator, .{
					.values = try allocator.dupe(pixel_type, residual),
					.count = 1,
					.first_seen = first_seen,
				});
			}
			first_seen += 1;
		}
	}

	if (candidates.items.len == 0) return error.GenericError;

	const bucket_shift: u5 = @intCast(@max(image.bitdepth - 8, 0));
	const bucket_size: pixel_type = @intCast(@as(i32, 3) << bucket_shift);
	var rounded = try allocator.alloc(pixel_type, num_channels);
	defer allocator.free(rounded);
	var buckets: std.ArrayList(DeltaBucketCandidate) = .empty;
	defer deinitDeltaBucketCandidates(allocator, &buckets);

	for (candidates.items, 0..) |candidate, candidate_index| {
		for (0..num_channels) |c| {
			rounded[c] = roundIntSymmetric(candidate.values[c], bucket_size);
		}

		var found_bucket = false;
		for (buckets.items) |*bucket| {
			if (!std.mem.eql(pixel_type, bucket.values, rounded)) continue;
			bucket.total_count += candidate.count;
			const representative = candidates.items[bucket.representative_index];
			if (candidate.count > representative.count or
				(candidate.count == representative.count and candidate.first_seen < representative.first_seen))
			{
				bucket.representative_index = candidate_index;
			}
			if (candidate.first_seen < bucket.first_seen) bucket.first_seen = candidate.first_seen;
			found_bucket = true;
			break;
		}
		if (!found_bucket) {
			try buckets.append(allocator, .{
				.values = try allocator.dupe(pixel_type, rounded),
				.total_count = candidate.count,
				.representative_index = candidate_index,
				.first_seen = candidate.first_seen,
			});
		}
	}

	const num_selected = @min(max_deltas, buckets.items.len);
	const selected = try allocator.alloc(pixel_type, num_selected * num_channels);
	errdefer allocator.free(selected);
	const used = try allocator.alloc(bool, buckets.items.len);
	defer allocator.free(used);
	@memset(used, false);

	for (0..num_selected) |selected_index| {
		var best_index: ?usize = null;
		for (buckets.items, 0..) |bucket, bucket_index| {
			if (used[bucket_index]) continue;
			if (best_index == null) {
				best_index = bucket_index;
				continue;
			}
			const best = buckets.items[best_index.?];
			const bucket_distance = deltaBucketDistance(bucket.values);
			const best_distance = deltaBucketDistance(best.values);
			if (bucket.total_count > best.total_count or
				(bucket.total_count == best.total_count and bucket_distance > best_distance) or
				(bucket.total_count == best.total_count and bucket_distance == best_distance and bucket.first_seen < best.first_seen))
			{
				best_index = bucket_index;
			}
		}
		const chosen = best_index orelse return error.GenericError;
		used[chosen] = true;
		const representative = candidates.items[buckets.items[chosen].representative_index];
		@memcpy(selected[selected_index * num_channels ..][0..num_channels], representative.values);
	}

	return selected;
}

/// Uses the most frequent residual tuples under the chosen predictor as the
/// first auto-discovered delta palette entries, then falls back to explicit colors.
pub fn fwdPaletteAutoDeltas(
	image: *Image,
	begin_c: u32,
	end_c: u32,
	max_deltas: usize,
	predictor: Predictor,
	allocator: std.mem.Allocator,
) JxlError!Transform {
	const delta_values = try chooseCommonDeltaTuples(image, begin_c, end_c, max_deltas, predictor, allocator);
	defer allocator.free(delta_values);
	return fwdPaletteWithDeltas(image, begin_c, end_c, delta_values, predictor, allocator);
}

pub fn metaPalette(image: *Image, begin_c: u32, end_c: u32, nb_colors: u32, nb_deltas: u32, allocator: std.mem.Allocator) JxlError!void {
	checkEqualChannels(image, begin_c, end_c) catch return error.GenericError;

    const nb: usize = end_c - begin_c + 1;
    if (begin_c >= image.nb_meta_channels) {
        image.nb_meta_channels += 1;
    } else {
        if (image.nb_meta_channels < nb) return error.GenericError;
        image.nb_meta_channels += 2 - nb;
    }

    // Remove channels [begin_c+1, end_c]
    var i: usize = 0;
    while (i < nb - 1) : (i += 1) {
        if (begin_c + 1 < image.channels.items.len) {
            var ch = image.channels.orderedRemove(begin_c + 1);
            ch.deinit();
        }
    }

    // Insert palette channel at front
    var pch = try Channel.create(allocator, nb_colors + nb_deltas, nb, -1, -1);
    errdefer pch.deinit();
    try image.channels.insert(allocator, 0, pch);
}

// ── InvPalette ──

const kRgbChannels: usize = 3;
const kLargeCube: i32 = 5;
const kSmallCube: i32 = 4;
const kSmallCubeBits: u5 = 2;
const kLargeCubeOffset: i32 = kSmallCube * kSmallCube * kSmallCube; // 64
const kImplicitPaletteSize: i32 = kLargeCubeOffset + kLargeCube * kLargeCube * kLargeCube; // 189

const kDeltaPalette = [72][3]pixel_type{
    .{ 0, 0, 0 },       .{ 4, 4, 4 },       .{ 11, 0, 0 },
    .{ 0, 0, -13 },     .{ 0, -12, 0 },     .{ -10, -10, -10 },
    .{ -18, -18, -18 }, .{ -27, -27, -27 }, .{ -18, -18, 0 },
    .{ 0, 0, -32 },     .{ -32, 0, 0 },     .{ -37, -37, -37 },
    .{ 0, -32, -32 },   .{ 24, 24, 45 },    .{ 50, 50, 50 },
    .{ -45, -24, -24 }, .{ -24, -45, -45 }, .{ 0, -24, -24 },
    .{ -34, -34, 0 },   .{ -24, 0, -24 },   .{ -45, -45, -24 },
    .{ 64, 64, 64 },    .{ -32, 0, -32 },   .{ 0, -32, 0 },
    .{ -32, 0, 32 },    .{ -24, -45, -24 }, .{ 45, 24, 45 },
    .{ 24, -24, -45 },  .{ -45, -24, 24 },  .{ 80, 80, 80 },
    .{ 64, 0, 0 },      .{ 0, 0, -64 },     .{ 0, -64, -64 },
    .{ -24, -24, 45 },  .{ 96, 96, 96 },    .{ 64, 64, 0 },
    .{ 45, -24, -24 },  .{ 34, -34, 0 },    .{ 112, 112, 112 },
    .{ 24, -45, -45 },  .{ 45, 45, -24 },   .{ 0, -32, 32 },
    .{ 24, -24, 45 },   .{ 0, 96, 96 },     .{ 45, -24, 24 },
    .{ 24, -45, -24 },  .{ -24, -45, 24 },  .{ 0, -64, 0 },
    .{ 96, 0, 0 },      .{ 128, 128, 128 }, .{ 64, 0, 64 },
    .{ 144, 144, 144 }, .{ 96, 96, 0 },     .{ -36, -36, 36 },
    .{ 45, -24, -45 },  .{ 45, -45, -24 },  .{ 0, 0, -96 },
    .{ 0, 128, 128 },   .{ 0, 96, 0 },      .{ 45, 24, -45 },
    .{ -128, 0, 0 },    .{ 24, -45, 24 },   .{ -45, 24, -45 },
    .{ 64, 0, -64 },    .{ 64, -64, -64 },  .{ 96, 0, 96 },
    .{ 45, -45, 24 },   .{ 24, 45, -45 },   .{ 64, 64, -64 },
    .{ 128, 128, 0 },   .{ 0, 0, -128 },    .{ -24, 45, -45 },
};

fn scalePalette(comptime denom: u64, value: u64, bit_depth: u64) pixel_type {
    return @intCast((value * ((@as(u64, 1) << @intCast(bit_depth)) - 1)) / denom);
}

/// Finds an exact decoder-visible implicit palette match for up to RGB channels
/// by scanning the built-in cube palettes the decoder already synthesizes.
fn findImplicitPaletteOffset(color: []const pixel_type, bit_depth: i32) ?u32 {
	if (color.len == 0 or color.len > kRgbChannels) return null;

	for (0..@as(usize, @intCast(kImplicitPaletteSize))) |implicit_offset| {
		var matches = true;
		for (color, 0..) |value, c| {
			if (getPaletteValue(&.{}, 0, @intCast(implicit_offset), c, 0, bit_depth) != value) {
				matches = false;
				break;
			}
		}
		if (matches) return @intCast(implicit_offset);
	}
	return null;
}

fn getPaletteValue(palette_data: []const pixel_type, palette_w: usize, index_in: i32, c: usize, palette_size: i32, bit_depth: i32) pixel_type {
    var index = index_in;
    if (index < 0) {
        if (c >= kRgbChannels) return 0;
        index = -(index + 1);
        const delta_palette_len: i32 = @intCast(2 * (kDeltaPalette.len - 1) + 1);
        index = @rem(index, delta_palette_len);
        const half_idx: usize = @intCast(@divTrunc(index + 1, 2));
        const multiplier: pixel_type = if ((index & 1) != 0) 1 else -1;
        var result = kDeltaPalette[half_idx][c] * multiplier;
        if (bit_depth > 8) {
            result *= @as(pixel_type, 1) << @intCast(bit_depth - 8);
        }
        return result;
    } else if (index >= palette_size and index < palette_size + kLargeCubeOffset) {
        if (c >= kRgbChannels) return 0;
        var idx = index - palette_size;
        idx >>= @intCast(c * kSmallCubeBits);
        return scalePalette(kSmallCube, @intCast(@rem(idx, kSmallCube)), @intCast(bit_depth)) +
            (@as(pixel_type, 1) << @intCast(@max(0, bit_depth - 3)));
    } else if (index >= palette_size + kLargeCubeOffset) {
        if (c >= kRgbChannels) return 0;
        var idx = index - palette_size - kLargeCubeOffset;
        switch (c) {
            1 => idx = @divTrunc(idx, kLargeCube),
            2 => idx = @divTrunc(idx, kLargeCube * kLargeCube),
            else => {},
        }
        return scalePalette(kLargeCube - 1, @intCast(@rem(idx, kLargeCube)), @intCast(bit_depth));
    }
    // Normal palette lookup
    const row_idx: usize = @intCast(index);
    const num_rows = palette_data.len / palette_w;
    if (row_idx < palette_w and c < num_rows) {
        return palette_data[c * palette_w + row_idx];
    }
    return 0;
}

pub fn invPalette(image: *Image, begin_c: u32, nb_colors: u32, nb_deltas: u32, predictor: Predictor) JxlError!void {
    _ = nb_colors;
    if (image.nb_meta_channels < 1) return error.GenericError;

    const nb: usize = image.channels.items[0].h; // palette height = number of output channels
    const c0: usize = begin_c + 1;
    if (c0 >= image.channels.items.len) return error.GenericError;
    const w = image.channels.items[c0].w;
    const h = image.channels.items[c0].h;
    if (nb < 1) return error.GenericError;

    const allocator = image.allocator;
    const palette = &image.channels.items[0];
    const palette_data = palette.data;
    const palette_w = palette.w;
    const palette_size: i32 = @intCast(palette.w);
    const bit_depth = @min(image.bitdepth, 24);

    // Create output channels (nb-1 new ones after c0)
    var i: usize = 1;
    while (i < nb) : (i += 1) {
        var ch = try Channel.create(allocator, w, h, image.channels.items[c0].hshift, image.channels.items[c0].vshift);
        errdefer ch.deinit();
        try image.channels.insert(allocator, c0 + 1, ch);
    }

    if (w == 0) {
        // Nothing to do for empty channels
    } else if (nb_deltas == 0 and predictor == .zero) {
        // Fast path: direct palette lookup
        for (0..h) |y| {
            const p_index = image.channels.items[c0].rowConst(y);
            var p_outs: [256][]pixel_type = undefined;
            const nb_clamped = @min(nb, 256);
            for (0..nb_clamped) |c| {
                p_outs[c] = image.channels.items[c0 + c].row(y);
            }
            for (0..w) |x| {
                const index: i32 = p_index[x];
                for (0..nb_clamped) |c| {
                    p_outs[c][x] = getPaletteValue(palette_data, palette_w, index, c, palette_size, bit_depth);
                }
            }
        }
    } else {
        // Slow path with delta prediction — simplified (no weighted predictor)
        // Save index data
        const idx_data = allocator.alloc(pixel_type, w * h) catch return error.GenericError;
        defer allocator.free(idx_data);
        @memcpy(idx_data, image.channels.items[c0].data[0 .. w * h]);

        for (0..nb) |c| {
            const channel = &image.channels.items[c0 + c];
            for (0..h) |y| {
                const p = channel.row(y);
                for (0..w) |x| {
                    const index: i32 = idx_data[y * w + x];
                    const palette_entry = getPaletteValue(palette_data, palette_w, index, c, palette_size, bit_depth);
                    if (index < @as(i32, @intCast(nb_deltas))) {
                        // Delta: use simple prediction (left neighbor)
                        const left: pixel_type = if (x > 0) p[x - 1] else 0;
                        const pred = switch (predictor) {
                            .zero => @as(pixel_type, 0),
                            .left => left,
                            .gradient => blk: {
                                const top: pixel_type = if (y > 0) channel.rowConst(y - 1)[x] else left;
                                const topleft: pixel_type = if (x > 0 and y > 0) channel.rowConst(y - 1)[x - 1] else left;
                                break :blk context_predict.clampedGradient(left, top, topleft);
                            },
                            else => left,
                        };
                        p[x] = pixelAdd(pred, palette_entry);
                    } else {
                        p[x] = palette_entry;
                    }
                }
            }
        }
    }

    // Update meta channels
    if (c0 >= image.nb_meta_channels) {
        if (image.nb_meta_channels > 0) image.nb_meta_channels -= 1;
    } else {
        if (image.nb_meta_channels >= 2 - nb) {
            image.nb_meta_channels -= 2 - nb;
        }
    }
    // Remove palette channel (channel 0)
    var pch = image.channels.orderedRemove(0);
    pch.deinit();
}

// ── Undo all transforms on an image (in reverse order) ──

pub fn undoTransforms(image: *Image, wp_header: *const weighted.Header) JxlError!void {
    _ = wp_header;
    var ti: isize = @intCast(image.transforms.items.len);
    ti -= 1;
    while (ti >= 0) : (ti -= 1) {
        const t = image.transforms.items[@intCast(ti)];
        switch (t.id) {
            .rct => try invRCT(image, t.begin_c, t.rct_type),
            .squeeze => try invSqueeze(image, t.squeezes),
            .palette => try invPalette(image, t.begin_c, t.nb_colors, t.nb_deltas, t.predictor),
            .invalid => return error.GenericError,
        }
    }
}

// ── MetaApply: dispatch forward transform metadata ──

pub fn metaApply(image: *Image, t: *Transform, allocator: std.mem.Allocator) JxlError!void {
    switch (t.id) {
        .rct => {
            try checkEqualChannels(image, t.begin_c, t.begin_c + 2);
        },
        .squeeze => {
            try metaSqueeze(image, &t.squeezes, allocator);
        },
        .palette => {
            try metaPalette(image, t.begin_c, t.begin_c + t.num_c - 1, t.nb_colors, t.nb_deltas, allocator);
        },
        .invalid => return error.GenericError,
    }
}

// ── Tests ──

const testing = std.testing;

test "SqueezeParams defaults" {
    const sp = SqueezeParams{};
    try testing.expect(!sp.horizontal);
    try testing.expect(!sp.in_place);
    try testing.expectEqual(@as(u32, 0), sp.begin_c);
    try testing.expectEqual(@as(u32, 2), sp.num_c);
}

test "Transform default" {
    const t = Transform{};
    try testing.expectEqual(TransformId.invalid, t.id);
    try testing.expectEqual(@as(u32, 6), t.rct_type);
}

test "pixelAdd wrapping" {
    try testing.expectEqual(@as(pixel_type, 3), pixelAdd(1, 2));
    // wrapping: max_i32 + 1 wraps
    try testing.expectEqual(@as(pixel_type, @bitCast(@as(u32, 0x80000000))), pixelAdd(std.math.maxInt(pixel_type), 1));
}

test "smoothTendency monotone increasing" {
    // B=0, a=10, n=20 => increasing, diff should be negative (pulls estimate down)
    const diff = smoothTendency(0, 10, 20);
    try testing.expect(diff <= 0);
}

test "smoothTendency monotone decreasing" {
    // B=20, a=10, n=0 => decreasing, diff should be positive
    const diff = smoothTendency(20, 10, 0);
    try testing.expect(diff >= 0);
}

test "smoothTendency flat" {
    // B=10, a=10, n=10 => flat, diff=0
    try testing.expectEqual(@as(pixel_type_w, 0), smoothTendency(10, 10, 10));
}

test "invRCT YCoCg roundtrip" {
    const allocator = testing.allocator;
    // Create 3-channel 2x1 image
    var img = try Image.create(allocator, 2, 1, 8, 3);
    defer img.deinit();

    // Set YCoCg values: Y=128, Co=10, Cg=20
    img.channels.items[0].row(0)[0] = 128;
    img.channels.items[0].row(0)[1] = 100;
    img.channels.items[1].row(0)[0] = 10;
    img.channels.items[1].row(0)[1] = -5;
    img.channels.items[2].row(0)[0] = 20;
    img.channels.items[2].row(0)[1] = 8;

    // rct_type=6 is YCoCg with permutation=0
    try invRCT(&img, 0, 6);

    // Just verify it didn't crash and values changed
    try testing.expect(img.channels.items[0].row(0)[0] != 128);
}

test "fwdRCT YCoCg round-trips exactly through invRCT" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 3, 2, 8, 3);
    defer img.deinit();

    const original = [_][3]pixel_type{
        .{ 12, 34, 56 },
        .{ -3, 22, 101 },
        .{ 127, -18, 9 },
        .{ 0, 0, 0 },
        .{ -40, 17, -9 },
        .{ 5, -7, 11 },
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx][0];
            img.channels.items[1].row(y)[x] = original[idx][1];
            img.channels.items[2].row(y)[x] = original[idx][2];
            idx += 1;
        }
    }

    try fwdRCT(&img, 0, 6);
    try invRCT(&img, 0, 6);

    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx][0], img.channels.items[0].rowConst(y)[x]);
            try testing.expectEqual(original[idx][1], img.channels.items[1].rowConst(y)[x]);
            try testing.expectEqual(original[idx][2], img.channels.items[2].rowConst(y)[x]);
            idx += 1;
        }
    }
}

test "fwdPalette grayscale round-trips exactly through invPalette" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 4, 3, 8, 1);
    defer img.deinit();

    const original = [_]pixel_type{
        5, 7, 5, 9,
        7, 5, 9, 9,
        5, 7, 5, 9,
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx];
            idx += 1;
        }
    }

    const palette = try fwdPalette(&img, 0, 0, allocator);
    try testing.expectEqual(TransformId.palette, palette.id);
    try testing.expectEqual(@as(u32, 0), palette.begin_c);
    try testing.expectEqual(@as(u32, 1), palette.num_c);
    try testing.expectEqual(@as(u32, 3), palette.nb_colors);
    try testing.expectEqual(@as(u32, 0), palette.nb_deltas);
    try testing.expectEqual(Predictor.zero, palette.predictor);

    try testing.expectEqual(@as(usize, 2), img.channels.items.len);
    try testing.expectEqual(@as(usize, 1), img.channels.items[0].h);
    try testing.expectEqual(@as(usize, 3), img.channels.items[0].w);
    try testing.expectEqualSlices(pixel_type, &.{ 5, 7, 9 }, img.channels.items[0].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ 0, 1, 0, 2 }, img.channels.items[1].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ 1, 0, 2, 2 }, img.channels.items[1].rowConst(1));
    try testing.expectEqualSlices(pixel_type, &.{ 0, 1, 0, 2 }, img.channels.items[1].rowConst(2));

    try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

    try testing.expectEqual(@as(usize, 1), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx], img.channels.items[0].rowConst(y)[x]);
            idx += 1;
        }
    }
}

test "fwdPalette RGB round-trips exactly through invPalette" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 3, 2, 8, 3);
    defer img.deinit();

    const original = [_][3]pixel_type{
        .{ 10, 20, 30 },
        .{ 3, 4, 5 },
        .{ 10, 20, 30 },
        .{ 9, 9, 1 },
        .{ 3, 4, 5 },
        .{ 9, 9, 1 },
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx][0];
            img.channels.items[1].row(y)[x] = original[idx][1];
            img.channels.items[2].row(y)[x] = original[idx][2];
            idx += 1;
        }
    }

    const palette = try fwdPalette(&img, 0, 2, allocator);
    try testing.expectEqual(TransformId.palette, palette.id);
    try testing.expectEqual(@as(u32, 0), palette.begin_c);
    try testing.expectEqual(@as(u32, 3), palette.num_c);
    try testing.expectEqual(@as(u32, 3), palette.nb_colors);
    try testing.expectEqual(@as(u32, 0), palette.nb_deltas);
    try testing.expectEqual(Predictor.zero, palette.predictor);

	try testing.expectEqual(@as(usize, 2), img.channels.items.len);
	try testing.expectEqual(@as(usize, 3), img.channels.items[0].h);
	try testing.expectEqual(@as(usize, 3), img.channels.items[0].w);
	try testing.expectEqualSlices(pixel_type, &.{ 3, 9, 10 }, img.channels.items[0].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{ 4, 9, 20 }, img.channels.items[0].rowConst(1));
	try testing.expectEqualSlices(pixel_type, &.{ 5, 1, 30 }, img.channels.items[0].rowConst(2));
	try testing.expectEqualSlices(pixel_type, &.{ 2, 0, 2 }, img.channels.items[1].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{ 1, 0, 1 }, img.channels.items[1].rowConst(1));

    try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

    try testing.expectEqual(@as(usize, 3), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx][0], img.channels.items[0].rowConst(y)[x]);
            try testing.expectEqual(original[idx][1], img.channels.items[1].rowConst(y)[x]);
            try testing.expectEqual(original[idx][2], img.channels.items[2].rowConst(y)[x]);
            idx += 1;
        }
	}
}

test "fwdPalette RGB uses implicit colors without explicit palette rows" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 2, 2, 8, 3);
	defer img.deinit();

	const black = [_]pixel_type{
		getPaletteValue(&.{}, 0, 64, 0, 0, 8),
		getPaletteValue(&.{}, 0, 64, 1, 0, 8),
		getPaletteValue(&.{}, 0, 64, 2, 0, 8),
	};
	const white = [_]pixel_type{
		getPaletteValue(&.{}, 0, 188, 0, 0, 8),
		getPaletteValue(&.{}, 0, 188, 1, 0, 8),
		getPaletteValue(&.{}, 0, 188, 2, 0, 8),
	};
	const original = [_][3]pixel_type{
		black,
		white,
		white,
		black,
	};

	var idx: usize = 0;
	for (0..img.h) |y| {
		for (0..img.w) |x| {
			img.channels.items[0].row(y)[x] = original[idx][0];
			img.channels.items[1].row(y)[x] = original[idx][1];
			img.channels.items[2].row(y)[x] = original[idx][2];
			idx += 1;
		}
	}

	const palette = try fwdPalette(&img, 0, 2, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 0), palette.nb_colors);
	try testing.expectEqual(@as(u32, 0), palette.nb_deltas);
	try testing.expectEqual(@as(usize, 0), img.channels.items[0].w);
	try testing.expectEqualSlices(pixel_type, &.{ 64, 188 }, img.channels.items[1].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{ 188, 64 }, img.channels.items[1].rowConst(1));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

	try testing.expectEqual(@as(usize, 3), img.channels.items.len);
	idx = 0;
	for (0..img.h) |y| {
		for (0..img.w) |x| {
			try testing.expectEqual(original[idx][0], img.channels.items[0].rowConst(y)[x]);
			try testing.expectEqual(original[idx][1], img.channels.items[1].rowConst(y)[x]);
			try testing.expectEqual(original[idx][2], img.channels.items[2].rowConst(y)[x]);
			idx += 1;
		}
	}
}

test "fwdPalette RGB promotes frequent implicit colors into explicit palette rows" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 4, 3, 8, 3);
	defer img.deinit();

	const black = [_]pixel_type{
		getPaletteValue(&.{}, 0, 64, 0, 0, 8),
		getPaletteValue(&.{}, 0, 64, 1, 0, 8),
		getPaletteValue(&.{}, 0, 64, 2, 0, 8),
	};
	const white = [_]pixel_type{
		getPaletteValue(&.{}, 0, 188, 0, 0, 8),
		getPaletteValue(&.{}, 0, 188, 1, 0, 8),
		getPaletteValue(&.{}, 0, 188, 2, 0, 8),
	};

	for (0..img.h) |y| {
		for (0..img.w) |x| {
			const color = if (y == img.h - 1 and x == img.w - 1) black else white;
			img.channels.items[0].row(y)[x] = color[0];
			img.channels.items[1].row(y)[x] = color[1];
			img.channels.items[2].row(y)[x] = color[2];
		}
	}

	const palette = try fwdPalette(&img, 0, 2, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 1), palette.nb_colors);
	try testing.expectEqual(@as(u32, 0), palette.nb_deltas);
	try testing.expectEqual(@as(usize, 1), img.channels.items[0].w);
	try testing.expectEqualSlices(pixel_type, &.{255}, img.channels.items[0].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{255}, img.channels.items[0].rowConst(1));
	try testing.expectEqualSlices(pixel_type, &.{255}, img.channels.items[0].rowConst(2));
	try testing.expectEqual(@as(pixel_type, 65), img.channels.items[1].rowConst(2)[3]);

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

	for (0..img.h) |y| {
		for (0..img.w) |x| {
			const color = if (y == img.h - 1 and x == img.w - 1) black else white;
			try testing.expectEqual(color[0], img.channels.items[0].rowConst(y)[x]);
			try testing.expectEqual(color[1], img.channels.items[1].rowConst(y)[x]);
			try testing.expectEqual(color[2], img.channels.items[2].rowConst(y)[x]);
		}
	}
}

test "fwdPalette RGB orders explicit colors by luma instead of image order" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 3, 1, 8, 3);
	defer img.deinit();

	const original = [_][3]pixel_type{
		.{ 100, 0, 0 },
		.{ 0, 100, 0 },
		.{ 0, 0, 100 },
	};

	for (0..img.w) |x| {
		img.channels.items[0].row(0)[x] = original[x][0];
		img.channels.items[1].row(0)[x] = original[x][1];
		img.channels.items[2].row(0)[x] = original[x][2];
	}

	const palette = try fwdPalette(&img, 0, 2, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 3), palette.nb_colors);
	try testing.expectEqualSlices(pixel_type, &.{ 0, 100, 0 }, img.channels.items[0].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{ 0, 0, 100 }, img.channels.items[0].rowConst(1));
	try testing.expectEqualSlices(pixel_type, &.{ 100, 0, 0 }, img.channels.items[0].rowConst(2));
	try testing.expectEqualSlices(pixel_type, &.{ 1, 2, 0 }, img.channels.items[1].rowConst(0));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

	for (0..img.w) |x| {
		try testing.expectEqual(original[x][0], img.channels.items[0].rowConst(0)[x]);
		try testing.expectEqual(original[x][1], img.channels.items[1].rowConst(0)[x]);
		try testing.expectEqual(original[x][2], img.channels.items[2].rowConst(0)[x]);
	}
}

test "fwdPaletteWithDeltas grayscale round-trips exactly through invPalette" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 4, 2, 8, 1);
    defer img.deinit();

    const original = [_]pixel_type{
        10, 12, 14, 16,
        1, 3, 5, 7,
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx];
            idx += 1;
        }
    }

    const palette = try fwdPaletteWithDeltas(&img, 0, 0, &.{2}, .left, allocator);
    try testing.expectEqual(TransformId.palette, palette.id);
    try testing.expectEqual(@as(u32, 0), palette.begin_c);
    try testing.expectEqual(@as(u32, 1), palette.num_c);
    try testing.expectEqual(@as(u32, 2), palette.nb_colors);
    try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
    try testing.expectEqual(Predictor.left, palette.predictor);

    try testing.expectEqual(@as(usize, 2), img.channels.items.len);
    try testing.expectEqual(@as(usize, 1), img.channels.items[0].h);
    try testing.expectEqual(@as(usize, 3), img.channels.items[0].w);
    try testing.expectEqualSlices(pixel_type, &.{ 2, 10, 1 }, img.channels.items[0].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ 1, 0, 0, 0 }, img.channels.items[1].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ 2, 0, 0, 0 }, img.channels.items[1].rowConst(1));

    try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

    try testing.expectEqual(@as(usize, 1), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx], img.channels.items[0].rowConst(y)[x]);
            idx += 1;
        }
    }
}

test "fwdPaletteWithDeltas RGB round-trips exactly through invPalette" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 3, 2, 8, 3);
    defer img.deinit();

    const original = [_][3]pixel_type{
        .{ 10, 20, 30 },
        .{ 11, 19, 32 },
        .{ 12, 18, 34 },
        .{ 5, 5, 5 },
        .{ 6, 4, 7 },
        .{ 7, 3, 9 },
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx][0];
            img.channels.items[1].row(y)[x] = original[idx][1];
            img.channels.items[2].row(y)[x] = original[idx][2];
            idx += 1;
        }
    }

    const palette = try fwdPaletteWithDeltas(&img, 0, 2, &.{ 1, -1, 2 }, .left, allocator);
    try testing.expectEqual(TransformId.palette, palette.id);
    try testing.expectEqual(@as(u32, 0), palette.begin_c);
    try testing.expectEqual(@as(u32, 3), palette.num_c);
    try testing.expectEqual(@as(u32, 2), palette.nb_colors);
    try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
    try testing.expectEqual(Predictor.left, palette.predictor);

    try testing.expectEqual(@as(usize, 2), img.channels.items.len);
    try testing.expectEqual(@as(usize, 3), img.channels.items[0].h);
    try testing.expectEqual(@as(usize, 3), img.channels.items[0].w);
    try testing.expectEqualSlices(pixel_type, &.{ 1, 5, 10 }, img.channels.items[0].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ -1, 5, 20 }, img.channels.items[0].rowConst(1));
    try testing.expectEqualSlices(pixel_type, &.{ 2, 5, 30 }, img.channels.items[0].rowConst(2));
    try testing.expectEqualSlices(pixel_type, &.{ 2, 0, 0 }, img.channels.items[1].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ 1, 0, 0 }, img.channels.items[1].rowConst(1));

    try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

    try testing.expectEqual(@as(usize, 3), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx][0], img.channels.items[0].rowConst(y)[x]);
            try testing.expectEqual(original[idx][1], img.channels.items[1].rowConst(y)[x]);
            try testing.expectEqual(original[idx][2], img.channels.items[2].rowConst(y)[x]);
            idx += 1;
        }
	}
}

test "fwdPaletteWithDeltas RGB reuses implicit colors alongside delta entries" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 3, 1, 8, 3);
	defer img.deinit();

	const black = [_]pixel_type{
		getPaletteValue(&.{}, 0, 64, 0, 0, 8),
		getPaletteValue(&.{}, 0, 64, 1, 0, 8),
		getPaletteValue(&.{}, 0, 64, 2, 0, 8),
	};
	const white = [_]pixel_type{
		getPaletteValue(&.{}, 0, 188, 0, 0, 8),
		getPaletteValue(&.{}, 0, 188, 1, 0, 8),
		getPaletteValue(&.{}, 0, 188, 2, 0, 8),
	};
	const original = [_][3]pixel_type{
		black,
		white,
		.{ 254, 255, 255 },
	};

	for (0..img.w) |x| {
		img.channels.items[0].row(0)[x] = original[x][0];
		img.channels.items[1].row(0)[x] = original[x][1];
		img.channels.items[2].row(0)[x] = original[x][2];
	}

	const palette = try fwdPaletteWithDeltas(&img, 0, 2, &.{ -1, 0, 0 }, .left, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 0), palette.nb_colors);
	try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
	try testing.expectEqual(@as(usize, 1), img.channels.items[0].w);
	try testing.expectEqualSlices(pixel_type, &.{-1}, img.channels.items[0].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{0}, img.channels.items[0].rowConst(1));
	try testing.expectEqualSlices(pixel_type, &.{0}, img.channels.items[0].rowConst(2));
	try testing.expectEqualSlices(pixel_type, &.{ 65, 189, 0 }, img.channels.items[1].rowConst(0));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

	try testing.expectEqual(@as(usize, 3), img.channels.items.len);
	for (0..img.w) |x| {
		try testing.expectEqual(original[x][0], img.channels.items[0].rowConst(0)[x]);
		try testing.expectEqual(original[x][1], img.channels.items[1].rowConst(0)[x]);
		try testing.expectEqual(original[x][2], img.channels.items[2].rowConst(0)[x]);
	}
}

test "fwdPaletteWithDeltas RGB orders explicit fallback rows by luma" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 4, 1, 8, 3);
	defer img.deinit();

	const original = [_][3]pixel_type{
		.{ 50, 0, 0 },
		.{ 0, 50, 0 },
		.{ 0, 0, 50 },
		.{ 1, 0, 50 },
	};

	for (0..img.w) |x| {
		img.channels.items[0].row(0)[x] = original[x][0];
		img.channels.items[1].row(0)[x] = original[x][1];
		img.channels.items[2].row(0)[x] = original[x][2];
	}

	const palette = try fwdPaletteWithDeltas(&img, 0, 2, &.{ 1, 0, 0 }, .left, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 3), palette.nb_colors);
	try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
	try testing.expectEqualSlices(pixel_type, &.{ 1, 0, 50, 0 }, img.channels.items[0].rowConst(0));
	try testing.expectEqualSlices(pixel_type, &.{ 0, 0, 0, 50 }, img.channels.items[0].rowConst(1));
	try testing.expectEqualSlices(pixel_type, &.{ 0, 50, 0, 0 }, img.channels.items[0].rowConst(2));
	try testing.expectEqualSlices(pixel_type, &.{ 2, 3, 1, 0 }, img.channels.items[1].rowConst(0));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

	for (0..img.w) |x| {
		try testing.expectEqual(original[x][0], img.channels.items[0].rowConst(0)[x]);
		try testing.expectEqual(original[x][1], img.channels.items[1].rowConst(0)[x]);
		try testing.expectEqual(original[x][2], img.channels.items[2].rowConst(0)[x]);
	}
}

test "fwdPaletteAutoDeltas RGB selects the common delta tuple and round-trips" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 3, 2, 8, 3);
    defer img.deinit();

    const original = [_][3]pixel_type{
        .{ 10, 20, 30 },
        .{ 11, 19, 32 },
        .{ 12, 18, 34 },
        .{ 5, 5, 5 },
        .{ 6, 4, 7 },
        .{ 7, 3, 9 },
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx][0];
            img.channels.items[1].row(y)[x] = original[idx][1];
            img.channels.items[2].row(y)[x] = original[idx][2];
            idx += 1;
        }
    }

    const palette = try fwdPaletteAutoDeltas(&img, 0, 2, 1, .left, allocator);
    try testing.expectEqual(TransformId.palette, palette.id);
    try testing.expectEqual(@as(u32, 3), palette.num_c);
    try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
    try testing.expectEqualSlices(pixel_type, &.{ 1, 5, 10 }, img.channels.items[0].rowConst(0));
    try testing.expectEqualSlices(pixel_type, &.{ -1, 5, 20 }, img.channels.items[0].rowConst(1));
    try testing.expectEqualSlices(pixel_type, &.{ 2, 5, 30 }, img.channels.items[0].rowConst(2));

    try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);

    try testing.expectEqual(@as(usize, 3), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx][0], img.channels.items[0].rowConst(y)[x]);
            try testing.expectEqual(original[idx][1], img.channels.items[1].rowConst(y)[x]);
            try testing.expectEqual(original[idx][2], img.channels.items[2].rowConst(y)[x]);
            idx += 1;
        }
	}
}

test "fwdPaletteAutoDeltas grayscale prefers the densest residual bucket" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 3, 1, 8, 1);
	defer img.deinit();

	const original = [_]pixel_type{ 30, 35, 41 };
	for (0..img.w) |x| {
		img.channels.items[0].row(0)[x] = original[x];
	}

	const palette = try fwdPaletteAutoDeltas(&img, 0, 0, 1, .left, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
	try testing.expectEqualSlices(pixel_type, &.{ 5, 30, 41 }, img.channels.items[0].rowConst(0));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);
	try testing.expectEqualSlices(pixel_type, &original, img.channels.items[0].rowConst(0));
}

test "fwdPaletteAutoDeltas grayscale bucket scoring prefers larger-magnitude ties" {
	const allocator = testing.allocator;
	var img = try Image.create(allocator, 4, 1, 8, 1);
	defer img.deinit();

	const original = [_]pixel_type{ 5, 11, 41, 72 };
	for (0..img.w) |x| {
		img.channels.items[0].row(0)[x] = original[x];
	}

	const palette = try fwdPaletteAutoDeltas(&img, 0, 0, 1, .left, allocator);
	try testing.expectEqual(TransformId.palette, palette.id);
	try testing.expectEqual(@as(u32, 1), palette.nb_deltas);
	try testing.expectEqualSlices(pixel_type, &.{ 30, 5, 11, 72 }, img.channels.items[0].rowConst(0));

	try invPalette(&img, palette.begin_c, palette.nb_colors, palette.nb_deltas, palette.predictor);
	try testing.expectEqualSlices(pixel_type, &original, img.channels.items[0].rowConst(0));
}

test "fwdSqueeze round-trips exactly through invSqueeze" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 5, 4, 8, 1);
    defer img.deinit();

    const original = [_]pixel_type{
        9, 3, 8, 2, 7,
        1, 4, 6, 5, 0,
        -3, -1, 2, 4, 6,
        10, 8, 6, 4, 2,
    };

    var idx: usize = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            img.channels.items[0].row(y)[x] = original[idx];
            idx += 1;
        }
    }

    var squeezes = [_]SqueezeParams{
        .{
            .horizontal = true,
            .in_place = false,
            .begin_c = 0,
            .num_c = 1,
        },
        .{
            .horizontal = false,
            .in_place = false,
            .begin_c = 0,
            .num_c = 1,
        },
    };

    try fwdSqueeze(&img, squeezes[0..]);
    try invSqueeze(&img, squeezes[0..]);

    try testing.expectEqual(@as(usize, 1), img.channels.items.len);
    idx = 0;
    for (0..img.h) |y| {
        for (0..img.w) |x| {
            try testing.expectEqual(original[idx], img.channels.items[0].rowConst(y)[x]);
            idx += 1;
        }
    }
}
