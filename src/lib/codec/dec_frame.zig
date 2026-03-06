// Frame-level decoding: TOC, section dispatch, modular frame decoder.
// Transliterated from lib/jxl/dec_frame.cc, lib/jxl/dec_modular.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const common = @import("../base/common.zig");
const fc = @import("field_coders.zig");
const frame_header_mod = @import("frame_header.zig");
const FrameHeader = frame_header_mod.FrameHeader;
const frame_dimensions = @import("frame_dimensions.zig");
const FrameDimensions = frame_dimensions.FrameDimensions;
const image_metadata = @import("image_metadata.zig");
const CodecMetadata = image_metadata.CodecMetadata;
const toc = @import("toc.zig");
const TocEntry = toc.TocEntry;

// Modular decoding imports
const dec_ma = @import("../modular/dec_ma.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const ANSCode = dec_ans.ANSCode;
const encoding = @import("../modular/encoding.zig");
const GroupHeader = encoding.GroupHeader;
const modular_image = @import("../modular/modular_image.zig");
const Channel = modular_image.Channel;
const Image = modular_image.Image;
const options_mod = @import("../modular/options.zig");
const ModularOptions = options_mod.ModularOptions;
const transform_mod = @import("../modular/transform.zig");

// ── ModularStreamId ──

pub const ModularStreamKind = enum {
    global_data,
    var_dct_dc,
    modular_dc,
    ac_metadata,
    quant_table,
    modular_ac,
};

const kNumQuantTables: usize = 17; // DequantMatrices::kNum in C++

pub const ModularStreamId = struct {
    kind: ModularStreamKind = .global_data,
    quant_table_id: usize = 0,
    group_id: usize = 0,
    pass_id: usize = 0,

    pub fn id(self: ModularStreamId, frame_dim: FrameDimensions) usize {
        return switch (self.kind) {
            .global_data => 0,
            .var_dct_dc => 1 + self.group_id,
            .modular_dc => 1 + frame_dim.num_dc_groups + self.group_id,
            .ac_metadata => 1 + 2 * frame_dim.num_dc_groups + self.group_id,
            .quant_table => 1 + 3 * frame_dim.num_dc_groups + self.quant_table_id,
            .modular_ac => 1 + 3 * frame_dim.num_dc_groups + kNumQuantTables +
                frame_dim.num_groups * self.pass_id + self.group_id,
        };
    }

    pub fn global() ModularStreamId {
        return .{ .kind = .global_data };
    }

    pub fn modularDC(group_id: usize) ModularStreamId {
        return .{ .kind = .modular_dc, .group_id = group_id };
    }

    pub fn modularAC(group_id: usize, pass_id: usize) ModularStreamId {
        return .{ .kind = .modular_ac, .group_id = group_id, .pass_id = pass_id };
    }
};

// ── ModularFrameDecoder ──

pub const ModularFrameDecoder = struct {
    frame_dim: FrameDimensions = .{},
    full_image: Image,
    global_header: GroupHeader = .{},
    tree: dec_ma.Tree,
    code: ANSCode,
    context_map: []u8 = &.{},
    has_tree: bool = false,
    have_something: bool = false,
    do_color: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModularFrameDecoder {
        return .{
            .full_image = Image{
                .channels = std.ArrayList(Channel).init(allocator),
                .transforms = std.ArrayList(transform_mod.Transform).init(allocator),
                .allocator = allocator,
            },
            .tree = dec_ma.Tree.init(allocator),
            .code = ANSCode.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModularFrameDecoder) void {
        self.full_image.deinit();
        self.global_header.deinit();
        self.tree.deinit();
        self.code.deinit();
        if (self.context_map.len > 0) {
            self.allocator.free(self.context_map);
            self.context_map = &.{};
        }
    }

    pub fn initFrame(self: *ModularFrameDecoder, new_frame_dim: FrameDimensions) void {
        self.frame_dim = new_frame_dim;
    }

    /// Decode global modular info: tree, histograms, and global modular image.
    pub fn decodeGlobalInfo(
        self: *ModularFrameDecoder,
        br: *BitReader,
        frame_header: *const FrameHeader,
        metadata: *const CodecMetadata,
    ) JxlError!void {
        const decode_color = frame_header.encoding == .modular;
        const is_gray = metadata.m.color_encoding.color_space == .gray;
        var nb_chans: usize = 3;
        if (is_gray and frame_header.color_transform == .none) {
            nb_chans = 1;
        }
        self.do_color = decode_color;
        const nb_extra = metadata.m.num_extra_channels;
        if (!decode_color) nb_chans = 0;

        // Read optional global tree
        const has_tree_bit = br.readBits(1);
        if (has_tree_bit == 1) {
            const tree_size_limit: u32 = @intCast(@min(
                @as(u64, 1) << 22,
                1024 + @as(u64, self.frame_dim.xsize) * @as(u64, self.frame_dim.ysize) *
                    @as(u64, nb_chans + nb_extra) / 16,
            ));
            try dec_ma.decodeTree(self.allocator, br, &self.tree, tree_size_limit);

            self.context_map = try dec_ans.decodeHistograms(
                self.allocator,
                br,
                (self.tree.items.len + 1) / 2,
                &self.code,
            );
            self.has_tree = true;
        }

        // Create full-image modular representation
        self.full_image.deinit();
        self.full_image = try Image.create(
            self.allocator,
            self.frame_dim.xsize,
            self.frame_dim.ysize,
            metadata.m.bit_depth.bits_per_sample,
            nb_chans + nb_extra,
        );

        // Set up channel subsampling for YCbCr
        if (frame_header.color_transform == .ycbcr) {
            for (0..nb_chans) |c| {
                var ch = &self.full_image.channels.items[c];
                ch.hshift = @intCast(frame_header.chroma_subsampling.hShift(@intCast(c)));
                ch.vshift = @intCast(frame_header.chroma_subsampling.vShift(@intCast(c)));
                const xsize_shifted = common.divCeil(self.frame_dim.xsize, @as(usize, 1) << @intCast(ch.hshift));
                const ysize_shifted = common.divCeil(self.frame_dim.ysize, @as(usize, 1) << @intCast(ch.vshift));
                _ = xsize_shifted;
                _ = ysize_shifted;
                // TODO: shrink channel to shifted size
            }
        }

        // Decode global modular image
        const global_stream_id = ModularStreamId.global().id(self.frame_dim);
        var opts = ModularOptions{
            .max_chan_size = self.frame_dim.grp_dim,
            .group_dim = self.frame_dim.grp_dim,
        };

        const tree_ptr: ?[]const dec_ma.PropertyDecisionNode = if (self.has_tree) self.tree.items else null;
        const code_ptr: ?*const ANSCode = if (self.has_tree) &self.code else null;
        const ctx_map_ptr: ?[]const u8 = if (self.has_tree) self.context_map else null;

        try encoding.modularGenericDecompress(
            br,
            &self.full_image,
            global_stream_id,
            &opts,
            false, // don't undo transforms yet
            tree_ptr,
            code_ptr,
            ctx_map_ptr,
            self.allocator,
        );

        // Check if any channels fit within group size
        self.have_something = false;
        for (0..self.full_image.channels.items.len) |c| {
            const ch = &self.full_image.channels.items[c];
            if (c >= self.full_image.nb_meta_channels and
                ch.w <= self.frame_dim.grp_dim and
                ch.h <= self.frame_dim.grp_dim)
            {
                self.have_something = true;
            }
        }
    }

    /// Decode a modular group (DC or AC) from the bitstream.
    pub fn decodeGroup(
        self: *ModularFrameDecoder,
        br: *BitReader,
        group_id: usize,
        pass_id: usize,
        is_dc: bool,
    ) JxlError!void {
        const stream = if (is_dc)
            ModularStreamId.modularDC(group_id)
        else
            ModularStreamId.modularAC(group_id, pass_id);

        const gx = group_id % self.frame_dim.xsize_groups;
        const gy = group_id / self.frame_dim.xsize_groups;
        const x0 = gx * self.frame_dim.grp_dim;
        const y0 = gy * self.frame_dim.grp_dim;
        const xsize = @min(self.frame_dim.grp_dim, if (self.frame_dim.xsize > x0) self.frame_dim.xsize - x0 else 0);
        const ysize = @min(self.frame_dim.grp_dim, if (self.frame_dim.ysize > y0) self.frame_dim.ysize - y0 else 0);

        if (xsize == 0 or ysize == 0) return;

        // Create per-group image
        var gi = try Image.create(self.allocator, xsize, ysize, self.full_image.bitdepth, 0);
        defer gi.deinit();

        // Find channels that need per-group decoding
        var c = self.full_image.nb_meta_channels;
        while (c < self.full_image.channels.items.len) : (c += 1) {
            const fch = &self.full_image.channels.items[c];
            if (fch.w <= self.frame_dim.grp_dim and fch.h <= self.frame_dim.grp_dim) break;
        }
        const beginc = c;

        while (c < self.full_image.channels.items.len) : (c += 1) {
            const fch = &self.full_image.channels.items[c];
            const rw = if (fch.hshift >= 0) xsize >> @intCast(fch.hshift) else xsize;
            const rh = if (fch.vshift >= 0) ysize >> @intCast(fch.vshift) else ysize;
            if (rw == 0 or rh == 0) continue;
            var gc = try Channel.create(self.allocator, rw, rh, fch.hshift, fch.vshift);
            _ = &gc;
            try gi.channels.append(gc);
        }

        if (gi.channels.items.len == 0) return;

        var opts = ModularOptions{};
        const tree_ptr: ?[]const dec_ma.PropertyDecisionNode = if (self.has_tree) self.tree.items else null;
        const code_ptr: ?*const ANSCode = if (self.has_tree) &self.code else null;
        const ctx_map_ptr: ?[]const u8 = if (self.has_tree) self.context_map else null;

        try encoding.modularGenericDecompress(
            br,
            &gi,
            stream.id(self.frame_dim),
            &opts,
            true, // undo transforms
            tree_ptr,
            code_ptr,
            ctx_map_ptr,
            self.allocator,
        );

        // Copy decoded data back to full_image
        var gi_c: usize = 0;
        c = beginc;
        while (c < self.full_image.channels.items.len and gi_c < gi.channels.items.len) : (c += 1) {
            const fch = &self.full_image.channels.items[c];
            const gch = &gi.channels.items[gi_c];
            const rx0 = if (fch.hshift >= 0) x0 >> @intCast(fch.hshift) else x0;
            const ry0 = if (fch.vshift >= 0) y0 >> @intCast(fch.vshift) else y0;

            for (0..gch.h) |y| {
                const src = gch.rowConst(y);
                const dst_y = ry0 + y;
                if (dst_y >= fch.h) break;
                const dst = fch.row(dst_y);
                const copy_w = @min(gch.w, if (fch.w > rx0) fch.w - rx0 else 0);
                if (copy_w > 0) {
                    @memcpy(dst[rx0 .. rx0 + copy_w], src[0..copy_w]);
                }
            }
            gi_c += 1;
        }
    }

    /// Undo transforms on the full image (called after all groups are decoded).
    pub fn finalizeDecoding(self: *ModularFrameDecoder) JxlError!void {
        try transform_mod.undoTransforms(&self.full_image, &self.global_header.wp_header);
    }
};

// ── FrameDecoder: top-level frame decode orchestration ──

pub const FrameDecoder = struct {
    frame_header: FrameHeader = .{},
    frame_dim: FrameDimensions = .{},
    toc_entries: []TocEntry = &.{},
    modular_decoder: ModularFrameDecoder,
    metadata: *const CodecMetadata,
    decoded_dc_global: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, metadata: *const CodecMetadata) FrameDecoder {
        return .{
            .modular_decoder = ModularFrameDecoder.init(allocator),
            .metadata = metadata,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameDecoder) void {
        self.modular_decoder.deinit();
        if (self.toc_entries.len > 0) {
            self.allocator.free(self.toc_entries);
            self.toc_entries = &.{};
        }
    }

    /// Read frame header and TOC.
    pub fn initFrame(self: *FrameDecoder, br: *BitReader) JxlError!void {
        self.frame_header = try FrameHeader.readFromBitStream(br, self.metadata);
        self.frame_dim = self.frame_header.toFrameDimensions(self.metadata, false);
        self.modular_decoder.initFrame(self.frame_dim);

        const num_passes = self.frame_header.passes.num_passes;
        const num_groups = self.frame_dim.num_groups;
        const num_toc = toc.numTocEntries(num_groups, self.frame_dim.num_dc_groups, num_passes);

        self.toc_entries = try toc.readToc(self.allocator, num_toc, br);
    }

    /// Get the byte offset where section data begins (after header + TOC).
    pub fn headerBytes(_: *const FrameDecoder, br: *const BitReader) usize {
        return br.totalBitsConsumed() / 8;
    }

    /// Process DC Global section (section ID 0).
    pub fn processDCGlobal(self: *FrameDecoder, br: *BitReader) JxlError!void {
        // For modular frames: decode global modular info
        if (self.frame_header.encoding == .modular) {
            try self.modular_decoder.decodeGlobalInfo(br, &self.frame_header, self.metadata);
        }
        self.decoded_dc_global = true;
    }

    /// Decode entire frame from a contiguous byte buffer.
    /// This is the simple single-pass entry point.
    pub fn decodeFrame(self: *FrameDecoder, data: []const u8) JxlError!void {
        // Read frame header + TOC
        var header_br = BitReader.init(data);
        try self.initFrame(&header_br);
        const header_byte_offset = self.headerBytes(&header_br);
        header_br.close() catch {};

        const num_toc = self.toc_entries.len;

        if (num_toc == 1) {
            // Single-section frame (common for small lossless images)
            const section_data = data[header_byte_offset..];
            var section_br = BitReader.init(section_data);
            try self.processDCGlobal(&section_br);
            section_br.close() catch {};
        } else {
            // Multi-section frame: compute offsets and process in order
            var pos = header_byte_offset;

            // Find DC Global section (id=0) and process it first
            for (0..num_toc) |i| {
                if (self.toc_entries[i].id == 0) {
                    const section_data = data[pos..];
                    var section_br = BitReader.init(section_data);
                    try self.processDCGlobal(&section_br);
                    section_br.close() catch {};
                    break;
                }
                pos += self.toc_entries[i].size;
            }

            // Process DC groups
            pos = header_byte_offset;
            for (0..num_toc) |i| {
                const entry = self.toc_entries[i];
                if (entry.id >= 1 and entry.id <= self.frame_dim.num_dc_groups) {
                    const group_id = entry.id - 1;
                    const section_data = data[pos .. pos + entry.size];
                    var section_br = BitReader.init(section_data);
                    self.modular_decoder.decodeGroup(&section_br, group_id, 0, true) catch {};
                    section_br.close() catch {};
                }
                pos += entry.size;
            }

            // Process AC groups
            const ac_global_index = 1 + self.frame_dim.num_dc_groups;
            pos = header_byte_offset;
            for (0..num_toc) |i| {
                const entry = self.toc_entries[i];
                if (entry.id > ac_global_index) {
                    const ac_idx = entry.id - ac_global_index - 1;
                    const group_id = ac_idx % self.frame_dim.num_groups;
                    const pass_id = ac_idx / self.frame_dim.num_groups;
                    const section_data = data[pos .. pos + entry.size];
                    var section_br = BitReader.init(section_data);
                    self.modular_decoder.decodeGroup(&section_br, group_id, pass_id, false) catch {};
                    section_br.close() catch {};
                }
                pos += entry.size;
            }
        }

        // Finalize: undo transforms on full image
        try self.modular_decoder.finalizeDecoding();
    }

    /// Get the decoded image (after decodeFrame).
    pub fn getDecodedImage(self: *FrameDecoder) *Image {
        return &self.modular_decoder.full_image;
    }
};

// ── Tests ──

const testing = std.testing;

test "ModularStreamId global" {
    var fd = FrameDimensions{};
    fd.set(100, 100, 1, 0, 0, true, 1);
    const sid = ModularStreamId.global();
    try testing.expectEqual(@as(usize, 0), sid.id(fd));
}

test "ModularStreamId modularDC" {
    var fd = FrameDimensions{};
    fd.set(1024, 1024, 1, 0, 0, true, 1);
    const sid = ModularStreamId.modularDC(0);
    try testing.expectEqual(@as(usize, 1 + fd.num_dc_groups), sid.id(fd));
}

test "ModularStreamId modularAC" {
    var fd = FrameDimensions{};
    fd.set(1024, 1024, 1, 0, 0, true, 1);
    const sid = ModularStreamId.modularAC(2, 0);
    const expected = 1 + 3 * fd.num_dc_groups + kNumQuantTables + 2;
    try testing.expectEqual(expected, sid.id(fd));
}

test "ModularFrameDecoder init/deinit" {
    const allocator = testing.allocator;
    var dec = ModularFrameDecoder.init(allocator);
    defer dec.deinit();
    try testing.expect(!dec.has_tree);
}

test "FrameDecoder init/deinit" {
    const allocator = testing.allocator;
    var metadata = CodecMetadata{};
    var dec = FrameDecoder.init(allocator, &metadata);
    defer dec.deinit();
    try testing.expect(!dec.decoded_dc_global);
}
