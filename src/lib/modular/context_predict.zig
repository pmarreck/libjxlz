// Context prediction: ClampedGradient, Select, PredictOne, FlatDecisionNode, MATreeLookup, FilterTree.
// Transliterated from lib/jxl/modular/encoding/context_predict.h

const std = @import("std");
const options = @import("options.zig");
const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;
const Predictor = options.Predictor;
const PropertyVal = options.PropertyVal;
const kNumStaticProperties = options.kNumStaticProperties;
const kNumModularPredictors = options.kNumModularPredictors;
const weighted = @import("weighted.zig");
const dec_ma = @import("dec_ma.zig");

pub const kExtraPropsPerChannel: usize = 4;
pub const kNumNonrefProperties: usize = kNumStaticProperties + 13 + weighted.kNumProperties;
pub const kWPProp: usize = kNumNonrefProperties - weighted.kNumProperties;
pub const kGradientProp: usize = 9;

// ── ClampedGradient ──

pub fn clampedGradient(n: anytype, w: anytype, l: anytype) @TypeOf(n) {
    const T = @TypeOf(n);
    const m = @min(n, w);
    const M = @max(n, w);
    // grad = n + w - l, with potential overflow handled via unsigned arithmetic
    const grad: T = @bitCast(@as(
        @Type(.{ .int = .{ .signedness = .unsigned, .bits = @typeInfo(T).int.bits } }),
        @bitCast(n),
    ) +% @as(
        @Type(.{ .int = .{ .signedness = .unsigned, .bits = @typeInfo(T).int.bits } }),
        @bitCast(w),
    ) -% @as(
        @Type(.{ .int = .{ .signedness = .unsigned, .bits = @typeInfo(T).int.bits } }),
        @bitCast(l),
    ));
    const grad_clamp_M: T = if (l < m) M else grad;
    return if (l > M) m else grad_clamp_M;
}

pub fn select(a: pixel_type_w, b: pixel_type_w, c: pixel_type_w) pixel_type_w {
    const p = a + b - c;
    const pa = if (p - a < 0) -(p - a) else p - a;
    const pb = if (p - b < 0) -(p - b) else p - b;
    return if (pa < pb) a else b;
}

// ── PredictOne ──

pub fn predictOne(
    p: Predictor,
    left: pixel_type_w,
    top: pixel_type_w,
    toptop: pixel_type_w,
    topleft: pixel_type_w,
    topright: pixel_type_w,
    leftleft: pixel_type_w,
    toprightright: pixel_type_w,
    wp_pred: pixel_type_w,
) pixel_type_w {
    return switch (p) {
        .zero => 0,
        .left => left,
        .top => top,
        .select => select(left, top, topleft),
        .weighted => wp_pred,
        .gradient => clampedGradient(left, top, topleft),
        .top_left => topleft,
        .top_right => topright,
        .left_left => leftleft,
        .average0 => @divTrunc(left + top, 2),
        .average1 => @divTrunc(left + topleft, 2),
        .average2 => @divTrunc(topleft + top, 2),
        .average3 => @divTrunc(top + topright, 2),
        .average4 => @divTrunc(6 * top - 2 * toptop + 7 * left + leftleft + toprightright + 3 * topright + 8, 16),
        else => 0,
    };
}

// ── FlatDecisionNode ──

pub const FlatDecisionNode = struct {
    property0: i32 = -1, // -1 if leaf
    // Union-like fields depending on leaf vs inner
    splitval0: PropertyVal = 0, // or predictor (if leaf)
    predictor: Predictor = .zero,
    splitvals: [2]PropertyVal = .{ 0, 0 }, // or multiplier (if leaf)
    multiplier: i32 = 1,
    childID: u32 = 0, // ctx id if leaf
    properties: [2]i16 = .{ 0, 0 }, // or predictor_offset (if leaf)
    predictor_offset: i64 = 0,
};

pub const FlatTree = std.ArrayList(FlatDecisionNode);

// ── PredictionResult ──

pub const PredictionResult = struct {
    context: u32 = 0,
    guess: pixel_type_w = 0,
    predictor: Predictor = .zero,
    multiplier: i32 = 1,
};

// ── MATreeLookup ──

pub const MATreeLookup = struct {
    nodes: []const FlatDecisionNode,

    pub fn init(tree: []const FlatDecisionNode) MATreeLookup {
        return .{ .nodes = tree };
    }

    pub const LookupResult = struct {
        context: u32,
        predictor: Predictor,
        offset: i64,
        multiplier: i32,
    };

    pub fn lookup(self: *const MATreeLookup, properties: []const pixel_type) LookupResult {
        var pos: u32 = 0;
        while (true) {
            const node = self.nodes[pos];
            if (node.property0 < 0) {
                return .{
                    .context = node.childID,
                    .predictor = node.predictor,
                    .offset = node.predictor_offset,
                    .multiplier = node.multiplier,
                };
            }
            const p0 = properties[@intCast(node.property0)] <= node.splitval0;
            const off0: u32 = if (properties[@intCast(node.properties[0])] <= node.splitvals[0]) 1 else 0;
            const off1: u32 = 2 | (if (properties[@intCast(node.properties[1])] <= node.splitvals[1]) @as(u32, 1) else 0);
            pos = node.childID + (if (p0) off1 else off0);
        }
    }
};

// ── FilterTree ──

