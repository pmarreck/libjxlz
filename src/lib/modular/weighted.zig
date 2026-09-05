// Weighted predictor header and state.
// Transliterated from lib/jxl/modular/encoding/context_predict.h (weighted:: namespace)

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("../codec/field_coders.zig");
const options = @import("options.zig");
const pixel_type = options.pixel_type;
const pixel_type_w = options.pixel_type_w;

pub const kNumPredictors: usize = 4;
pub const kPredExtraBits: i64 = 3;
pub const kPredictionRound: i64 = ((1 << kPredExtraBits) >> 1) - 1;
pub const kNumProperties: usize = 1;

pub const Header = struct {
    p1C: pixel_type = 16,
    p2C: pixel_type = 10,
    p3Ca: pixel_type = 7,
    p3Cb: pixel_type = 7,
    p3Cc: pixel_type = 7,
    p3Cd: pixel_type = 0,
    p3Ce: pixel_type = 0,
    w: [kNumPredictors]u32 = .{ 0xd, 0xc, 0xc, 0xc },

    pub fn readFromBitStream(br: *BitReader) Header {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return Header{};
        }

        var h = Header{};
        // 7 predictor coefficients, each 5 bits with defaults
        h.p1C = @intCast(br.readBits(5));
        h.p2C = @intCast(br.readBits(5));
        h.p3Ca = @intCast(br.readBits(5));
        h.p3Cb = @intCast(br.readBits(5));
        h.p3Cc = @intCast(br.readBits(5));
        h.p3Cd = @intCast(br.readBits(5));
        h.p3Ce = @intCast(br.readBits(5));
        // 4 weights, each 4 bits
        h.w[0] = @intCast(br.readBits(4));
        h.w[1] = @intCast(br.readBits(4));
        h.w[2] = @intCast(br.readBits(4));
        h.w[3] = @intCast(br.readBits(4));

        return h;
    }
};

// Approximation lookup table: divlookup[i] = (1 << 24) / (i + 1)
const divlookup: [64]u32 = .{
    16777216, 8388608, 5592405, 4194304, 3355443, 2796202, 2396745, 2097152,
    1864135,  1677721, 1525201, 1398101, 1290555, 1198372, 1118481, 1048576,
    986895,   932067,  883011,  838860,  798915,  762600,  729444,  699050,
    671088,   645277,  621378,  599186,  578524,  559240,  541200,  524288,
    508400,   493447,  479349,  466033,  453438,  441505,  430185,  419430,
    409200,   399457,  390167,  381300,  372827,  364722,  356962,  349525,
    342392,   335544,  328965,  322638,  316551,  310689,  305040,  299593,
    294337,   289262,  284359,  279620,  275036,  270600,  266305,  262144,
};

