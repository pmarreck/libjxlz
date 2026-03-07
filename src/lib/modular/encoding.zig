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
    // Use @truncate to match C++ static_cast<pixel_type>(uint32_t(a)+uint32_t(b))
    // wrapping semantics — @intCast would panic on overflow.
    return @truncate(val *% @as(pixel_type_w, multiplier) +% offset);
}

inline fn absPixel(v: pixel_type_w) pixel_type {
    return @intCast(if (v >= 0) v else -v);
}

/// Precompute per-x extra reference properties from prior decoded channels.
/// Mirrors libjxl `PrecomputeReferences` and feeds properties >= kNumNonrefProperties.
fn precomputeReferences(
    channel: *const Channel,
    y: usize,
    image: *const Image,
    chan: usize,
    property_use: *const context_predict.PropertyUsePlan,
    references: *Channel,
) void {
    const reference_props = property_use.referenceProps();
    if (reference_props.len == 0) return;

    for (0..channel.w) |x| {
        const rp = references.row(x);
        for (reference_props) |property_index_u8| {
            rp[@as(usize, property_index_u8) - context_predict.kNumNonrefProperties] = 0;
        }
    }

    var offset: usize = 0;
    const num_extra_props = references.w;

    var j: isize = @intCast(chan);
    while (j > 0 and offset < num_extra_props) {
        j -= 1;
        const ref_chan = &image.channels.items[@intCast(j)];
        if (ref_chan.w != channel.w or ref_chan.h != channel.h) continue;
        if (ref_chan.hshift != channel.hshift or ref_chan.vshift != channel.vshift) continue;

        const base_property = context_predict.kNumNonrefProperties + offset;
        const use_abs_value = property_use.uses(base_property);
        const use_value = property_use.uses(base_property + 1);
        const use_abs_diff = property_use.uses(base_property + 2);
        const use_diff = property_use.uses(base_property + 3);
        if (!use_abs_value and !use_value and !use_abs_diff and !use_diff) {
            offset += context_predict.kExtraPropsPerChannel;
            continue;
        }

        const rpp = ref_chan.rowConst(y);
        const rpprev = ref_chan.rowConst(if (y > 0) y - 1 else 0);
        for (0..channel.w) |x| {
            const rp = references.row(x);
            const v: pixel_type_w = rpp[x];
            if (use_abs_value) rp[offset + 0] = absPixel(v);
            if (use_value) rp[offset + 1] = @intCast(v);

            if (use_abs_diff or use_diff) {
                const vleft: pixel_type_w = if (x > 0) rpp[x - 1] else 0;
                const vtop: pixel_type_w = if (y > 0) rpprev[x] else vleft;
                const vtopleft: pixel_type_w = if (x > 0 and y > 0) rpprev[x - 1] else vleft;
                const vpredicted: pixel_type_w = context_predict.clampedGradient(
                    @as(pixel_type, @intCast(vleft)),
                    @as(pixel_type, @intCast(vtop)),
                    @as(pixel_type, @intCast(vtopleft)),
                );
                const vdiff: pixel_type_w = v - vpredicted;
                if (use_abs_diff) rp[offset + 2] = absPixel(vdiff);
                if (use_diff) rp[offset + 3] = @intCast(vdiff);
            }
        }

        offset += context_predict.kExtraPropsPerChannel;
    }
}

pub const ReaderStrategy = enum {
    reference,
    specialized,
};

const default_reader_strategy: ReaderStrategy = .specialized;

inline fn readHybridUintClusteredReference(reader: *ANSSymbolReader, ctx: usize, br: *BitReader) usize {
    return reader.readHybridUintClustered(ctx, br, true);
}

inline fn readHybridUintClusteredNoLZ77ANS(reader: *ANSSymbolReader, ctx: usize, br: *BitReader) usize {
    return reader.readHybridUintClusteredMaybeInlined(false, false, ctx, br);
}

inline fn readHybridUintClusteredLZ77ANS(reader: *ANSSymbolReader, ctx: usize, br: *BitReader) usize {
    return reader.readHybridUintClusteredMaybeInlined(true, false, ctx, br);
}

inline fn readHybridUintClusteredNoLZ77Huff(reader: *ANSSymbolReader, ctx: usize, br: *BitReader) usize {
    return reader.readHybridUintClusteredMaybeInlined(false, true, ctx, br);
}