pub fn filterTree(
    allocator: std.mem.Allocator,
    global_tree: []const dec_ma.PropertyDecisionNode,
    static_props: [kNumStaticProperties]pixel_type,
    num_props: *usize,
    use_wp: *bool,
    wp_only: *bool,
    gradient_only: *bool,
) !FlatTree {
    num_props.* = 0;
    var has_wp = false;
    var has_non_wp = false;
    gradient_only.* = true;

    var output: FlatTree = .{};

    // BFS queue
    var queue: std.ArrayList(usize) = .{};
    defer queue.deinit(allocator);
    try queue.append(allocator, 0);

    while (queue.items.len > 0) {
        var cur = queue.orderedRemove(0);

        // Skip nodes decided by static properties
        while (global_tree[cur].property >= 0 and
            global_tree[cur].property < @as(i16, @intCast(kNumStaticProperties)))
        {
            if (static_props[@intCast(global_tree[cur].property)] > global_tree[cur].splitval) {
                cur = global_tree[cur].lchild;
            } else {
                cur = global_tree[cur].rchild;
            }
        }

        if (global_tree[cur].property == -1) {
            // Leaf node
            var flat = FlatDecisionNode{};
            flat.property0 = -1;
            flat.childID = global_tree[cur].lchild;
            flat.predictor = global_tree[cur].predictor;
            flat.predictor_offset = global_tree[cur].predictor_offset;
            flat.multiplier = @intCast(global_tree[cur].multiplier);
            gradient_only.* = gradient_only.* and (flat.predictor == .gradient);
            has_wp = has_wp or (flat.predictor == .weighted);
            has_non_wp = has_non_wp or (flat.predictor != .weighted);
            try output.append(allocator, flat);
            continue;
        }

        var flat = FlatDecisionNode{};
        flat.childID = @intCast(output.items.len + queue.items.len + 1);
        flat.property0 = global_tree[cur].property;
        num_props.* = @max(@as(usize, @intCast(flat.property0)) + 1, num_props.*);
        flat.splitval0 = global_tree[cur].splitval;

        for (0..2) |i| {
            var cur_child: usize = if (i == 0) global_tree[cur].lchild else global_tree[cur].rchild;

            // Skip static-decidable children
            while (global_tree[cur_child].property >= 0 and
                global_tree[cur_child].property < @as(i16, @intCast(kNumStaticProperties)))
            {
                if (static_props[@intCast(global_tree[cur_child].property)] > global_tree[cur_child].splitval) {
                    cur_child = global_tree[cur_child].lchild;
                } else {
                    cur_child = global_tree[cur_child].rchild;
                }
            }

            if (global_tree[cur_child].property == -1) {
                flat.properties[i] = 0;
                flat.splitvals[i] = 0;
                try queue.append(allocator, cur_child);
                try queue.append(allocator, cur_child); // duplicate leaf
            } else {
                flat.properties[i] = global_tree[cur_child].property;
                flat.splitvals[i] = global_tree[cur_child].splitval;
                try queue.append(allocator, global_tree[cur_child].lchild);
                try queue.append(allocator, global_tree[cur_child].rchild);
                num_props.* = @max(@as(usize, @intCast(flat.properties[i])) + 1, num_props.*);
            }
        }

        // Mark properties
        inline for (.{ flat.property0, flat.properties[0], flat.properties[1] }) |prop| {
            if (prop == @as(i32, @intCast(kWPProp))) {
                has_wp = true;
            } else if (prop >= @as(i32, @intCast(kNumStaticProperties))) {
                has_non_wp = true;
            }
            if (prop >= @as(i32, @intCast(kNumStaticProperties)) and prop != @as(i32, @intCast(kGradientProp))) {
                gradient_only.* = false;
            }
        }

        try output.append(allocator, flat);
    }

    if (num_props.* > kNumNonrefProperties) {
        num_props.* = ((num_props.* - kNumNonrefProperties + kExtraPropsPerChannel - 1) / kExtraPropsPerChannel) * kExtraPropsPerChannel + kNumNonrefProperties;
    } else {
        num_props.* = kNumNonrefProperties;
    }
    use_wp.* = has_wp;
    wp_only.* = has_wp and !has_non_wp;

    return output;
}

// ── Tests ──

const testing = std.testing;

test "clampedGradient basic" {
    // n=10, w=20, l=15 => grad = 10+20-15 = 15; m=10,M=20; l=15 in [10,20] => grad
    try testing.expectEqual(@as(i32, 15), clampedGradient(@as(i32, 10), @as(i32, 20), @as(i32, 15)));
    // l < m: clamp to M
    try testing.expectEqual(@as(i32, 20), clampedGradient(@as(i32, 10), @as(i32, 20), @as(i32, 5)));
    // l > M: clamp to m
    try testing.expectEqual(@as(i32, 10), clampedGradient(@as(i32, 10), @as(i32, 20), @as(i32, 25)));
}

test "select basic" {
    // a=10, b=20, c=15 => p=15, pa=5, pb=5 => pa < pb false => b
    try testing.expectEqual(@as(pixel_type_w, 20), select(10, 20, 15));
    // a=10, b=20, c=10 => p=20, pa=10, pb=0 => pa < pb false => b
    try testing.expectEqual(@as(pixel_type_w, 20), select(10, 20, 10));
    // a=10, b=20, c=20 => p=10, pa=0, pb=10 => pa < pb => a
    try testing.expectEqual(@as(pixel_type_w, 10), select(10, 20, 20));
}

test "predictOne zero" {
    try testing.expectEqual(@as(pixel_type_w, 0), predictOne(.zero, 1, 2, 3, 4, 5, 6, 7, 8));
}

test "predictOne gradient" {
    // clampedGradient(left=10, top=20, topleft=15) = 15
    try testing.expectEqual(@as(pixel_type_w, 15), predictOne(.gradient, 10, 20, 0, 15, 0, 0, 0, 0));
}