pub const State = struct {
    prediction: [kNumPredictors]pixel_type_w = .{ 0, 0, 0, 0 },
    pred: pixel_type_w = 0,
    wp_prop: pixel_type = 0, // WP prediction error property for tree lookup
    pred_errors: [kNumPredictors][]u32 = undefined,
    error_buf: [kNumPredictors][]i32 = undefined,
    errors: []i32 = undefined,
    header: Header,
    allocator: std.mem.Allocator,

    // Buffers stored inline for cleanup
    pred_error_bufs: [kNumPredictors][]u32 = .{ &.{}, &.{}, &.{}, &.{} },
    error_storage: []i32 = &.{},

    pub fn init(allocator: std.mem.Allocator, header: Header, xsize: usize, ysize: usize) !State {
        _ = ysize;
        var s = State{
            .header = header,
            .allocator = allocator,
        };
        errdefer s.deinit();
        const buf_size = (xsize + 2) * 2;
        for (0..kNumPredictors) |i| {
            s.pred_error_bufs[i] = try allocator.alloc(u32, buf_size);
            @memset(s.pred_error_bufs[i], 0);
            s.pred_errors[i] = s.pred_error_bufs[i];
        }
        s.error_storage = try allocator.alloc(i32, buf_size);
        @memset(s.error_storage, 0);
        s.errors = s.error_storage;
        return s;
    }

    pub fn deinit(self: *State) void {
        for (0..kNumPredictors) |i| {
            if (self.pred_error_bufs[i].len > 0) {
                self.allocator.free(self.pred_error_bufs[i]);
            }
        }
        if (self.error_storage.len > 0) {
            self.allocator.free(self.error_storage);
        }
    }

    inline fn addBits(x: pixel_type_w) pixel_type_w {
        return x << kPredExtraBits;
    }

    inline fn floorLog2Nonzero(v: u64) u6 {
        return @intCast(63 - @clz(v));
    }

    inline fn errorWeight(self: *const State, x: u64, maxweight: u32) u32 {
        _ = self;
        const shift_raw: i32 = @as(i32, @intCast(floorLog2Nonzero(x + 1))) - 5;
        const shift: u6 = if (shift_raw < 0) 0 else @intCast(shift_raw);
        const shift5: u5 = @intCast(@min(shift, 31));
        return 4 + ((maxweight * divlookup[x >> shift]) >> shift5);
    }

    inline fn weightedAverage(self: *const State, p: *const [kNumPredictors]pixel_type_w, w_in: [kNumPredictors]u32) pixel_type_w {
        _ = self;
        var w = w_in;
        var weight_sum: u32 = 0;
        inline for (0..kNumPredictors) |i| {
            weight_sum += w[i];
        }
        const log_weight = floorLog2Nonzero(weight_sum);
        const shift: u5 = if (log_weight >= 4) @intCast(log_weight - 4) else 0;
        weight_sum = 0;
        inline for (0..kNumPredictors) |i| {
            w[i] >>= shift;
            weight_sum += w[i];
        }
        var sum: pixel_type_w = @intCast((weight_sum >> 1) -% 1);
        inline for (0..kNumPredictors) |i| {
            sum += p[i] * @as(pixel_type_w, @intCast(w[i]));
        }
        return @intCast((@as(i128, sum) * @as(i128, divlookup[weight_sum -% 1])) >> 24);
    }

    inline fn predictImpl(
        self: *State,
        comptime compute_properties: bool,
        comptime track_wp_prop: bool,
        x: usize,
        y: usize,
        xsize: usize,
        N_in: pixel_type_w,
        W_in: pixel_type_w,
        NE_in: pixel_type_w,
        NW_in: pixel_type_w,
        NN_in: pixel_type_w,
        properties: ?*std.ArrayList(pixel_type),
        offset: usize,
    ) pixel_type_w {
        const cur_row: usize = if (y & 1 != 0) 0 else (xsize + 2);
        const prev_row: usize = if (y & 1 != 0) (xsize + 2) else 0;
        const pos_N = prev_row + x;
        const pos_NE = if (x < xsize - 1) pos_N + 1 else pos_N;
        const pos_NW = if (x > 0) pos_N - 1 else pos_N;

        var weights: [kNumPredictors]u32 = undefined;
        inline for (0..kNumPredictors) |i| {
            const err_sum: u32 = self.pred_errors[i][pos_N] +%
                self.pred_errors[i][pos_NE] +%
                self.pred_errors[i][pos_NW];
            weights[i] = self.errorWeight(err_sum, self.header.w[i]);
        }

        const N = addBits(N_in);
        const W = addBits(W_in);
        const NE = addBits(NE_in);
        const NW = addBits(NW_in);
        const NN = addBits(NN_in);

        const teW: pixel_type_w = if (x == 0) 0 else self.errors[cur_row + x - 1];
        const teN: pixel_type_w = self.errors[pos_N];
        const teNW: pixel_type_w = self.errors[pos_NW];
        const sumWN: pixel_type_w = teN + teW;
        const teNE: pixel_type_w = self.errors[pos_NE];

        if (comptime track_wp_prop) {
            var p = teW;
            if (absW(teN) > absW(p)) p = teN;
            if (absW(teNW) > absW(p)) p = teNW;
            if (absW(teNE) > absW(p)) p = teNE;
            self.wp_prop = @intCast(p);
            if (comptime compute_properties) {
                const props = properties.?;
                props.items[offset] = self.wp_prop;
            }
        }

        self.prediction[0] = W + NE - N;
        self.prediction[1] = N - ((sumWN + teNE) * @as(pixel_type_w, self.header.p1C) >> 5);
        self.prediction[2] = W - ((sumWN + teNW) * @as(pixel_type_w, self.header.p2C) >> 5);
        self.prediction[3] = N - ((teNW * @as(pixel_type_w, self.header.p3Ca) +
            teN * @as(pixel_type_w, self.header.p3Cb) +
            teNE * @as(pixel_type_w, self.header.p3Cc) +
            (NN - N) * @as(pixel_type_w, self.header.p3Cd) +
            (NW - W) * @as(pixel_type_w, self.header.p3Ce)) >> 5);

        self.pred = self.weightedAverage(&self.prediction, weights);

        // If all three have the same sign, skip clamping
        if (((teN ^ teW) | (teN ^ teNW)) > 0) {
            return @intCast((self.pred + kPredictionRound) >> @as(u6, @intCast(kPredExtraBits)));
        }

        // Otherwise clamp to min/max of W, NE, N
        const mx = @max(W, @max(NE, N));
        const mn = @min(W, @min(NE, N));
        self.pred = @max(mn, @min(mx, self.pred));
        return @intCast((self.pred + kPredictionRound) >> @as(u6, @intCast(kPredExtraBits)));
    }

    pub inline fn predict(
        self: *State,
        x: usize,
        y: usize,
        xsize: usize,
        N_in: pixel_type_w,
        W_in: pixel_type_w,
        NE_in: pixel_type_w,
        NW_in: pixel_type_w,
        NN_in: pixel_type_w,
        properties: ?*std.ArrayList(pixel_type),
        offset: usize,
    ) pixel_type_w {
        if (properties != null) {
            return self.predictImpl(true, true, x, y, xsize, N_in, W_in, NE_in, NW_in, NN_in, properties, offset);
        }
        return self.predictImpl(false, true, x, y, xsize, N_in, W_in, NE_in, NW_in, NN_in, null, 0);
    }

    pub inline fn predictNoProps(
        self: *State,
        x: usize,
        y: usize,
        xsize: usize,
        N_in: pixel_type_w,
        W_in: pixel_type_w,
        NE_in: pixel_type_w,
        NW_in: pixel_type_w,
        NN_in: pixel_type_w,
    ) pixel_type_w {
        return self.predictImpl(false, true, x, y, xsize, N_in, W_in, NE_in, NW_in, NN_in, null, 0);
    }

    pub inline fn predictNoWPProp(
        self: *State,
        x: usize,
        y: usize,
        xsize: usize,
        N_in: pixel_type_w,
        W_in: pixel_type_w,
        NE_in: pixel_type_w,
        NW_in: pixel_type_w,
        NN_in: pixel_type_w,
    ) pixel_type_w {
        return self.predictImpl(false, false, x, y, xsize, N_in, W_in, NE_in, NW_in, NN_in, null, 0);
    }

    pub fn getWPProp(self: *const State) pixel_type {
        return self.wp_prop;
    }

    pub fn updateErrors(self: *State, val_in: pixel_type_w, x: usize, y: usize, xsize: usize) void {
        const cur_row: usize = if (y & 1 != 0) 0 else (xsize + 2);
        const prev_row: usize = if (y & 1 != 0) (xsize + 2) else 0;
        const val = addBits(val_in);
        self.errors[cur_row + x] = @truncate(self.pred - val);
        inline for (0..kNumPredictors) |i| {
            const abs_diff = absW(self.prediction[i] - val);
            const err: u32 = @truncate(@as(u64, @intCast((abs_diff + kPredictionRound) >> @as(u6, @intCast(kPredExtraBits)))));
            self.pred_errors[i][cur_row + x] = err;
            self.pred_errors[i][prev_row + x + 1] +%= err;
        }
    }

    inline fn absW(x: pixel_type_w) pixel_type_w {
        return if (x < 0) -x else x;
    }
};

