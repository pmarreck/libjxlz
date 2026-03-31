// Frame header with backward and forward-compatible extension capability.
// Transliterated from lib/jxl/frame_header.h and lib/jxl/frame_header.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const fc = @import("field_coders.zig");
const pack_signed = @import("../base/pack_signed.zig");
const common = @import("../base/common.zig");
const loop_filter_mod = @import("loop_filter.zig");
const image_metadata = @import("image_metadata.zig");
const headers = @import("headers.zig");
const frame_dimensions = @import("frame_dimensions.zig");

pub const kMaxNumPasses: u32 = 11;

// ── Enums ──

pub const FrameEncoding = enum(u32) {
    var_dct = 0,
    modular = 1,
};

pub const ColorTransform = enum(u32) {
    xyb = 0,
    none = 1,
    ycbcr = 2,
};

pub const FrameType = enum(u32) {
    regular_frame = 0,
    dc_frame = 1,
    reference_only = 2,
    skip_progressive = 3,
};

pub const BlendMode = enum(u32) {
    replace = 0,
    add = 1,
    blend = 2,
    alpha_weighted_add = 3,
    mul = 4,
};

// ── Frame flags ──

pub const FrameFlags = struct {
    pub const noise: u64 = 1;
    pub const patches: u64 = 2;
    pub const splines: u64 = 16;
    pub const use_dc_frame: u64 = 32;
    pub const skip_adaptive_dc_smoothing: u64 = 128;
};

// ── YCbCrChromaSubsampling ──

pub const YCbCrChromaSubsampling = struct {
    channel_mode: [3]u32 = .{ 0, 0, 0 },
    maxhs: u8 = 0,
    maxvs: u8 = 0,

    const kHShift = [4]u8{ 0, 1, 1, 0 };
    const kVShift = [4]u8{ 0, 1, 0, 1 };

    pub fn readFromBitStream(br: *BitReader) YCbCrChromaSubsampling {
        var cs = YCbCrChromaSubsampling{};
        for (0..3) |i| {
            cs.channel_mode[i] = @intCast(br.readBits(2));
        }
        cs.recompute();
        return cs;
    }

    fn recompute(self: *YCbCrChromaSubsampling) void {
        self.maxhs = 0;
        self.maxvs = 0;
        for (self.channel_mode) |ch| {
            self.maxhs = @max(self.maxhs, kHShift[ch]);
            self.maxvs = @max(self.maxvs, kVShift[ch]);
        }
    }

    pub fn hShift(self: YCbCrChromaSubsampling, c: usize) u8 {
        return kHShift[self.channel_mode[c]];
    }

    pub fn vShift(self: YCbCrChromaSubsampling, c: usize) u8 {
        return kVShift[self.channel_mode[c]];
    }

    pub fn maxHShift(self: YCbCrChromaSubsampling) u8 {
        return self.maxhs;
    }

    pub fn maxVShift(self: YCbCrChromaSubsampling) u8 {
        return self.maxvs;
    }

    pub fn is444(self: YCbCrChromaSubsampling) bool {
        return self.maxhs == 0 and self.maxvs == 0;
    }
};

// ── BlendingInfo ──

pub const BlendingInfo = struct {
    mode: BlendMode = .replace,
    alpha_channel: u32 = 0,
    clamp: bool = false,
    source: u32 = 0,

    pub fn readFromBitStream(
        br: *BitReader,
        num_extra_channels: usize,
        is_partial_frame: bool,
    ) JxlError!BlendingInfo {
        var bi = BlendingInfo{};

        // BlendMode: U32(Val(0), Val(1), Val(2), BitsOffset(2, 3))
        const bm_enc = fc.U32Enc.init(
            fc.val(@intFromEnum(BlendMode.replace)),
            fc.val(@intFromEnum(BlendMode.add)),
            fc.val(@intFromEnum(BlendMode.blend)),
            fc.bitsOffset(2, 3),
        );
        const bm_val = fc.U32Coder.read(bm_enc, br);
        if (bm_val > @intFromEnum(BlendMode.mul)) return error.GenericError;
        bi.mode = @enumFromInt(bm_val);

        // Alpha channel (conditional)
        if (num_extra_channels > 0 and
            (bi.mode == .blend or bi.mode == .alpha_weighted_add))
        {
            const ac_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bitsOffset(3, 3));
            bi.alpha_channel = fc.U32Coder.read(ac_enc, br);
            if (bi.alpha_channel >= num_extra_channels) return error.GenericError;
        }

        // Clamp (conditional)
        if ((num_extra_channels > 0 and
            (bi.mode == .blend or bi.mode == .alpha_weighted_add)) or
            bi.mode == .mul)
        {
            bi.clamp = br.readBits(1) != 0;
        }

        // Source frame (conditional)
        if (bi.mode != .replace or is_partial_frame) {
            const src_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
            bi.source = fc.U32Coder.read(src_enc, br);
        }

        return bi;
    }
};

