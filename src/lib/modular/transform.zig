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
        t.id = std.meta.intToEnum(TransformId, @as(u32, @intCast(id_sel))) catch return error.GenericError;
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
            t.predictor = std.meta.intToEnum(Predictor, pred_val) catch return error.GenericError;
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
