// Loop filter parameters, stored in each frame.
// Transliterated from lib/jxl/loop_filter.h and lib/jxl/loop_filter.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");

pub const kEpfSharpEntries: usize = 8;

pub const LoopFilter = struct {
    // Gaborish
    gab: bool = true,
    gab_custom: bool = false,
    gab_x_weight1: f32 = 0,
    gab_x_weight2: f32 = 0,
    gab_y_weight1: f32 = 0,
    gab_y_weight2: f32 = 0,
    gab_b_weight1: f32 = 0,
    gab_b_weight2: f32 = 0,

    // Edge-preserving filter
    epf_iters: u32 = 2,

    epf_sharp_custom: bool = false,
    epf_sharp_lut: [kEpfSharpEntries]f32 = [_]f32{0} ** kEpfSharpEntries,

    epf_weight_custom: bool = false,
    epf_channel_scale: [3]f32 = .{ 0, 0, 0 },
    epf_pass1_zeroflush: f32 = 0,
    epf_pass2_zeroflush: f32 = 0,

    epf_sigma_custom: bool = false,
    epf_quant_mul: f32 = 0,
    epf_pass0_sigma_scale: f32 = 0,
    epf_pass2_sigma_scale: f32 = 0,
    epf_border_sad_mul: f32 = 0,

    epf_sigma_for_modular: f32 = 0,

    extensions: u64 = 0,

    pub fn readFromBitStream(br: *BitReader, is_modular: bool) JxlError!LoopFilter {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return LoopFilter{};
        }

        var lf = LoopFilter{};

        // Gaborish
        lf.gab = br.readBits(1) != 0;
        if (lf.gab) {
            lf.gab_custom = br.readBits(1) != 0;
            if (lf.gab_custom) {
                lf.gab_x_weight1 = try fc.F16Coder.read(br);
                lf.gab_x_weight2 = try fc.F16Coder.read(br);
                if (@abs(1.0 + (lf.gab_x_weight1 + lf.gab_x_weight2) * 4.0) < 1e-8) {
                    return error.GenericError;
                }
                lf.gab_y_weight1 = try fc.F16Coder.read(br);
                lf.gab_y_weight2 = try fc.F16Coder.read(br);
                if (@abs(1.0 + (lf.gab_y_weight1 + lf.gab_y_weight2) * 4.0) < 1e-8) {
                    return error.GenericError;
                }
                lf.gab_b_weight1 = try fc.F16Coder.read(br);
                lf.gab_b_weight2 = try fc.F16Coder.read(br);
                if (@abs(1.0 + (lf.gab_b_weight1 + lf.gab_b_weight2) * 4.0) < 1e-8) {
                    return error.GenericError;
                }
            }
        }

        // EPF iterations (default 2)
        lf.epf_iters = @intCast(br.readBits(2));

        if (lf.epf_iters > 0) {
            // Sharp LUT (only for VarDCT)
            if (!is_modular) {
                lf.epf_sharp_custom = br.readBits(1) != 0;
                if (lf.epf_sharp_custom) {
                    for (0..kEpfSharpEntries) |i| {
                        lf.epf_sharp_lut[i] = try fc.F16Coder.read(br);
                    }
                }
            }

            // Weight parameters
            lf.epf_weight_custom = br.readBits(1) != 0;
            if (lf.epf_weight_custom) {
                lf.epf_channel_scale[0] = try fc.F16Coder.read(br);
                lf.epf_channel_scale[1] = try fc.F16Coder.read(br);
                lf.epf_channel_scale[2] = try fc.F16Coder.read(br);
                lf.epf_pass1_zeroflush = try fc.F16Coder.read(br);
                lf.epf_pass2_zeroflush = try fc.F16Coder.read(br);
            }

            // Sigma parameters
            lf.epf_sigma_custom = br.readBits(1) != 0;
            if (lf.epf_sigma_custom) {
                if (!is_modular) {
                    lf.epf_quant_mul = try fc.F16Coder.read(br);
                }
                lf.epf_pass0_sigma_scale = try fc.F16Coder.read(br);
                lf.epf_pass2_sigma_scale = try fc.F16Coder.read(br);
                lf.epf_border_sad_mul = try fc.F16Coder.read(br);
            }

            // Sigma for modular
            if (is_modular) {
                lf.epf_sigma_for_modular = try fc.F16Coder.read(br);
                if (lf.epf_sigma_for_modular < 1e-8) {
                    return error.GenericError;
                }
            }
        }

        // Extensions
        lf.extensions = fc.readExtensions(br);

        return lf;
    }

    pub fn padding(self: LoopFilter) usize {
        const padding_per_epf_iter = [4]usize{ 0, 2, 3, 6 };
        return padding_per_epf_iter[self.epf_iters] + if (self.gab) @as(usize, 1) else 0;
    }
};

// ── Tests ──

const testing = std.testing;

test "LoopFilter all default" {
    // AllDefault bit = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const lf = try LoopFilter.readFromBitStream(&br, false);
    try testing.expect(lf.gab);
    try testing.expectEqual(@as(u32, 2), lf.epf_iters);
}

test "LoopFilter non-default gab off" {
    // AllDefault=0, gab=0, epf_iters=00 (=0), extensions=00 (selector 0 -> 0)
    // bits: 0, 0, 00, 00
    // byte0: 0b00000000
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const lf = try LoopFilter.readFromBitStream(&br, false);
    try testing.expect(!lf.gab);
    try testing.expectEqual(@as(u32, 0), lf.epf_iters);
}

test "LoopFilter padding" {
    var lf = LoopFilter{};
    lf.gab = true;
    lf.epf_iters = 2;
    try testing.expectEqual(@as(usize, 4), lf.padding()); // 3 + 1
}
