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
const PropertyVal = options.PropertyVal;
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
            errdefer allocator.free(transforms);
            var initialized: usize = 0;
            errdefer for (transforms[0..initialized]) |*t| t.deinit();
            for (transforms) |*t| {
                t.* = try Transform.readFromBitStream(br, allocator);
                initialized += 1;
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

const kMaskProp9: u8 = 1 << 0;
const kMaskProp10: u8 = 1 << 1;
const kMaskProp11: u8 = 1 << 2;
const kMaskProp12: u8 = 1 << 3;
const kMaskProp13: u8 = 1 << 4;
const kMaskProp15: u8 = 1 << 5;

inline fn propertyMaskBit(property_index: usize) ?u8 {
    return switch (property_index) {
        9 => kMaskProp9,
        10 => kMaskProp10,
        11 => kMaskProp11,
        12 => kMaskProp12,
        13 => kMaskProp13,
        context_predict.kWPProp => kMaskProp15,
        else => null,
    };
}

/// Recognizes the dominant no-reference property sets after MA-tree filtering so
/// decode can switch to compile-time-specialized inner loops instead of runtime
/// property guards for each pixel.
fn specializedPropertyMask(property_use: *const context_predict.PropertyUsePlan) ?u8 {
    if (property_use.usesReferenceProps()) return null;

    var mask: u8 = 0;
    for (options.kNumStaticProperties..context_predict.kNumNonrefProperties) |property_index| {
        if (!property_use.uses(property_index)) continue;
        mask |= propertyMaskBit(property_index) orelse return null;
    }
    return mask;
}

inline fn compactPropertySlot(comptime property_mask: u8, comptime property_bit: u8) usize {
    if ((property_mask & property_bit) == 0) return 0;
    return 1 + @as(usize, @popCount(@as(u8, property_mask & (property_bit - 1))));
}

inline fn remapPropertyIndex(comptime property_mask: u8, property_index: i32) i16 {
    return switch (property_index) {
        0 => 0,
        9 => @intCast(compactPropertySlot(property_mask, kMaskProp9)),
        10 => @intCast(compactPropertySlot(property_mask, kMaskProp10)),
        11 => @intCast(compactPropertySlot(property_mask, kMaskProp11)),
        12 => @intCast(compactPropertySlot(property_mask, kMaskProp12)),
        13 => @intCast(compactPropertySlot(property_mask, kMaskProp13)),
        context_predict.kWPProp => @intCast(compactPropertySlot(property_mask, kMaskProp15)),
        else => unreachable,
    };
}

const kCompactNoRefLeaf = std.math.maxInt(u8);
const kInlineCompactNoRefTreeNodes = 128;

const CompactNoRefNode = struct {
    property0: u8 = kCompactNoRefLeaf,
    property1: u8 = 0,
    property2: u8 = 0,
    predictor_tag: u8 = 0,
    child_id: u16 = 0,
    _pad: u16 = 0,
    splitval0: PropertyVal = 0,
    splitval1: PropertyVal = 0,
    splitval2: PropertyVal = 0,
    multiplier: i32 = 1,
    predictor_offset: i64 = 0,
};

/// Compacts a filtered no-reference tree into the local property-id space used by
/// the hot mask-specialized loops, keeping slot zero as the always-zero sentinel.
fn remapNoRefMaskTree(comptime property_mask: u8, flat_tree: []context_predict.FlatDecisionNode) void {
    for (flat_tree) |*node| {
        if (node.property0 < 0) continue;
        node.property0 = remapPropertyIndex(property_mask, node.property0);
        inline for (0..2) |i| {
            node.properties[i] = remapPropertyIndex(property_mask, node.properties[i]);
        }
    }
}

/// Re-encodes remapped no-reference trees into a denser node layout so the hot
/// specialized lookup loop touches less metadata per pixel.
fn compactNoRefTree(
    flat_tree: []const context_predict.FlatDecisionNode,
    storage: []CompactNoRefNode,
) ?[]const CompactNoRefNode {
    if (flat_tree.len > storage.len or flat_tree.len > std.math.maxInt(u16)) return null;

    for (flat_tree, 0..) |node, i| {
        var compact = CompactNoRefNode{};
        if (node.property0 < 0) {
            if (node.childID > std.math.maxInt(u16)) return null;
            compact.predictor_tag = @intCast(@intFromEnum(node.predictor));
            compact.child_id = @intCast(node.childID);
            compact.multiplier = node.multiplier;
            compact.predictor_offset = node.predictor_offset;
        } else {
            if (node.property0 < 0 or node.property0 > std.math.maxInt(u8)) return null;
            if (node.properties[0] < 0 or node.properties[0] > std.math.maxInt(u8)) return null;
            if (node.properties[1] < 0 or node.properties[1] > std.math.maxInt(u8)) return null;
            if (node.childID > std.math.maxInt(u16)) return null;

            compact.property0 = @intCast(node.property0);
            compact.property1 = @intCast(node.properties[0]);
            compact.property2 = @intCast(node.properties[1]);
            compact.child_id = @intCast(node.childID);
            compact.splitval0 = node.splitval0;
            compact.splitval1 = node.splitvals[0];
            compact.splitval2 = node.splitvals[1];
        }
        storage[i] = compact;
    }
    return storage[0..flat_tree.len];
}

inline fn compactNoRefLookup(
    nodes: []const CompactNoRefNode,
    properties: []const pixel_type,
) context_predict.MATreeLookup.LookupResult {
    var pos: usize = 0;
    while (true) {
        const node = nodes[pos];
        if (node.property0 == kCompactNoRefLeaf) {
            return .{
                .context = node.child_id,
                .predictor = @enumFromInt(node.predictor_tag),
                .offset = node.predictor_offset,
                .multiplier = node.multiplier,
            };
        }
        const p0 = properties[@as(usize, node.property0)] <= node.splitval0;
        const off0: usize = if (properties[@as(usize, node.property1)] <= node.splitval1) 1 else 0;
        const off1: usize = 2 | (if (properties[@as(usize, node.property2)] <= node.splitval2) @as(usize, 1) else 0);
        pos = @as(usize, node.child_id) + (if (p0) off1 else off0);
    }
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

/// Handles the common filtered-tree cases that use only non-reference properties
/// from a small fixed mask, letting Zig constant-fold the property writes in the
/// inner pixel loop while keeping the generic tree lookup and predictor logic.
fn decodeModularChannelNoRefsMaskLoop(
    comptime read_next: anytype,
    comptime property_mask: u8,
    comptime use_compact_tree: bool,
    lookup_ctx: anytype,
    br: *BitReader,
    reader: *ANSSymbolReader,
    wp_header: *const weighted.Header,
    channel: *Channel,
    allocator: std.mem.Allocator,
    use_wp: bool,
) JxlError!void {
    const use_prop_9 = (property_mask & kMaskProp9) != 0;
    const use_prop_10 = (property_mask & kMaskProp10) != 0;
    const use_prop_11 = (property_mask & kMaskProp11) != 0;
    const use_prop_12 = (property_mask & kMaskProp12) != 0;
    const use_prop_13 = (property_mask & kMaskProp13) != 0;
    const use_prop_wp = (property_mask & kMaskProp15) != 0;
    const slot_prop9 = compactPropertySlot(property_mask, kMaskProp9);
    const slot_prop10 = compactPropertySlot(property_mask, kMaskProp10);
    const slot_prop11 = compactPropertySlot(property_mask, kMaskProp11);
    const slot_prop12 = compactPropertySlot(property_mask, kMaskProp12);
    const slot_prop13 = compactPropertySlot(property_mask, kMaskProp13);
    const slot_prop15 = compactPropertySlot(property_mask, kMaskProp15);
    const compact_prop_count: usize = 1 + @as(usize, @popCount(property_mask));
    var properties = [_]pixel_type{0} ** compact_prop_count;

    var wp_state: ?weighted.State = null;
    if (use_wp) {
        wp_state = try weighted.State.init(allocator, wp_header.*, channel.w, channel.h);
    }
    defer {
        if (wp_state) |*ws| ws.deinit();
    }

    for (0..channel.h) |y| {
        const r = channel.row(y);
        const has_top = y > 0;
        const has_toptop = y > 1;
        const top_row = if (has_top) channel.rowConst(y - 1) else &[_]pixel_type{};
        const top2_row = if (has_toptop) channel.rowConst(y - 2) else &[_]pixel_type{};
        var local_gradient: pixel_type_w = 0;

        for (0..channel.w) |x| {
            const left: pixel_type_w = if (x > 0) r[x - 1] else if (has_top) top_row[x] else 0;
            const top: pixel_type_w = if (has_top) top_row[x] else left;
            const topleft: pixel_type_w = if (x > 0 and has_top) top_row[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < channel.w and has_top) top_row[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) r[x - 2] else left;
            const toptop: pixel_type_w = if (has_toptop) top2_row[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < channel.w and has_top) top_row[x + 2] else topright;

            if (use_prop_9) {
                local_gradient = left + top - topleft;
                properties[slot_prop9] = @intCast(local_gradient);
            }
            if (use_prop_10) properties[slot_prop10] = @intCast(left - topleft);
            if (use_prop_11) properties[slot_prop11] = @intCast(topleft - top);
            if (use_prop_12) properties[slot_prop12] = @intCast(top - topright);
            if (use_prop_13) properties[slot_prop13] = @intCast(top - toptop);

            var wp_pred: pixel_type_w = 0;
            if (wp_state) |*ws| {
                if (use_prop_wp) {
                    wp_pred = ws.predictNoProps(x, y, channel.w, top, left, topright, topleft, toptop);
                    properties[slot_prop15] = ws.getWPProp();
                } else {
                    wp_pred = ws.predictNoWPProp(x, y, channel.w, top, left, topright, topleft, toptop);
                }
            }

            const lr = if (comptime use_compact_tree)
                compactNoRefLookup(lookup_ctx, &properties)
            else
                lookup_ctx.lookup(&properties);
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

fn decodeModularChannelNoRefsMask(
    comptime read_next: anytype,
    comptime property_mask: u8,
    br: *BitReader,
    reader: *ANSSymbolReader,
    flat_tree: []context_predict.FlatDecisionNode,
    wp_header: *const weighted.Header,
    channel: *Channel,
    allocator: std.mem.Allocator,
    use_wp: bool,
) JxlError!void {
    remapNoRefMaskTree(property_mask, flat_tree);

    var compact_storage: [kInlineCompactNoRefTreeNodes]CompactNoRefNode = undefined;
    if (compactNoRefTree(flat_tree, &compact_storage)) |compact_tree| {
        return decodeModularChannelNoRefsMaskLoop(
            read_next,
            property_mask,
            true,
            compact_tree,
            br,
            reader,
            wp_header,
            channel,
            allocator,
            use_wp,
        );
    }

    const tree_lookup = context_predict.MATreeLookup.init(flat_tree);
    return decodeModularChannelNoRefsMaskLoop(
        read_next,
        property_mask,
        false,
        tree_lookup,
        br,
        reader,
        wp_header,
        channel,
        allocator,
        use_wp,
    );
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
    var flat_tree = try context_predict.filterTree(
        allocator,
        global_tree,
        static_props,
        &num_props,
        &use_wp,
        &wp_only,
        &gradient_only,
        &property_use,
    );
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

    if (specializedPropertyMask(&property_use)) |property_mask| {
        switch (property_mask) {
            kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            kMaskProp9 | kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp9 | kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            kMaskProp13 | kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp13 | kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            kMaskProp10 | kMaskProp11 | kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp10 | kMaskProp11 | kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            kMaskProp10 | kMaskProp11 | kMaskProp13 | kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp10 | kMaskProp11 | kMaskProp13 | kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            kMaskProp9 | kMaskProp10 | kMaskProp11 | kMaskProp12 | kMaskProp13 | kMaskProp15 => return decodeModularChannelNoRefsMask(read_next, kMaskProp9 | kMaskProp10 | kMaskProp11 | kMaskProp12 | kMaskProp13 | kMaskProp15, br, reader, flat_tree.items, wp_header, channel, allocator, use_wp),
            else => {},
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
        const has_top = y > 0;
        const has_toptop = y > 1;
        const top_row = if (has_top) channel.rowConst(y - 1) else &[_]pixel_type{};
        const top2_row = if (has_toptop) channel.rowConst(y - 2) else &[_]pixel_type{};
        if (references) |*refs| {
            precomputeReferences(channel, y, image, chan, &property_use, refs);
        }

        if (use_prop_y) properties[2] = @intCast(y);
        var local_gradient: pixel_type_w = 0;

        for (0..channel.w) |x| {
            const left: pixel_type_w = if (x > 0) r[x - 1] else if (has_top) top_row[x] else 0;
            const top: pixel_type_w = if (has_top) top_row[x] else left;
            const topleft: pixel_type_w = if (x > 0 and has_top) top_row[x - 1] else left;
            const topright: pixel_type_w = if (x + 1 < channel.w and has_top) top_row[x + 1] else top;
            const leftleft: pixel_type_w = if (x > 1) r[x - 2] else left;
            const toptop: pixel_type_w = if (has_toptop) top2_row[x] else top;
            const toprightright: pixel_type_w = if (x + 2 < channel.w and has_top) top_row[x + 2] else topright;

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
                if (use_prop_wp) {
                    wp_pred = ws.predictNoProps(x, y, channel.w, top, left, topright, topleft, toptop);
                    properties[context_predict.kWPProp] = ws.getWPProp();
                } else {
                    wp_pred = ws.predictNoWPProp(x, y, channel.w, top, left, topright, topleft, toptop);
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
    try image.transforms.ensureUnusedCapacity(image.allocator, header.transforms.len);
    image.transforms.appendSliceAssumeCapacity(header.transforms);
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
    var local_tree: dec_ma.Tree = .empty;
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

test "specializedPropertyMask accepts hot non-reference masks" {
    var property_use = context_predict.PropertyUsePlan{};
    property_use.mark(13);
    property_use.mark(context_predict.kWPProp);
    property_use.finalize();

    try testing.expectEqual(@as(?u8, 0b11_0000), specializedPropertyMask(&property_use));
}

test "specializedPropertyMask rejects reference and unsupported properties" {
    var reference_props = context_predict.PropertyUsePlan{};
    reference_props.mark(context_predict.kNumNonrefProperties);
    reference_props.finalize();
    try testing.expectEqual(@as(?u8, null), specializedPropertyMask(&reference_props));

    var unsupported_props = context_predict.PropertyUsePlan{};
    unsupported_props.mark(8);
    unsupported_props.mark(context_predict.kWPProp);
    unsupported_props.finalize();
    try testing.expectEqual(@as(?u8, null), specializedPropertyMask(&unsupported_props));
}

test "remapNoRefMaskTree preserves lookup for compact mask 13+15" {
    const mask = kMaskProp13 | kMaskProp15;
    const original = [_]context_predict.FlatDecisionNode{
        .{
            .property0 = 13,
            .splitval0 = 4,
            .properties = .{ 15, 0 },
            .splitvals = .{ 7, 0 },
            .childID = 1,
        },
        .{ .property0 = -1, .predictor = .gradient, .childID = 3, .multiplier = 1 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 5, .multiplier = 2 },
        .{ .property0 = -1, .predictor = .gradient, .childID = 7, .multiplier = 3 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 9, .multiplier = 4 },
    };
    var remapped = original;
    remapNoRefMaskTree(mask, &remapped);

    var generic_props = [_]pixel_type{0} ** context_predict.kNumNonrefProperties;
    generic_props[13] = 6;
    generic_props[context_predict.kWPProp] = 2;

    var compact_props = [_]pixel_type{0} ** 3;
    compact_props[compactPropertySlot(mask, kMaskProp13)] = generic_props[13];
    compact_props[compactPropertySlot(mask, kMaskProp15)] = generic_props[context_predict.kWPProp];

    const expected = context_predict.MATreeLookup.init(&original).lookup(&generic_props);
    const actual = context_predict.MATreeLookup.init(&remapped).lookup(&compact_props);
    try testing.expectEqualDeep(expected, actual);
}

test "remapNoRefMaskTree keeps zero sentinel at local slot zero" {
    const mask = kMaskProp9 | kMaskProp10 | kMaskProp11 | kMaskProp12 | kMaskProp13 | kMaskProp15;
    var remapped = [_]context_predict.FlatDecisionNode{
        .{
            .property0 = 9,
            .splitval0 = 6,
            .properties = .{ 0, 15 },
            .splitvals = .{ 0, 5 },
            .childID = 1,
        },
        .{ .property0 = -1, .predictor = .gradient, .childID = 1, .multiplier = 1 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 2, .multiplier = 2 },
        .{ .property0 = -1, .predictor = .gradient, .childID = 3, .multiplier = 3 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 4, .multiplier = 4 },
    };
    remapNoRefMaskTree(mask, &remapped);

    try testing.expectEqual(@as(i16, 0), remapped[0].properties[0]);
    try testing.expectEqual(@as(i32, compactPropertySlot(mask, kMaskProp9)), remapped[0].property0);
    try testing.expectEqual(@as(i16, @intCast(compactPropertySlot(mask, kMaskProp15))), remapped[0].properties[1]);
}

test "compactNoRefTree preserves lookup for remapped tree" {
    const mask = kMaskProp10 | kMaskProp11 | kMaskProp13 | kMaskProp15;
    const original = [_]context_predict.FlatDecisionNode{
        .{
            .property0 = 13,
            .splitval0 = 4,
            .properties = .{ 10, 15 },
            .splitvals = .{ 1, 7 },
            .childID = 1,
        },
        .{ .property0 = -1, .predictor = .gradient, .childID = 3, .multiplier = 1 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 5, .multiplier = 2 },
        .{ .property0 = -1, .predictor = .gradient, .childID = 7, .multiplier = 3 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 9, .multiplier = 4 },
    };
    var remapped = original;
    remapNoRefMaskTree(mask, &remapped);

    var compact_storage: [8]CompactNoRefNode = undefined;
    const compact_tree = compactNoRefTree(&remapped, &compact_storage) orelse unreachable;

    var generic_props = [_]pixel_type{0} ** context_predict.kNumNonrefProperties;
    generic_props[10] = 3;
    generic_props[11] = -2;
    generic_props[13] = 6;
    generic_props[context_predict.kWPProp] = 2;

    var compact_props = [_]pixel_type{0} ** 5;
    compact_props[compactPropertySlot(mask, kMaskProp10)] = generic_props[10];
    compact_props[compactPropertySlot(mask, kMaskProp11)] = generic_props[11];
    compact_props[compactPropertySlot(mask, kMaskProp13)] = generic_props[13];
    compact_props[compactPropertySlot(mask, kMaskProp15)] = generic_props[context_predict.kWPProp];

    const expected = context_predict.MATreeLookup.init(&remapped).lookup(&compact_props);
    const actual = compactNoRefLookup(compact_tree, &compact_props);
    try testing.expectEqualDeep(expected, actual);
}

test "compactNoRefTree returns null when inline storage is too small" {
    const mask = kMaskProp13 | kMaskProp15;
    var remapped = [_]context_predict.FlatDecisionNode{
        .{
            .property0 = 13,
            .splitval0 = 4,
            .properties = .{ 15, 0 },
            .splitvals = .{ 7, 0 },
            .childID = 1,
        },
        .{ .property0 = -1, .predictor = .gradient, .childID = 3, .multiplier = 1 },
        .{ .property0 = -1, .predictor = .weighted, .childID = 5, .multiplier = 2 },
    };
    remapNoRefMaskTree(mask, &remapped);

    var compact_storage: [2]CompactNoRefNode = undefined;
    try testing.expectEqual(@as(?[]const CompactNoRefNode, null), compactNoRefTree(&remapped, &compact_storage));
}