// ── Passes ──

pub const Passes = struct {
    num_passes: u32 = 1,
    num_downsample: u32 = 0,
    downsample: [kMaxNumPasses]u32 = [_]u32{0} ** kMaxNumPasses,
    last_pass: [kMaxNumPasses]u32 = [_]u32{0} ** kMaxNumPasses,
    shift: [kMaxNumPasses]u32 = [_]u32{0} ** kMaxNumPasses,

    pub fn readFromBitStream(br: *BitReader) JxlError!Passes {
        var p = Passes{};

        // num_passes: U32(Val(1), Val(2), Val(3), BitsOffset(3, 4))
        const np_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.bitsOffset(3, 4));
        p.num_passes = fc.U32Coder.read(np_enc, br);
        if (p.num_passes > kMaxNumPasses) return error.GenericError;

        if (p.num_passes != 1) {
            // num_downsample: U32(Val(0), Val(1), Val(2), BitsOffset(1, 3))
            const nd_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bitsOffset(1, 3));
            p.num_downsample = fc.U32Coder.read(nd_enc, br);
            if (p.num_downsample > 4) return error.GenericError;
            if (p.num_downsample > p.num_passes) return error.GenericError;

            // Shift values for each pass except last
            for (0..p.num_passes - 1) |i| {
                p.shift[i] = @intCast(br.readBits(2));
            }
            p.shift[p.num_passes - 1] = 0;

            // Downsample values: U32(Val(1), Val(2), Val(4), Val(8))
            for (0..p.num_downsample) |i| {
                const ds_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(4), fc.val(8));
                p.downsample[i] = fc.U32Coder.read(ds_enc, br);
                if (i > 0 and p.downsample[i] >= p.downsample[i - 1]) {
                    return error.GenericError;
                }
            }

            // Last pass for each downsample: U32(Val(0), Val(1), Val(2), Bits(3))
            for (0..p.num_downsample) |i| {
                const lp_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.bits(3));
                p.last_pass[i] = fc.U32Coder.read(lp_enc, br);
                if (i > 0 and p.last_pass[i] <= p.last_pass[i - 1]) {
                    return error.GenericError;
                }
                if (p.last_pass[i] >= p.num_passes) return error.GenericError;
            }
        }

        return p;
    }
};

// ── AnimationFrame ──

pub const AnimationFrame = struct {
    duration: u32 = 0,
    timecode: u32 = 0,

    pub fn readFromBitStream(
        br: *BitReader,
        have_animation: bool,
        have_timecodes: bool,
    ) AnimationFrame {
        var af = AnimationFrame{};

        if (have_animation) {
            // duration: U32(Val(0), Val(1), Bits(8), Bits(32))
            const dur_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.bits(8), fc.bits(32));
            af.duration = fc.U32Coder.read(dur_enc, br);
        }

        if (have_timecodes) {
            af.timecode = @intCast(br.readBits(32));
        }

        return af;
    }
};

// ── FrameOrigin / FrameSize ──

pub const FrameOrigin = struct {
    x0: i32 = 0,
    y0: i32 = 0,
};

pub const FrameSize = struct {
    xsize: u32 = 0,
    ysize: u32 = 0,
};

// ── FrameHeader ──

