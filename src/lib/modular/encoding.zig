// Modular encoding/decoding: GroupHeader, ModularDecode, ModularGenericDecompress.
// Transliterated from lib/jxl/modular/encoding/encoding.h/.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("../codec/field_coders.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const ANSCode = dec_ans.ANSCode;
const ANSSymbolReader = dec_ans.ANSSymbolReader;
const pack_signed = @import("../base/pack_signed.zig");
const options = @import("options.zig");
const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;
const Predictor = options.Predictor;
const ModularOptions = options.ModularOptions;
const weighted = @import("weighted.zig");
const dec_ma = @import("dec_ma.zig");
const context_predict = @import("context_predict.zig");
const transform_mod = @import("transform.zig");
const Transform = transform_mod.Transform;
const modular_image = @import("modular_image.zig");
const Channel = modular_image.Channel;
const Image = modular_image.Image;

// ── GroupHeader ──

pub const GroupHeader = struct {
    use_global_tree: bool = false,
    wp_header: weighted.Header = .{},
    transforms: []Transform = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn readFromBitStream(br: *BitReader, allocator: std.mem.Allocator) JxlError!GroupHeader {
        var h = GroupHeader{};
        h.allocator = allocator;

        h.use_global_tree = br.readBits(1) != 0;
        h.wp_header = weighted.Header.readFromBitStream(br);

        // num_transforms: U32(Val(0), Val(1), BitsOffset(4,2), BitsOffset(8,18))
        const nt_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.bitsOffset(4, 2), fc.bitsOffset(8, 18));
        const num_transforms = fc.U32Coder.read(nt_enc, br);

        if (num_transforms > 0) {
            const transforms = try allocator.alloc(Transform, num_transforms);
            for (transforms) |*t| {
                t.* = try Transform.readFromBitStream(br, allocator);
            }
            h.transforms = transforms;
        }

        return h;
    }

    pub fn deinit(self: *GroupHeader) void {
        if (self.allocator) |alloc| {
            for (self.transforms) |*t| {
                var tm = t.*;
                tm.deinit();
            }
            if (self.transforms.len > 0) {
                alloc.free(self.transforms);
                self.transforms = &.{};
            }
        }
    }
};

// ── Make pixel from ANS symbol ──

inline fn makePixel(v: u32, multiplier: pixel_type, offset: pixel_type_w) pixel_type {
    const val: pixel_type_w = pack_signed.unpackSigned(v);
    return @intCast(val * @as(pixel_type_w, multiplier) + offset);
}

// ── Decode a single modular channel ──