inline fn readHybridUintClusteredLZ77Huff(reader: *ANSSymbolReader, ctx: usize, br: *BitReader) usize {
    return reader.readHybridUintClusteredMaybeInlined(true, true, ctx, br);
}

// ── Decode a single modular channel ──

fn decodeModularChannelImpl(
    comptime read_next: anytype,
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
    var property_use = context_predict.PropertyUsePlan{};
    var flat_tree = context_predict.filterTree(
        allocator,
        global_tree,
        static_props,
        &num_props,
        &use_wp,
        &wp_only,
        &gradient_only,
        &property_use,
    ) catch return error.GenericError;
    defer flat_tree.deinit(allocator);

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
                        const v: u32 = @intCast(read_next(reader, ctx_id, br));
                        r[x] = pack_signed.unpackSigned(v);
                    }
                }
            } else {
                for (0..channel.h) |y| {
                    const r = channel.row(y);
                    for (0..channel.w) |x| {
                        const v: u32 = @intCast(read_next(reader, ctx_id, br));
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
                    const v: u32 = @intCast(read_next(reader, ctx_id, br));
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

    const use_prop_y = property_use.uses(2);
    const use_prop_x = property_use.uses(3);
    const use_prop_abs_top = property_use.uses(4);
    const use_prop_abs_left = property_use.uses(5);
    const use_prop_top = property_use.uses(6);
    const use_prop_left = property_use.uses(7);
    const use_prop_left_minus_gradient = property_use.uses(8);
    const use_prop_gradient = property_use.uses(9);
    const use_prop_left_minus_topleft = property_use.uses(10);
    const use_prop_topleft_minus_top = property_use.uses(11);
    const use_prop_top_minus_topright = property_use.uses(12);
    const use_prop_top_minus_toptop = property_use.uses(13);
    const use_prop_left_minus_leftleft = property_use.uses(14);
    const use_prop_wp = property_use.uses(context_predict.kWPProp);
    const use_local_gradient_history = property_use.needsLocalGradientHistory();
    const reference_props = property_use.referenceProps();

    const num_extra_props = if (reference_props.len > 0 and num_props > context_predict.kNumNonrefProperties)
        num_props - context_predict.kNumNonrefProperties
    else
        0;
    var references: ?Channel = null;
    if (num_extra_props > 0) {
        references = try Channel.create(allocator, num_extra_props, channel.w, 0, 0);
    }
    defer {
        if (references) |*r| r.deinit();
    }

    var wp_state: ?weighted.State = null;
    if (use_wp) {
        wp_state = try weighted.State.init(allocator, wp_header.*, channel.w, channel.h);
    }
    defer {
        if (wp_state) |*ws| ws.deinit();
    }

    for (0..channel.h) |y| {
        const r = channel.row(y);
        if (references) |*refs| {
            precomputeReferences(channel, y, image, chan, &property_use, refs);
        }

        if (use_prop_y) properties[2] = @intCast(y);
        var local_gradient: pixel_type_w = 0;

        for (0..channel.w) |x| {
            const left: pixel_type_w = if (x > 0) r[x - 1] else if (y > 0) channel.row(y - 1)[x] else 0;
            const top: pixel_type_w = if (y > 0) channel.row(y - 1)[x] else left;
            const topleft: pixel_type_w = if (x > 0 and y > 0) channel.row(y - 1)[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < channel.w and y > 0) channel.row(y - 1)[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) r[x - 2] else left;
            const toptop: pixel_type_w = if (y > 1) channel.row(y - 2)[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < channel.w and y > 0) channel.row(y - 1)[x + 2] else topright;

            if (use_prop_x) properties[3] = @intCast(x);
            if (use_prop_abs_top) properties[4] = absPixel(top);
            if (use_prop_abs_left) properties[5] = absPixel(left);
            if (use_prop_top) properties[6] = @intCast(top);
            if (use_prop_left) properties[7] = @intCast(left);
            if (use_local_gradient_history) {
                const prev_gradient = local_gradient;
                const next_gradient = left + top - topleft;
                if (use_prop_left_minus_gradient) properties[8] = @intCast(left - prev_gradient);
                local_gradient = next_gradient;
                if (use_prop_gradient) properties[9] = @intCast(next_gradient);
            }
            if (use_prop_left_minus_topleft) properties[10] = @intCast(left - topleft);
            if (use_prop_topleft_minus_top) properties[11] = @intCast(topleft - top);
            if (use_prop_top_minus_topright) properties[12] = @intCast(top - topright);
            if (use_prop_top_minus_toptop) properties[13] = @intCast(top - toptop);
            if (use_prop_left_minus_leftleft) properties[14] = @intCast(left - leftleft);

            var wp_pred: pixel_type_w = 0;
            if (wp_state) |*ws| {
                wp_pred = ws.predict(x, y, channel.w, top, left, topright, topleft, toptop, null, 0);
                if (use_prop_wp) {
                    properties[context_predict.kWPProp] = ws.getWPProp();
                }
            }

            if (references) |*refs| {
                const ref_props = refs.rowConst(x);
                for (reference_props) |property_index_u8| {
                    const property_index: usize = property_index_u8;
                    properties[property_index] = ref_props[property_index - context_predict.kNumNonrefProperties];
                }
            }

            // Tree lookup
            const lr = tree_lookup.lookup(properties);
            const pred = context_predict.predictOne(
                lr.predictor,
                left,
                top,
                toptop,
                topleft,
                topright,
                leftleft,
                toprightright,
                wp_pred,
            );

            const v: u32 = @intCast(read_next(reader, lr.context, br));
            r[x] = makePixel(v, @intCast(lr.multiplier), pred + lr.offset);

            if (wp_state) |*ws| {
                ws.updateErrors(r[x], x, y, channel.w);
            }
        }
    }
}

fn decodeModularChannelReference(
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
    return decodeModularChannelImpl(
        readHybridUintClusteredReference,
        br,
        reader,
        context_map,
        global_tree,
        wp_header,
        chan,
        group_id,
        image,
        allocator,
    );
}

fn decodeModularChannelWithReaderStrategy(
    comptime reader_strategy: ReaderStrategy,
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
    if (reader_strategy == .reference) {
        return decodeModularChannelReference(
            br,
            reader,
            context_map,
            global_tree,
            wp_header,
            chan,
            group_id,
            image,
            allocator,
        );
    }
    if (reader.use_prefix_code) {
        if (reader.usesLZ77()) {
            return decodeModularChannelImpl(
                readHybridUintClusteredLZ77Huff,
                br,
                reader,
                context_map,
                global_tree,
                wp_header,
                chan,
                group_id,
                image,
                allocator,
            );
        }
        return decodeModularChannelImpl(
            readHybridUintClusteredNoLZ77Huff,
            br,
            reader,
            context_map,
            global_tree,
            wp_header,
            chan,
            group_id,
            image,
            allocator,
        );
    }
    if (reader.usesLZ77()) {
        return decodeModularChannelImpl(
            readHybridUintClusteredLZ77ANS,
            br,
            reader,
            context_map,
            global_tree,
            wp_header,
            chan,
            group_id,
            image,
            allocator,
        );
    }
    return decodeModularChannelImpl(
        readHybridUintClusteredNoLZ77ANS,
        br,
        reader,
        context_map,
        global_tree,
        wp_header,
        chan,
        group_id,
        image,
        allocator,
    );
}

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
    return decodeModularChannelWithReaderStrategy(
        default_reader_strategy,
        br,
        reader,
        context_map,
        global_tree,
        wp_header,
        chan,
        group_id,
        image,
        allocator,
    );
}

// ── ModularDecode ──

pub fn modularDecodeWithReaderStrategy(
    comptime reader_strategy: ReaderStrategy,
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
        try image.transforms.append(image.allocator, t);
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
    var local_tree: dec_ma.Tree = .{};
    defer local_tree.deinit(allocator);
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

        try decodeModularChannelWithReaderStrategy(
            reader_strategy,
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
    return modularDecodeWithReaderStrategy(
        default_reader_strategy,
        br,
        image,
        header,
        group_id,
        opts,
        global_tree,
        global_code,
        global_ctx_map,
        allocator,
    );
}

/// High-level modular decompress with optional transform undo.
pub fn modularGenericDecompressWithReaderStrategy(
    comptime reader_strategy: ReaderStrategy,
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

    try modularDecodeWithReaderStrategy(reader_strategy, br, image, &header, group_id, opts, tree, code, ctx_map, allocator);

    if (undo_transforms) {
        try transform_mod.undoTransforms(image, &header.wp_header);
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
    return modularGenericDecompressWithReaderStrategy(
        default_reader_strategy,
        br,
        image,
        group_id,
        opts,
        undo_transforms,
        tree,
        code,
        ctx_map,
        allocator,
    );
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