pub const FrameHeader = struct {
    encoding: FrameEncoding = .var_dct,
    frame_type: FrameType = .regular_frame,
    flags: u64 = 0,
    color_transform: ColorTransform = .xyb,
    chroma_subsampling: YCbCrChromaSubsampling = .{},

    group_size_shift: u32 = 1,
    x_qm_scale: u32 = 3,
    b_qm_scale: u32 = 2,

    name_buf: [1071]u8 = undefined,
    name_len: u32 = 0,

    passes: Passes = .{},
    dc_level: u32 = 0,

    custom_size_or_origin: bool = false,
    frame_size: FrameSize = .{},
    frame_origin: FrameOrigin = .{},

	upsampling: u32 = 1,
	extra_channel_upsampling: [256]u32 = [_]u32{1} ** 256,

	blending_info: BlendingInfo = .{},
	extra_channel_blending_info: [256]BlendingInfo = [_]BlendingInfo{.{}} ** 256,

    animation_frame: AnimationFrame = .{},
    is_last: bool = true,
    save_as_reference: u32 = 0,
    save_before_color_transform: bool = false,

    loop_filter: loop_filter_mod.LoopFilter = .{},
    extensions: u64 = 0,

    /// Read a FrameHeader from the bitstream.
    /// `metadata` provides codestream-level information needed for conditional fields.
    /// `is_preview` indicates this is a preview frame.
    pub fn readFromBitStream(
        br: *BitReader,
        metadata: ?*const image_metadata.CodecMetadata,
        is_preview: bool,
    ) JxlError!FrameHeader {
        // AllDefault check
        if (fc.readAllDefault(br)) {
            return FrameHeader{};
        }
        var fh = FrameHeader{};

        // FrameType: U32(Val(0), Val(1), Val(2), Val(3))
        const ft_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
        const ft_val = fc.U32Coder.read(ft_enc, br);
        fh.frame_type = @enumFromInt(ft_val);

        if (is_preview and fh.frame_type != .regular_frame) {
            return error.GenericError;
        }

        // FrameEncoding (as bool: false=VarDCT, true=Modular)
        const is_modular = br.readBits(1) != 0;
        fh.encoding = if (is_modular) .modular else .var_dct;

        // Flags (U64)
        fh.flags = fc.U64Coder.read(br);

        // Color transform
        const xyb_encoded = if (metadata) |md| md.m.xyb_encoded else true;

        if (xyb_encoded) {
            fh.color_transform = .xyb;
        } else {
            const alternate = br.readBits(1) != 0;
            fh.color_transform = if (alternate) .ycbcr else .none;
        }
        // Chroma subsampling (YCbCr without DC frame)
        if (fh.color_transform == .ycbcr and (fh.flags & FrameFlags.use_dc_frame) == 0) {
            fh.chroma_subsampling = YCbCrChromaSubsampling.readFromBitStream(br);
        }

        const num_extra_channels: usize = if (metadata) |md|
            md.m.extra_channel_count
        else
            0;

        // Upsampling (if not using DC frame)
        if ((fh.flags & FrameFlags.use_dc_frame) == 0) {
            // upsampling: U32(Val(1), Val(2), Val(4), Val(8))
            const up_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(4), fc.val(8));
            fh.upsampling = fc.U32Coder.read(up_enc, br);

            if (metadata != null and num_extra_channels != 0) {
                const md = metadata.?;
                for (0..num_extra_channels) |i| {
                    const dim_shift = md.m.extra_channel_info[i].dim_shift;
                    var ec_up = fh.extra_channel_upsampling[i] >> @intCast(dim_shift);
                    const ec_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(4), fc.val(8));
                    ec_up = fc.U32Coder.read(ec_enc, br);
                    fh.extra_channel_upsampling[i] = ec_up << @intCast(dim_shift);
                    if (fh.extra_channel_upsampling[i] < fh.upsampling) {
                        return error.GenericError;
                    }
                    if (fh.extra_channel_upsampling[i] > 8) {
                        return error.GenericError;
                    }
                }
            }
        }

        // Modular group size shift
        if (fh.encoding == .modular) {
            fh.group_size_shift = @intCast(br.readBits(2));
        }
        // VarDCT + XYB QM scales
        if (fh.encoding == .var_dct and fh.color_transform == .xyb) {
            fh.x_qm_scale = @intCast(br.readBits(3));
            fh.b_qm_scale = @intCast(br.readBits(3));
        } else {
            fh.x_qm_scale = 2;
            fh.b_qm_scale = 2;
        }
        // Passes (not for kReferenceOnly)
        if (fh.frame_type != .reference_only) {
            fh.passes = try Passes.readFromBitStream(br);
        }
        // DC level (only for kDCFrame)
        if (fh.frame_type == .dc_frame) {
            const dc_enc = fc.U32Enc.init(fc.val(1), fc.val(2), fc.val(3), fc.val(4));
            fh.dc_level = fc.U32Coder.read(dc_enc, br);
        } else {
            fh.dc_level = 0;
        }
        // Custom size/origin (not for kDCFrame)
        var is_partial_frame = false;
        if (fh.frame_type != .dc_frame) {
            fh.custom_size_or_origin = br.readBits(1) != 0;
            if (fh.custom_size_or_origin) {
                const size_enc = fc.U32Enc.init(
                    fc.bits(8),
                    fc.bitsOffset(11, 256),
                    fc.bitsOffset(14, 2304),
                    fc.bitsOffset(30, 18688),
                );

                // Frame origin (only regular/skip_progressive)
                if (fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive) {
                    const ux0 = fc.U32Coder.read(size_enc, br);
                    const uy0 = fc.U32Coder.read(size_enc, br);
                    fh.frame_origin.x0 = pack_signed.unpackSigned(ux0);
                    fh.frame_origin.y0 = pack_signed.unpackSigned(uy0);
                }

                // Frame size
                fh.frame_size.xsize = fc.U32Coder.read(size_enc, br);
                fh.frame_size.ysize = fc.U32Coder.read(size_enc, br);
                if (fh.frame_size.xsize == 0 or fh.frame_size.ysize == 0) {
                    return error.GenericError;
                }

                // Partial frame detection
                if (fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive) {
                    if (metadata) |md| {
                        const image_xsize: i32 = @intCast(md.xsize());
                        const image_ysize: i32 = @intCast(md.ysize());
                        if (fh.frame_origin.x0 > 0) is_partial_frame = true;
                        if (fh.frame_origin.y0 > 0) is_partial_frame = true;
                        if (@as(i32, @intCast(fh.frame_size.xsize)) + fh.frame_origin.x0 < image_xsize)
                            is_partial_frame = true;
                        if (@as(i32, @intCast(fh.frame_size.ysize)) + fh.frame_origin.y0 < image_ysize)
                            is_partial_frame = true;
                    }
                }
            }
        }

        // Blending info + animation (regular/skip_progressive only)
        if (fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive) {
            fh.blending_info = try BlendingInfo.readFromBitStream(br, num_extra_channels, is_partial_frame);

            // Extra channel blending info
            for (0..num_extra_channels) |i| {
                fh.extra_channel_blending_info[i] = try BlendingInfo.readFromBitStream(
                    br,
                    num_extra_channels,
                    is_partial_frame,
                );
            }

            if (is_preview) {
                var replace_all = (fh.blending_info.mode == .replace);
                for (0..num_extra_channels) |i| {
                    replace_all = replace_all and (fh.extra_channel_blending_info[i].mode == .replace);
                }
                if (!replace_all or fh.custom_size_or_origin) {
                    return error.GenericError;
                }
            }

            // Animation frame
            if (metadata) |md| {
                if (md.m.have_animation) {
                    fh.animation_frame = AnimationFrame.readFromBitStream(
                        br,
                        true,
                        md.m.animation.have_timecodes,
                    );
                }
            }

            // is_last
            fh.is_last = br.readBits(1) != 0;
        } else {
            fh.is_last = false;
        }

        // save_as_reference (not DC frame, not last)
        if (fh.frame_type != .dc_frame and !fh.is_last) {
            const ref_enc = fc.U32Enc.init(fc.val(0), fc.val(1), fc.val(2), fc.val(3));
            fh.save_as_reference = fc.U32Coder.read(ref_enc, br);
        }

        // save_before_color_transform
        if (fh.frame_type != .dc_frame) {
            const can_ref = fh.canBeReferenced();
            if (can_ref and
                fh.blending_info.mode == .replace and
                !is_partial_frame and
                (fh.frame_type == .regular_frame or fh.frame_type == .skip_progressive))
            {
                fh.save_before_color_transform = br.readBits(1) != 0;
            } else if (fh.frame_type == .reference_only) {
                fh.save_before_color_transform = br.readBits(1) != 0;
            }
        } else {
            fh.save_before_color_transform = true;
        }

        // Name string: U32(Val(0), Bits(4), BitsOffset(5,16), BitsOffset(10,48))
        const name_enc = fc.U32Enc.init(fc.val(0), fc.bits(4), fc.bitsOffset(5, 16), fc.bitsOffset(10, 48));
        fh.name_len = fc.U32Coder.read(name_enc, br);
        if (fh.name_len > 1071) return error.GenericError;
        for (0..fh.name_len) |i| {
            fh.name_buf[i] = @intCast(br.readBits(8));
        }

        // LoopFilter
        fh.loop_filter = try loop_filter_mod.LoopFilter.readFromBitStream(br, is_modular);

        // Extensions
        fh.extensions = fc.readExtensions(br);

        return fh;
    }

    pub fn canBeReferenced(self: FrameHeader) bool {
        return !self.is_last and self.frame_type != .dc_frame and
            (self.animation_frame.duration == 0 or self.save_as_reference != 0);
    }

    pub fn needsColorTransform(self: FrameHeader) bool {
        return !self.save_before_color_transform or
            self.frame_type == .regular_frame or
            self.frame_type == .skip_progressive;
    }

    pub fn getName(self: *const FrameHeader) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn toFrameDimensions(
        self: FrameHeader,
        metadata: ?*const image_metadata.CodecMetadata,
        is_preview: bool,
    ) frame_dimensions.FrameDimensions {
        var xsize: usize = 0;
        var ysize: usize = 0;

        if (metadata) |md| {
            if (is_preview) {
                xsize = md.m.preview_size.xsize();
                ysize = md.m.preview_size.ysize();
            } else {
                xsize = md.xsize();
                ysize = md.ysize();
            }
        }

        if (self.frame_size.xsize != 0) xsize = self.frame_size.xsize;
        if (self.frame_size.ysize != 0) ysize = self.frame_size.ysize;

        if (self.dc_level != 0) {
            xsize = common.divCeil(xsize, @as(usize, 1) << @intCast(3 * self.dc_level));
            ysize = common.divCeil(ysize, @as(usize, 1) << @intCast(3 * self.dc_level));
        }

        var fd = frame_dimensions.FrameDimensions{};
        fd.set(
            xsize,
            ysize,
            self.group_size_shift,
            self.chroma_subsampling.maxHShift(),
            self.chroma_subsampling.maxVShift(),
            self.encoding == .modular,
            self.upsampling,
        );
        return fd;
    }
};