fn decodeModularChannel(
    br: *BitReader,
    reader: *ANSSymbolReader,
    context_map: []const u8,
    global_tree: []const dec_ma.PropertyDecisionNode,
    wp_header: *const weighted.Header,
    chan: usize,
    group_id: usize,
    image: *Image,
    allocator: std.mem.Allocator,
) JxlError!void {
    var channel = &image.channels.items[chan];
    if (channel.w == 0 or channel.h == 0) return;

    const static_props = [_]pixel_type{ @intCast(chan), @intCast(group_id) };

    // Filter tree for this channel/group
    var num_props: usize = 0;
    var use_wp: bool = false;
    var wp_only: bool = false;
    var gradient_only: bool = false;
    var flat_tree = context_predict.filterTree(
        allocator,
        global_tree,
        static_props,
        &num_props,
        &use_wp,
        &wp_only,
        &gradient_only,
    ) catch return error.GenericError;
    defer flat_tree.deinit();

    // Map leaf childIDs through context_map for direct clustered reads
    for (flat_tree.items) |*node| {
        if (node.property0 < 0) {
            node.childID = context_map[node.childID];
        }
    }

    if (flat_tree.items.len == 1) {
        // Single-node tree: no meta-adaptation needed
        const predictor = flat_tree.items[0].predictor;
        const offset: pixel_type_w = flat_tree.items[0].predictor_offset;
        const multiplier: pixel_type = @intCast(flat_tree.items[0].multiplier);
        const ctx_id: usize = flat_tree.items[0].childID;

        if (predictor == .zero) {
            // Fastest track: zero predictor, just read values
            if (multiplier == 1 and offset == 0) {
                for (0..channel.h) |y| {
                    const r = channel.row(y);
                    for (0..channel.w) |x| {
                        const v: u32 = @intCast(reader.readHybridUintClustered(ctx_id, br, true));
                        r[x] = pack_signed.unpackSigned(v);
                    }
                }
            } else {
                for (0..channel.h) |y| {
                    const r = channel.row(y);
                    for (0..channel.w) |x| {
                        const v: u32 = @intCast(reader.readHybridUintClustered(ctx_id, br, true));
                        r[x] = makePixel(v, multiplier, offset);
                    }
                }
            }
            return;
        }

        if (predictor == .gradient and offset == 0 and multiplier == 1) {
            // Gradient very fast track
            for (0..channel.h) |y| {
                const r = channel.row(y);
                for (0..channel.w) |x| {
                    const left: pixel_type_w = if (x > 0) r[x - 1] else if (y > 0) channel.row(y - 1)[x] else 0;
                    const top: pixel_type_w = if (y > 0) channel.row(y - 1)[x] else left;
                    const topleft: pixel_type_w = if (x > 0 and y > 0) channel.row(y - 1)[x - 1] else left;
                    const guess: pixel_type = context_predict.clampedGradient(@as(pixel_type, @intCast(left)), @as(pixel_type, @intCast(top)), @as(pixel_type, @intCast(topleft)));
                    const v: u32 = @intCast(reader.readHybridUintClustered(ctx_id, br, true));
                    r[x] = makePixel(v, 1, guess);
                }
            }
            return;
        }
    }

    // General case: full tree traversal with properties
    const tree_lookup = context_predict.MATreeLookup.init(flat_tree.items);
    var properties = try allocator.alloc(pixel_type, num_props);
    defer allocator.free(properties);
    @memset(properties, 0);

    var wp_state: ?weighted.State = null;
    if (use_wp) {
        wp_state = try weighted.State.init(allocator, wp_header.*, channel.w, channel.h);
    }
    defer {
        if (wp_state) |*ws| ws.deinit();
    }

    for (0..channel.h) |y| {
        const r = channel.row(y);

        // Init static properties for this row
        if (properties.len > 0) properties[0] = @intCast(chan);
        if (properties.len > 1) properties[1] = @intCast(group_id);
        if (properties.len > 2) properties[2] = @intCast(y);
        if (properties.len > 9) properties[9] = 0; // local gradient

        for (0..channel.w) |x| {
            const left: pixel_type_w = if (x > 0) r[x - 1] else if (y > 0) channel.row(y - 1)[x] else 0;
            const top: pixel_type_w = if (y > 0) channel.row(y - 1)[x] else left;
            const topleft: pixel_type_w = if (x > 0 and y > 0) channel.row(y - 1)[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < channel.w and y > 0) channel.row(y - 1)[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) r[x - 2] else left;
            const toptop: pixel_type_w = if (y > 1) channel.row(y - 2)[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < channel.w and y > 0) channel.row(y - 1)[x + 2] else topright;

            // Compute properties
            if (properties.len > 3) properties[3] = @intCast(x);
            if (properties.len > 4) properties[4] = @intCast(if (top >= 0) top else -top);
            if (properties.len > 5) properties[5] = @intCast(if (left >= 0) left else -left);
            if (properties.len > 6) properties[6] = @intCast(top);
            if (properties.len > 7) properties[7] = @intCast(left);
            if (properties.len > 8) {
                const prev_gradient = properties[9];
                properties[8] = @intCast(left - @as(pixel_type_w, prev_gradient));
                properties[9] = @intCast(left + top - topleft); // local gradient for next
            }
            if (properties.len > 10) properties[10] = @intCast(left - topleft);
            if (properties.len > 11) properties[11] = @intCast(topleft - top);
            if (properties.len > 12) properties[12] = @intCast(top - topright);
            if (properties.len > 13) properties[13] = @intCast(top - toptop);
            if (properties.len > 14) properties[14] = @intCast(left - leftleft);

            var wp_pred: pixel_type_w = 0;
            if (wp_state) |*ws| {
                wp_pred = ws.predict(x, y, channel.w, top, left, topright, topleft, toptop, null, 0);
            }

            // Tree lookup
            const lr = tree_lookup.lookup(properties);
            const pred = context_predict.predictOne(
                lr.predictor,
                left, top, toptop, topleft, topright,
                leftleft, toprightright, wp_pred,
            );

            const v: u32 = @intCast(reader.readHybridUintClustered(lr.context, br, true));
            r[x] = makePixel(v, @intCast(lr.multiplier), pred + lr.offset);

            if (wp_state) |*ws| {
                ws.updateErrors(r[x], x, y, channel.w);
            }
        }
    }
}

// ── ModularDecode ──

