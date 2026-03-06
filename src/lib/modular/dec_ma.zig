// MA tree decoder: PropertyDecisionNode and DecodeTree.
// Transliterated from lib/jxl/modular/encoding/dec_ma.h and dec_ma.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const dec_ans = @import("../entropy/dec_ans.zig");
const ANSCode = dec_ans.ANSCode;
const ANSSymbolReader = dec_ans.ANSSymbolReader;
const pack_signed = @import("../base/pack_signed.zig");
const ma_common = @import("ma_common.zig");
const options = @import("options.zig");
const Predictor = options.Predictor;
const PropertyVal = options.PropertyVal;

// ── PropertyDecisionNode ──

pub const PropertyDecisionNode = struct {
    splitval: PropertyVal = 0,
    property: i16 = -1, // -1 = leaf node
    lchild: u32 = 0,
    rchild: u32 = 0,
    predictor: Predictor = .zero,
    predictor_offset: i64 = 0,
    multiplier: u32 = 1,

    pub fn leaf(pred: Predictor, offset: i64, mult: u32) PropertyDecisionNode {
        return .{
            .property = -1,
            .predictor = pred,
            .predictor_offset = offset,
            .multiplier = mult,
        };
    }

    pub fn split(p: i16, split_val: PropertyVal, lch: u32, rch: u32) PropertyDecisionNode {
        return .{
            .property = p,
            .splitval = split_val,
            .lchild = lch,
            .rchild = if (rch == 0 and lch != 0) lch + 1 else rch,
        };
    }
};

pub const Tree = std.ArrayList(PropertyDecisionNode);

// ── Tree validation ──

fn validateTree(tree: []const PropertyDecisionNode) JxlError!void {
    if (tree.len == 0) return error.GenericError;

    // Find max property index
    var num_properties: usize = 0;
    for (tree) |node| {
        if (node.property >= 0 and @as(usize, @intCast(node.property)) >= num_properties) {
            num_properties = @as(usize, @intCast(node.property)) + 1;
        }
    }

    // Check tree height
    const allocator = std.heap.page_allocator;
    const height = allocator.alloc(i32, tree.len) catch return;
    defer allocator.free(height);
    @memset(height, 0);

    const kHeightLimit: i32 = 2048;
    for (0..tree.len) |i| {
        if (height[i] > kHeightLimit) return error.GenericError;
        if (tree[i].property == -1) continue;
        if (tree[i].lchild >= tree.len or tree[i].rchild >= tree.len) return error.GenericError;
        height[tree[i].lchild] = height[i] + 1;
        height[tree[i].rchild] = height[i] + 1;
    }
}

// ── Inner DecodeTree (with ANS reader) ──

fn decodeTreeInner(
    allocator: std.mem.Allocator,
    br: *BitReader,
    reader: *ANSSymbolReader,
    context_map: []const u8,
    tree: *Tree,
    tree_size_limit: usize,
) JxlError!void {
    var leaf_id: u32 = 0;
    var to_decode: usize = 1;

    while (to_decode > 0) {
        if (tree.items.len > tree_size_limit) return error.GenericError;
        to_decode -= 1;

        const prop1 = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.property), br, context_map);
        if (prop1 > 256) return error.GenericError;
        const property: i16 = @as(i16, @intCast(prop1)) - 1;

        if (property == -1) {
            // Leaf node
            const predictor_raw = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.predictor), br, context_map);
            if (predictor_raw >= options.kNumModularPredictors) return error.GenericError;

            const offset_raw = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.offset), br, context_map);
            const predictor_offset: i64 = pack_signed.unpackSigned(@intCast(offset_raw));

            const mul_log = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.multiplier_log), br, context_map);
            if (mul_log >= 31) return error.GenericError;

            const mul_bits = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.multiplier_bits), br, context_map);
            if (mul_bits >= (@as(usize, 1) << @intCast(31 - mul_log)) - 1) return error.GenericError;

            const multiplier: u32 = (@as(u32, @intCast(mul_bits)) + 1) << @intCast(mul_log);

            try tree.append(allocator, .{
                .property = -1,
                .splitval = 0,
                .lchild = leaf_id,
                .rchild = 0,
                .predictor = @enumFromInt(@as(u32, @intCast(predictor_raw))),
                .predictor_offset = predictor_offset,
                .multiplier = multiplier,
            });
            leaf_id += 1;
            continue;
        }

        // Inner node
        const splitval_raw = reader.readHybridUint(@intFromEnum(ma_common.MATreeContext.split_val), br, context_map);
        const splitval: PropertyVal = pack_signed.unpackSigned(@intCast(splitval_raw));

        const lchild: u32 = @intCast(tree.items.len + to_decode + 1);
        const rchild: u32 = @intCast(tree.items.len + to_decode + 2);

        try tree.append(allocator, .{
            .property = property,
            .splitval = splitval,
            .lchild = lchild,
            .rchild = rchild,
            .predictor = .zero,
            .predictor_offset = 0,
            .multiplier = 1,
        });
        to_decode += 2;
    }
    try validateTree(tree.items);
}