// ── Tests ──

const testing = std.testing;

test "FrameHeader all default" {
    // AllDefault bit = 1
    var data = [_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const fh = try FrameHeader.readFromBitStream(&br, null, false);
    try testing.expectEqual(FrameEncoding.var_dct, fh.encoding);
    try testing.expectEqual(FrameType.regular_frame, fh.frame_type);
    try testing.expectEqual(@as(u64, 0), fh.flags);
    try testing.expectEqual(ColorTransform.xyb, fh.color_transform);
    try testing.expect(fh.is_last);
}

test "FrameType encoding" {
    // AllDefault=0, FrameType selector=01 -> Val(1) = dc_frame
    // encoding bool=0 (VarDCT), flags U64 selector=00 -> 0
    // xyb_encoded=true -> color_transform=xyb (no bits read)
    // no chroma_subsampling (not ycbcr)
    // not use_dc_frame -> upsampling read: selector=00 -> Val(1)
    // not modular -> no group_size_shift
    // VarDCT+XYB -> x_qm=3bits, b_qm=3bits
    // not reference_only -> passes read (single pass default: selector=00 -> Val(1))
    // dc_frame -> dc_level: selector=00 -> Val(1)
    // dc_frame -> no custom_size_or_origin
    // not regular/skip_progressive -> is_last=false
    // dc_frame -> no save_as_reference
    // dc_frame -> save_before_color_transform=true
    // name: selector=00 -> Val(0) (empty)
    // loop_filter: all_default=1
    // extensions: U64 selector=00 -> 0
    //
    // Bits in order:
    // 0: AllDefault=0
    // 1-2: FrameType selector=01
    // 3: encoding=0 (VarDCT)
    // 4-5: flags U64 selector=00
    // (xyb_encoded -> no color transform bits)
    // (no chroma subsampling)
    // 6-7: upsampling selector=00 -> Val(1)
    // (no extra channel upsampling - no metadata)
    // (not modular: no group_size_shift)
    // 8-10: x_qm_scale = 011 (=3 default)
    // 11-13: b_qm_scale = 010 (=2 default)
    // 14-15: passes num_passes selector=00 -> Val(1)
    // 16-17: dc_level selector=00 -> Val(1)
    // (dc_frame: no custom_size_or_origin, no blending, is_last=false, no save_as_reference)
    // (dc_frame: save_before_color_transform=true, no bit read)
    // 18-19: name length selector=00 -> Val(0)
    // 20: loop_filter all_default=1
    // 21-22: extensions U64 selector=00 -> 0
    //
    // byte0 (bits 0-7): 0_01_0_00_00 = 0b00000010 = 0x02
    // byte1 (bits 8-15): 011_010_00 = 0b00010110 = 0x16
    // Hmm, let me re-lay this out...
    // bit0=0 (AllDefault)
    // bit1-2=01 (FrameType sel)
    // bit3=0 (encoding)
    // bit4-5=00 (flags sel)
    // bit6-7=00 (upsampling sel)
    // byte0 = 0b00000010 = 0x02
    //
    // bit8-10=011 (x_qm=3)
    // bit11-13=010 (b_qm=2)
    // bit14-15=00 (passes sel)
    // byte1: 011_010_00 -> bit8=1,bit9=1,bit10=0,bit11=0,bit12=1,bit13=0,bit14=0,bit15=0 = 0b00010011 ... hmm
    // Actually byte1 = bits[8..15]: bit8=LSB
    // x_qm 3 bits: bit8=bit0_of_3=1, bit9=bit1_of_3=1, bit10=bit2_of_3=0
    // b_qm 3 bits: bit11=bit0_of_2=0, bit12=bit1_of_2=1, bit13=bit2_of_2=0
    // passes sel: bit14=0, bit15=0
    // byte1 = 1|(1<<1)|(0<<2)|(0<<3)|(1<<4)|(0<<5)|(0<<6)|(0<<7) = 0b00010011 = 0x13
    //
    // bit16-17=00 (dc_level sel -> Val(1))
    // bit18-19=00 (name length sel -> Val(0))
    // bit20=1 (loop_filter all_default)
    // bit21-22=00 (extensions sel)
    // byte2 = 0|(0<<1)|(0<<2)|(0<<3)|(1<<4)|(0<<5)|(0<<6)|(0<<7) = 0b00010000 = 0x10
    var data = [_]u8{ 0x02, 0x13, 0x10, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const fh = try FrameHeader.readFromBitStream(&br, null, false);
    try testing.expectEqual(FrameType.dc_frame, fh.frame_type);
    try testing.expectEqual(FrameEncoding.var_dct, fh.encoding);
    try testing.expectEqual(@as(u32, 1), fh.dc_level);
    try testing.expect(!fh.is_last);
    try testing.expect(fh.save_before_color_transform);
}

test "BlendingInfo replace default" {
    // BlendMode selector=00 -> Val(0) = replace, no other fields
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const bi = try BlendingInfo.readFromBitStream(&br, 0, false);
    try testing.expectEqual(BlendMode.replace, bi.mode);
}

test "Passes single pass default" {
    // num_passes selector=00 -> Val(1)
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const p = try Passes.readFromBitStream(&br);
    try testing.expectEqual(@as(u32, 1), p.num_passes);
}

test "YCbCrChromaSubsampling 444" {
    // All channel_modes = 0: 6 bits all zero
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const cs = YCbCrChromaSubsampling.readFromBitStream(&br);
    try testing.expect(cs.is444());
    try testing.expectEqual(@as(u8, 0), cs.maxHShift());
    try testing.expectEqual(@as(u8, 0), cs.maxVShift());
}

test "AnimationFrame no animation" {
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const af = AnimationFrame.readFromBitStream(&br, false, false);
    try testing.expectEqual(@as(u32, 0), af.duration);
    try testing.expectEqual(@as(u32, 0), af.timecode);
}

test "AnimationFrame with duration" {
    // have_animation=true, have_timecodes=false
    // duration: selector=00 -> Val(0)
    var data = [_]u8{ 0x00, 0, 0, 0, 0, 0, 0, 0 };
    var br = BitReader.init(&data);
    const af = AnimationFrame.readFromBitStream(&br, true, false);
    try testing.expectEqual(@as(u32, 0), af.duration);
}

test "FrameHeader canBeReferenced" {
    var fh = FrameHeader{};
    // Default: is_last=true -> cannot be referenced
    try testing.expect(!fh.canBeReferenced());

    fh.is_last = false;
    fh.animation_frame.duration = 0;
    // is_last=false, not dc_frame, duration=0 -> can be referenced
    try testing.expect(fh.canBeReferenced());
}

test "pack_signed roundtrip" {
    try testing.expectEqual(@as(i32, 0), pack_signed.unpackSigned(pack_signed.packSigned(0)));
    try testing.expectEqual(@as(i32, -42), pack_signed.unpackSigned(pack_signed.packSigned(-42)));
    try testing.expectEqual(@as(i32, 42), pack_signed.unpackSigned(pack_signed.packSigned(42)));
}