pub fn modularDecode(
    br: *BitReader,
    image: *Image,
    header: *GroupHeader,
    group_id: usize,
    opts: *const ModularOptions,
    global_tree: ?[]const dec_ma.PropertyDecisionNode,
    global_code: ?*const ANSCode,
    global_ctx_map: ?[]const u8,
    allocator: std.mem.Allocator,
) JxlError!void {
    if (image.channels.items.len == 0) return;

    // Read group header (transforms, WP header, use_global_tree)
    header.* = try GroupHeader.readFromBitStream(br, allocator);

    // Apply forward transform metadata (modifies channel structure)
    for (header.transforms) |*t| {
        var tm = @as(Transform, t.*);
        try transform_mod.metaApply(image, &tm, allocator);
        t.* = tm;
    }

    // Move transforms to image for later undo (header gives up ownership)
    for (header.transforms) |t| {
        try image.transforms.append(t);
    }
    // Clear header's transform slice so it doesn't double-free squeeze params
    if (header.allocator) |alloc| {
        if (header.transforms.len > 0) {
            alloc.free(header.transforms);
        }
    }
    header.transforms = &.{};

    const nb_channels = image.channels.items.len;

    // Compute distance_multiplier and num_chans
    var num_chans: usize = 0;
    var distance_multiplier: usize = 0;
    for (0..nb_channels) |i| {
        const ch = &image.channels.items[i];
        if (i >= image.nb_meta_channels and
            (ch.w > opts.max_chan_size or ch.h > opts.max_chan_size))
        {
            break;
        }
        if (ch.w == 0 or ch.h == 0) continue;
        if (ch.w > distance_multiplier) distance_multiplier = ch.w;
        num_chans += 1;
    }
    if (num_chans == 0) return;

    // Read or use global tree
    var local_tree = dec_ma.Tree.init(allocator);
    defer local_tree.deinit();
    var local_code = ANSCode.init(allocator);
    defer local_code.deinit();
    var local_ctx_map: []u8 = &.{};
    defer if (local_ctx_map.len > 0) allocator.free(local_ctx_map);

    var tree: []const dec_ma.PropertyDecisionNode = undefined;
    var code: *const ANSCode = undefined;
    var ctx_map: []const u8 = undefined;

    if (!header.use_global_tree) {
        // Read local tree
        var max_tree_size: u64 = 1024;
        for (0..nb_channels) |i| {
            const ch = &image.channels.items[i];
            if (i >= image.nb_meta_channels and
                (ch.w > opts.max_chan_size or ch.h > opts.max_chan_size))
            {
                break;
            }
            max_tree_size += @as(u64, ch.w) * @as(u64, ch.h);
        }
        max_tree_size = @min(1 << 20, max_tree_size);

        try dec_ma.decodeTree(allocator, br, &local_tree, @intCast(max_tree_size));

        // Read histograms for channel data
        local_ctx_map = try dec_ans.decodeHistograms(
            allocator,
            br,
            (local_tree.items.len + 1) / 2,
            &local_code,
        );

        tree = local_tree.items;
        code = &local_code;
        ctx_map = local_ctx_map;
    } else {
        if (global_tree == null or global_code == null or global_ctx_map == null) {
            return error.GenericError;
        }
        tree = global_tree.?;
        code = global_code.?;
        ctx_map = global_ctx_map.?;
    }

    if (tree.len == 0) return error.GenericError;

    // Create ANS reader
    var reader = try ANSSymbolReader.create(code, br, distance_multiplier, allocator);
    defer reader.deinit();

    // Decode channels
    for (0..nb_channels) |c| {
        const ch = &image.channels.items[c];
        if (c >= image.nb_meta_channels and
            (ch.w > opts.max_chan_size or ch.h > opts.max_chan_size))
        {
            break;
        }
        if (ch.w == 0 or ch.h == 0) continue;

        try decodeModularChannel(
            br,
            &reader,
            ctx_map,
            tree,
            &header.wp_header,
            c,
            group_id,
            image,
            allocator,
        );
    }

    if (!reader.checkANSFinalState()) {
        return error.GenericError;
    }
}

/// High-level modular decompress with optional transform undo.
pub fn modularGenericDecompress(
    br: *BitReader,
    image: *Image,
    group_id: usize,
    opts: *const ModularOptions,
    undo_transforms: bool,
    tree: ?[]const dec_ma.PropertyDecisionNode,
    code: ?*const ANSCode,
    ctx_map: ?[]const u8,
    allocator: std.mem.Allocator,
) JxlError!void {
    var header = GroupHeader{};
    defer header.deinit();

    try modularDecode(br, image, &header, group_id, opts, tree, code, ctx_map, allocator);

    if (undo_transforms) {
        try transform_mod.undoTransforms(image, &header.wp_header);
    }
}

// ── Tests ──

const testing = std.testing;

test "GroupHeader defaults" {
    const h = GroupHeader{};
    try testing.expect(!h.use_global_tree);
    try testing.expectEqual(@as(usize, 0), h.transforms.len);
}

test "makePixel basic" {
    // v=0 (unpacks to 0), multiplier=1, offset=0
    try testing.expectEqual(@as(pixel_type, 0), makePixel(0, 1, 0));
    // v=2 (unpacks to 1 via zigzag), multiplier=1, offset=10
    try testing.expectEqual(@as(pixel_type, 11), makePixel(2, 1, 10));
    // v=1 (unpacks to -1), multiplier=1, offset=5
    try testing.expectEqual(@as(pixel_type, 4), makePixel(1, 1, 5));
}