// ── Public DecodeTree ──

/// Decodes a MA tree from the bitstream.
/// Reads its own ANS histograms (kNumTreeContexts contexts),
/// then decodes the tree nodes, and verifies final ANS state.
pub fn decodeTree(
    allocator: std.mem.Allocator,
    br: *BitReader,
    tree: *Tree,
    tree_size_limit: usize,
) JxlError!void {
    var tree_code = ANSCode.init(allocator);
    defer tree_code.deinit();

    const tree_context_map = dec_ans.decodeHistograms(
        allocator,
        br,
        ma_common.kNumTreeContexts,
        &tree_code,
    ) catch return error.GenericError;
    defer allocator.free(tree_context_map);

    // Check for infinite tree: if the property context has a single degenerate
    // symbol > 0, every node would be a non-leaf, leading to infinite expansion.
    if (tree_code.degenerate_symbols.len > tree_context_map[@intFromEnum(ma_common.MATreeContext.property)]) {
        if (tree_code.degenerate_symbols[tree_context_map[@intFromEnum(ma_common.MATreeContext.property)]] > 0) {
            return error.GenericError;
        }
    }

    var reader = ANSSymbolReader.create(&tree_code, br, 0, allocator) catch return error.GenericError;
    defer reader.deinit();

    const limit = @min(tree_size_limit, ma_common.kMaxTreeSize);
    try decodeTreeInner(allocator, br, &reader, tree_context_map, tree, limit);

    if (!reader.checkANSFinalState()) {
        return error.GenericError;
    }
}

// ── Tests ──

const testing = std.testing;

test "PropertyDecisionNode leaf default" {
    const node = PropertyDecisionNode{};
    try testing.expectEqual(@as(i16, -1), node.property);
    try testing.expectEqual(Predictor.zero, node.predictor);
    try testing.expectEqual(@as(u32, 1), node.multiplier);
}

test "PropertyDecisionNode.leaf" {
    const node = PropertyDecisionNode.leaf(.gradient, 5, 2);
    try testing.expectEqual(@as(i16, -1), node.property);
    try testing.expectEqual(Predictor.gradient, node.predictor);
    try testing.expectEqual(@as(i64, 5), node.predictor_offset);
    try testing.expectEqual(@as(u32, 2), node.multiplier);
}

test "PropertyDecisionNode.split" {
    const node = PropertyDecisionNode.split(3, 42, 10, 11);
    try testing.expectEqual(@as(i16, 3), node.property);
    try testing.expectEqual(@as(PropertyVal, 42), node.splitval);
    try testing.expectEqual(@as(u32, 10), node.lchild);
    try testing.expectEqual(@as(u32, 11), node.rchild);
}
