// Modular image types: Channel and Image.
// Transliterated from lib/jxl/modular/modular_image.h/.cc

const std = @import("std");
const options = @import("options.zig");
const pixel_type = options.pixel_type;
const transform_mod = @import("transform.zig");
const Transform = transform_mod.Transform;

pub const Channel = struct {
    data: []pixel_type = &.{},
    w: usize = 0,
    h: usize = 0,
    hshift: i32 = 0,
    vshift: i32 = 0,
    component: i32 = -1,
    row_stride: usize = 0, // pixels per row (may include padding)
    allocator: ?std.mem.Allocator = null,

    pub fn create(allocator: std.mem.Allocator, iw: usize, ih: usize, hsh: i32, vsh: i32) !Channel {
        if (iw == 0 or ih == 0) {
            return Channel{ .w = iw, .h = ih, .hshift = hsh, .vshift = vsh, .allocator = allocator };
        }
        const data = try allocator.alloc(pixel_type, iw * ih);
        @memset(data, 0);
        return Channel{
            .data = data,
            .w = iw,
            .h = ih,
            .hshift = hsh,
            .vshift = vsh,
            .row_stride = iw,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Channel) void {
        if (self.allocator) |alloc| {
            if (self.data.len > 0) {
                alloc.free(self.data);
                self.data = &.{};
            }
        }
    }

    pub fn row(self: *Channel, y: usize) []pixel_type {
        const start = y * self.row_stride;
        return self.data[start .. start + self.w];
    }

    pub fn rowConst(self: *const Channel, y: usize) []const pixel_type {
        const start = y * self.row_stride;
        return self.data[start .. start + self.w];
    }

    pub fn zeroFill(self: *Channel) void {
        @memset(self.data, 0);
    }
};

pub const Image = struct {
    channels: std.ArrayList(Channel),
    transforms: std.ArrayList(Transform),
    w: usize = 0,
    h: usize = 0,
    bitdepth: i32 = 8,
    nb_meta_channels: usize = 0,
    err: bool = false,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, iw: usize, ih: usize, bitdepth: i32, nb_chans: usize) !Image {
        var img = Image{
            .channels = std.ArrayList(Channel).init(allocator),
            .transforms = std.ArrayList(Transform).init(allocator),
            .w = iw,
            .h = ih,
            .bitdepth = bitdepth,
            .allocator = allocator,
        };
        for (0..nb_chans) |_| {
            const ch = try Channel.create(allocator, iw, ih, 0, 0);
            try img.channels.append(ch);
        }
        return img;
    }

    pub fn deinit(self: *Image) void {
        for (self.channels.items) |*ch| {
            ch.deinit();
        }
        self.channels.deinit();
        for (self.transforms.items) |*t| {
            t.deinit();
        }
        self.transforms.deinit();
    }

    pub fn empty(self: *const Image) bool {
        for (self.channels.items) |ch| {
            if (ch.w != 0 and ch.h != 0) return false;
        }
        return true;
    }
};

// ── Tests ──

const testing = std.testing;

test "Channel create and access" {
    const allocator = testing.allocator;
    var ch = try Channel.create(allocator, 4, 3, 0, 0);
    defer ch.deinit();
    try testing.expectEqual(@as(usize, 4), ch.w);
    try testing.expectEqual(@as(usize, 3), ch.h);

    var r = ch.row(1);
    r[0] = 42;
    try testing.expectEqual(@as(pixel_type, 42), ch.rowConst(1)[0]);
}

test "Image create and deinit" {
    const allocator = testing.allocator;
    var img = try Image.create(allocator, 8, 8, 8, 3);
    defer img.deinit();
    try testing.expectEqual(@as(usize, 3), img.channels.items.len);
    try testing.expectEqual(@as(usize, 8), img.channels.items[0].w);
    try testing.expect(!img.empty());
}

test "Channel zero size" {
    const allocator = testing.allocator;
    var ch = try Channel.create(allocator, 0, 0, 0, 0);
    defer ch.deinit();
    try testing.expectEqual(@as(usize, 0), ch.w);
    try testing.expectEqual(@as(usize, 0), ch.data.len);
}