// ── Tests ──

const testing = std.testing;

test "Header all default" {
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const h = Header.readFromBitStream(&br);
    try testing.expectEqual(@as(pixel_type, 16), h.p1C);
    try testing.expectEqual(@as(pixel_type, 10), h.p2C);
    try testing.expectEqual(@as(u32, 0xd), h.w[0]);
    try testing.expectEqual(@as(u32, 0xc), h.w[1]);
}

test "Header non-default" {
    var data = [_]u8{
        0x10, 0x10, 0x80, 0xB8, 0x42, 0xDB, 0x0C, 0x00,
    };
    var br = BitReader.init(&data);
    const h = Header.readFromBitStream(&br);
    try testing.expectEqual(@as(pixel_type, 8), h.p1C);
    try testing.expectEqual(@as(pixel_type, 0), h.p2C);
    try testing.expectEqual(@as(pixel_type, 2), h.p3Ca);
    try testing.expectEqual(@as(pixel_type, 0), h.p3Cb);
    try testing.expectEqual(@as(pixel_type, 4), h.p3Cc);
    try testing.expectEqual(@as(pixel_type, 14), h.p3Cd);
    try testing.expectEqual(@as(pixel_type, 5), h.p3Ce);
    try testing.expectEqual(@as(u32, 4), h.w[0]);
    try testing.expectEqual(@as(u32, 11), h.w[1]);
    try testing.expectEqual(@as(u32, 13), h.w[2]);
    try testing.expectEqual(@as(u32, 12), h.w[3]);
}

