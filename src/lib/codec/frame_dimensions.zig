// Frame dimensions: block/group constants and FrameDimensions struct.
// Transliterated from lib/jxl/frame_dimensions.h

const std = @import("std");
const common = @import("../base/common.zig");
const Rect = @import("../base/rect.zig").Rect;

pub const block_dim: usize = 8;
pub const dct_block_size: usize = block_dim * block_dim;
pub const group_dim: usize = 256;
pub const group_dim_in_blocks: usize = group_dim / block_dim;

comptime {
    std.debug.assert(group_dim % block_dim == 0);
}

/// Dimensions of a frame, in pixels, and other derived dimensions.
pub const FrameDimensions = struct {
    xsize: usize = 0,
    ysize: usize = 0,
    xsize_upsampled: usize = 0,
    ysize_upsampled: usize = 0,
    xsize_upsampled_padded: usize = 0,
    ysize_upsampled_padded: usize = 0,
    xsize_padded: usize = 0,
    ysize_padded: usize = 0,
    xsize_blocks: usize = 0,
    ysize_blocks: usize = 0,
    xsize_groups: usize = 0,
    ysize_groups: usize = 0,
    xsize_dc_groups: usize = 0,
    ysize_dc_groups: usize = 0,
    num_groups: usize = 0,
    num_dc_groups: usize = 0,
    grp_dim: usize = 0,
    dc_group_dim: usize = 0,

    pub fn set(
        self: *FrameDimensions,
        xsize_px: usize,
        ysize_px: usize,
        group_size_shift: usize,
        max_hshift: usize,
        max_vshift: usize,
        modular_mode: bool,
        upsampling: usize,
    ) void {
        self.grp_dim = (group_dim >> 1) << @intCast(group_size_shift);
        self.dc_group_dim = self.grp_dim * block_dim;
        self.xsize_upsampled = xsize_px;
        self.ysize_upsampled = ysize_px;
        self.xsize = common.divCeil(xsize_px, upsampling);
        self.ysize = common.divCeil(ysize_px, upsampling);
        self.xsize_blocks = common.divCeil(self.xsize, block_dim << @intCast(max_hshift)) << @intCast(max_hshift);
        self.ysize_blocks = common.divCeil(self.ysize, block_dim << @intCast(max_vshift)) << @intCast(max_vshift);
        self.xsize_padded = self.xsize_blocks * block_dim;
        self.ysize_padded = self.ysize_blocks * block_dim;
        if (modular_mode) {
            self.xsize_padded = self.xsize;
            self.ysize_padded = self.ysize;
        }
        self.xsize_upsampled_padded = self.xsize_padded * upsampling;
        self.ysize_upsampled_padded = self.ysize_padded * upsampling;
        self.xsize_groups = common.divCeil(self.xsize, self.grp_dim);
        self.ysize_groups = common.divCeil(self.ysize, self.grp_dim);
        self.xsize_dc_groups = common.divCeil(self.xsize_blocks, self.grp_dim);
        self.ysize_dc_groups = common.divCeil(self.ysize_blocks, self.grp_dim);
        self.num_groups = self.xsize_groups * self.ysize_groups;
        self.num_dc_groups = self.xsize_dc_groups * self.ysize_dc_groups;
    }

    pub fn groupRect(self: FrameDimensions, group_index: usize) Rect {
        const gx = group_index % self.xsize_groups;
        const gy = group_index / self.xsize_groups;
        return Rect.initClamped(
            gx * self.grp_dim,
            gy * self.grp_dim,
            self.grp_dim,
            self.grp_dim,
            self.xsize,
            self.ysize,
        );
    }

    pub fn blockGroupRect(self: FrameDimensions, group_index: usize) Rect {
        const gx = group_index % self.xsize_groups;
        const gy = group_index / self.xsize_groups;
        return Rect.initClamped(
            gx * (self.grp_dim >> 3),
            gy * (self.grp_dim >> 3),
            self.grp_dim >> 3,
            self.grp_dim >> 3,
            self.xsize_blocks,
            self.ysize_blocks,
        );
    }

    pub fn dcGroupRect(self: FrameDimensions, group_index: usize) Rect {
        const gx = group_index % self.xsize_dc_groups;
        const gy = group_index / self.xsize_dc_groups;
        return Rect.initClamped(
            gx * self.grp_dim,
            gy * self.grp_dim,
            self.grp_dim,
            self.grp_dim,
            self.xsize_blocks,
            self.ysize_blocks,
        );
    }
};

// ── Tests ──

const testing = std.testing;

test "FrameDimensions basic VarDCT" {
    var fd = FrameDimensions{};
    fd.set(100, 100, 1, 0, 0, false, 1);
    try testing.expectEqual(@as(usize, 100), fd.xsize);
    try testing.expectEqual(@as(usize, 100), fd.ysize);
    // 100 pixels -> ceil(100/8) = 13 blocks
    try testing.expectEqual(@as(usize, 13), fd.xsize_blocks);
    try testing.expectEqual(@as(usize, 13), fd.ysize_blocks);
    // 13 * 8 = 104 padded
    try testing.expectEqual(@as(usize, 104), fd.xsize_padded);
    try testing.expectEqual(@as(usize, 104), fd.ysize_padded);
    try testing.expect(fd.num_groups >= 1);
}

test "FrameDimensions modular mode no padding" {
    var fd = FrameDimensions{};
    fd.set(100, 100, 1, 0, 0, true, 1);
    // Modular mode: no padding
    try testing.expectEqual(@as(usize, 100), fd.xsize_padded);
    try testing.expectEqual(@as(usize, 100), fd.ysize_padded);
}

test "FrameDimensions with upsampling" {
    var fd = FrameDimensions{};
    fd.set(200, 200, 1, 0, 0, false, 2);
    // xsize = ceil(200/2) = 100
    try testing.expectEqual(@as(usize, 100), fd.xsize);
    try testing.expectEqual(@as(usize, 200), fd.xsize_upsampled);
}

test "FrameDimensions groupRect" {
    var fd = FrameDimensions{};
    fd.set(512, 512, 1, 0, 0, true, 1);
    const r = fd.groupRect(0);
    try testing.expectEqual(@as(usize, 0), r.x0());
    try testing.expectEqual(@as(usize, 0), r.y0());
    try testing.expect(r.xsize() > 0);
    try testing.expect(r.ysize() > 0);
}