test "predictNoProps matches null-properties path" {
    const allocator = testing.allocator;
    var state = try State.init(allocator, Header{}, 4, 2);
    defer state.deinit();

    const xsize: usize = 4;
    const x: usize = 2;
    const y: usize = 1;
    const cur_row: usize = 0;
    const prev_row: usize = xsize + 2;

    state.errors[cur_row + x - 1] = -5;
    state.errors[prev_row + x] = 3;
    state.errors[prev_row + x - 1] = -7;
    state.errors[prev_row + x + 1] = 9;

    inline for (0..kNumPredictors) |i| {
        const base: u32 = @intCast((i + 1) * 3);
        state.pred_errors[i][prev_row + x] = base;
        state.pred_errors[i][prev_row + x - 1] = base + 1;
        state.pred_errors[i][prev_row + x + 1] = base + 2;
    }

    const via_optional = state.predict(x, y, xsize, 10, 11, 12, 13, 14, null, 0);
    const wp_prop_via_optional = state.getWPProp();
    const via_specialized = state.predictNoProps(x, y, xsize, 10, 11, 12, 13, 14);
    const wp_prop_via_specialized = state.getWPProp();

    try testing.expectEqual(via_optional, via_specialized);
    try testing.expectEqual(wp_prop_via_optional, wp_prop_via_specialized);
}

test "predictNoWPProp matches prediction without mutating wp property" {
    const allocator = testing.allocator;
    var state = try State.init(allocator, Header{}, 4, 2);
    defer state.deinit();

    const xsize: usize = 4;
    const x: usize = 1;
    const y: usize = 1;
    const cur_row: usize = 0;
    const prev_row: usize = xsize + 2;

    state.wp_prop = 123;
    state.errors[cur_row + x - 1] = 8;
    state.errors[prev_row + x] = -4;
    state.errors[prev_row + x - 1] = 6;
    state.errors[prev_row + x + 1] = -3;

    inline for (0..kNumPredictors) |i| {
        const base: u32 = @intCast((i + 2) * 5);
        state.pred_errors[i][prev_row + x] = base;
        state.pred_errors[i][prev_row + x - 1] = base + 2;
        state.pred_errors[i][prev_row + x + 1] = base + 4;
    }

    const with_wp_prop = state.predictNoProps(x, y, xsize, 21, 17, 25, 13, 11);
    state.wp_prop = 123;
    const without_wp_prop = state.predictNoWPProp(x, y, xsize, 21, 17, 25, 13, 11);

    try testing.expectEqual(with_wp_prop, without_wp_prop);
    try testing.expectEqual(@as(pixel_type, 123), state.getWPProp());
}
