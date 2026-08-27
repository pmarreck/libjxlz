// Frame-level decoding: TOC, section dispatch, modular frame decoder.
// Transliterated from lib/jxl/dec_frame.cc, lib/jxl/dec_modular.cc

const std = @import("std");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const unsupported_mod = @import("../base/unsupported.zig");
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
const splines_mod = @import("splines.zig");
const render_mod = @import("render.zig");

// Modular decoding imports
const dec_ma = @import("../modular/dec_ma.zig");
const dec_ans = @import("../entropy/dec_ans.zig");
const ANSCode = dec_ans.ANSCode;
const encoding = @import("../modular/encoding.zig");
const GroupHeader = encoding.GroupHeader;
const ReaderStrategy = encoding.ReaderStrategy;
const modular_image = @import("../modular/modular_image.zig");
const Channel = modular_image.Channel;
const Image = modular_image.Image;
const options_mod = @import("../modular/options.zig");
const ModularOptions = options_mod.ModularOptions;
const transform_mod = @import("../modular/transform.zig");
const float_utils = @import("../base/float.zig");

const SectionLayout = struct {
    offsets: []u64,
    total_size: u64,
};

/// Computes per-section byte offsets and validates that TOC-declared section sizes
/// stay within the provided frame buffer before any slice is taken.
fn computeSectionLayout(
    allocator: std.mem.Allocator,
    header_byte_offset: usize,
    data_len: usize,
    toc_entries: []const TocEntry,
) JxlError!SectionLayout {
    if (header_byte_offset > data_len) return error.GenericError;

    const layout = try toc.computeGroupOffsets(allocator, toc_entries);
    errdefer allocator.free(layout.offsets);

    const payload_len: u64 = @intCast(data_len - header_byte_offset);
    if (layout.total_size > payload_len) return error.GenericError;

    var i: usize = 0;
    while (i < toc_entries.len) : (i += 1) {
        const end = common.safeAdd(layout.offsets[i], toc_entries[i].size) orelse return error.GenericError;
        if (end > payload_len) return error.GenericError;
    }

    return .{
        .offsets = layout.offsets,
        .total_size = layout.total_size,
    };
}

fn sectionData(
    data: []const u8,
    header_byte_offset: usize,
    relative_offset: u64,
    size: u32,
) JxlError![]const u8 {
    const start_u64 = common.safeAdd(@as(u64, @intCast(header_byte_offset)), relative_offset) orelse return error.GenericError;
    const end_u64 = common.safeAdd(start_u64, size) orelse return error.GenericError;
    const start: usize = @intCast(start_u64);
    const end: usize = @intCast(end_u64);
    if (end > data.len) return error.GenericError;
    return data[start..end];
}

/// Computes the total byte span of one encoded frame by parsing its header and
/// TOC, then summing the declared section payload sizes. This is the minimal
/// primitive needed to step through animated codestreams frame-by-frame.
pub fn frameByteCount(
	allocator: std.mem.Allocator,
	metadata: *const CodecMetadata,
	data: []const u8,
) JxlError!usize {
	var frame_dec = FrameDecoder.init(allocator, metadata);
	defer frame_dec.deinit();

	var header_br = BitReader.init(data);
	try frame_dec.initFrame(&header_br);
	const header_byte_offset = frame_dec.headerBytes(&header_br);
	try header_br.close();

	const layout = try computeSectionLayout(allocator, header_byte_offset, data.len, frame_dec.toc_entries);
	defer allocator.free(layout.offsets);

	const total_u64 = common.safeAdd(@as(u64, @intCast(header_byte_offset)), layout.total_size) orelse return error.GenericError;
	if (total_u64 > data.len) return error.GenericError;
	return @intCast(total_u64);
}


/// Resizes the color channels for modular YCbCr so the in-memory image matches
/// the chroma-subsampled geometry expected by per-group decoding and transforms.
fn applyYCbCrChromaSubsampling(
    allocator: std.mem.Allocator,
    image: *Image,
    frame_dim: FrameDimensions,
    chroma_subsampling: frame_header_mod.YCbCrChromaSubsampling,
    nb_chans: usize,
) JxlError!void {
    for (0..nb_chans) |c| {
        const hshift: i32 = @intCast(chroma_subsampling.hShift(@intCast(c)));
        const vshift: i32 = @intCast(chroma_subsampling.vShift(@intCast(c)));
        const width = common.subsampledSize(frame_dim.xsize, hshift);
        const height = common.subsampledSize(frame_dim.ysize, vshift);

        var ch = &image.channels.items[c];
        ch.hshift = hshift;
        ch.vshift = vshift;
        if (ch.w == width and ch.h == height and ch.row_stride == width) continue;

        ch.deinit();
        ch.* = try Channel.create(allocator, width, height, hshift, vshift);
    }
}

/// Applies `ExtraChannelInfo.dim_shift` to the in-memory modular image so
/// subsampled alpha/depth planes use their encoded reduced geometry before
/// ANS token decode and per-group tiling begin.
fn applyExtraChannelDimShift(
	allocator: std.mem.Allocator,
	image: *Image,
	frame_dim: FrameDimensions,
	metadata: *const CodecMetadata,
	color_channels: usize,
) JxlError!void {
	for (0..metadata.m.num_extra_channels) |extra_index| {
		const channel_index = color_channels + extra_index;
		if (channel_index >= image.channels.items.len) return error.GenericError;

		const shift: i32 = @intCast(metadata.m.extra_channel_info[extra_index].dim_shift);
		const width = common.subsampledSize(frame_dim.xsize, shift);
		const height = common.subsampledSize(frame_dim.ysize, shift);

		var ch = &image.channels.items[channel_index];
		ch.hshift = shift;
		ch.vshift = shift;
		if (ch.w == width and ch.h == height and ch.row_stride == width) continue;

		ch.deinit();
		ch.* = try Channel.create(allocator, width, height, shift, shift);
	}
}

// ── DequantMatrices ──
// Transliterated from lib/jxl/quant_weights.cc DequantMatrices::{DecodeDC,Decode}

/// C++ QuantEncoding::Mode. Values are bitstream ABI: 3-bit kLog2NumQuantModes.
pub const QuantMode = enum(u8) {
	library = 0,
	identity = 1,
	dct2 = 2,
	dct4 = 3,
	dct4x8 = 4,
	afv = 5,
	dct = 6,
	raw = 7,
};

/// Per-table encoding of an AC dequant matrix. Library mode is the default
/// cjxl path; the other modes carry custom weights read by `decode`.
pub const DctQuantWeightParams = struct {
	num_distance_bands: u8 = 0,
	distance_bands: [3][kMaxDistanceBands]f32 = @splat(@splat(0)),
};

pub const QuantEncoding = struct {
	mode: QuantMode = .library,
	predefined: u8 = 0,
	idweights: [3][3]f32 = @splat(@splat(0)),
	dct2weights: [3][6]f32 = @splat(@splat(0)),
	dct4multipliers: [3][2]f32 = @splat(@splat(0)),
	dct4x8multipliers: [3]f32 = @splat(0),
	afv_weights: [3][9]f32 = @splat(@splat(0)),
	dct_params: DctQuantWeightParams = .{},
	dct_params_afv_4x4: DctQuantWeightParams = .{},
};

const kNumQuantTables: usize = 17; // DequantMatrices::kNum in C++
const kRequiredSizeX = [_]u8{ 1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16 };
const kRequiredSizeY = [_]u8{ 1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32 };
const kAlmostZero: f32 = 1.0e-8;
const kLog2MaxDistanceBands: usize = 4;
const kMaxDistanceBands: usize = 1 + (1 << kLog2MaxDistanceBands);

comptime {
	if (kRequiredSizeX.len != kNumQuantTables or kRequiredSizeY.len != kNumQuantTables) {
		@compileError("quant-table size arrays must match kNumQuantTables");
	}
}

fn requiredSize(table_index: usize) usize {
	return @as(usize, kRequiredSizeX[table_index]) * @as(usize, kRequiredSizeY[table_index]);
}

fn readScaledF16(br: *BitReader) JxlError!f32 {
	const val = try fc.F16Coder.read(br);
	if (@abs(val) < kAlmostZero) return error.GenericError;
	return val * 64.0;
}

fn readNonzeroF16(br: *BitReader) JxlError!f32 {
	const val = try fc.F16Coder.read(br);
	if (@abs(val) < kAlmostZero) return error.GenericError;
	return val;
}

fn decodeDctParams(br: *BitReader) JxlError!DctQuantWeightParams {
	var params = DctQuantWeightParams{};
	params.num_distance_bands = @intCast(br.readBits(kLog2MaxDistanceBands) + 1);
	for (0..3) |c| {
		for (0..params.num_distance_bands) |j| {
			params.distance_bands[c][j] = try fc.F16Coder.read(br);
		}
		if (params.distance_bands[c][0] < kAlmostZero) return error.GenericError;
		params.distance_bands[c][0] *= 64.0;
	}
	return params;
}

pub const DequantMatrices = struct {
	dc_quant: [3]f32 = .{ 1.0 / 4096.0, 1.0 / 512.0, 1.0 / 256.0 }, // defaults from C++
	encodings: [kNumQuantTables]QuantEncoding = [_]QuantEncoding{.{}} ** kNumQuantTables,

	/// Read DC quantization parameters from the bitstream.
	/// Must be called before DecodeGlobalInfo, matching C++ ProcessDCGlobal flow.
	pub fn decodeDC(self: *DequantMatrices, br: *BitReader) JxlError!void {
		const all_default = br.readBits(1);
		if (all_default == 0) {
			for (0..3) |c| {
				const bits16: u16 = @intCast(br.readBits(16));
				const biased_exp = (bits16 >> 10) & 0x1F;
				if (biased_exp == 31) return error.GenericError; // infinity/NaN not allowed
				const val = float_utils.loadFloat16(bits16);
				self.dc_quant[c] = val * (1.0 / 128.0);
				if (self.dc_quant[c] < kAlmostZero) return error.GenericError;
			}
		}
	}

	/// Read the 17 AC dequant table encodings from the AC-global section.
	/// C++ DequantMatrices::Decode. all_default=1 installs Library<0> for every
	/// table and consumes one bit — the path default cjxl lossy encodes take.
	pub fn decode(self: *DequantMatrices, br: *BitReader) JxlError!void {
		const all_default = br.readBits(1);
		if (all_default != 0) {
			self.encodings = [_]QuantEncoding{.{ .mode = .library, .predefined = 0 }} ** kNumQuantTables;
			return;
		}
		for (0..kNumQuantTables) |i| {
			const mode_bits: u8 = @intCast(br.readBits(3));
			const mode: QuantMode = @enumFromInt(mode_bits);
			switch (mode) {
				.library => {
					// kCeilLog2NumPredefinedTables == 0: no extra bits.
					self.encodings[i] = .{ .mode = .library, .predefined = 0 };
				},
				.identity => {
					if (requiredSize(i) != 1) return error.GenericError;
					var weights: [3][3]f32 = undefined;
					for (0..3) |c| {
						for (0..3) |j| {
							weights[c][j] = try readScaledF16(br);
						}
					}
					self.encodings[i] = .{ .mode = .identity, .idweights = weights };
				},
				.dct2 => {
					if (requiredSize(i) != 1) return error.GenericError;
					var weights: [3][6]f32 = undefined;
					for (0..3) |c| {
						for (0..6) |j| {
							weights[c][j] = try readScaledF16(br);
						}
					}
					self.encodings[i] = .{ .mode = .dct2, .dct2weights = weights };
				},
				.dct => {
					self.encodings[i] = .{ .mode = .dct, .dct_params = try decodeDctParams(br) };
				},
				.dct4 => {
					if (requiredSize(i) != 1) return error.GenericError;
					var multipliers: [3][2]f32 = undefined;
					for (0..3) |c| {
						for (0..2) |j| {
							multipliers[c][j] = try readNonzeroF16(br);
						}
					}
					self.encodings[i] = .{
						.mode = .dct4,
						.dct4multipliers = multipliers,
						.dct_params = try decodeDctParams(br),
					};
				},
				.dct4x8 => {
					if (requiredSize(i) != 1) return error.GenericError;
					var multipliers: [3]f32 = undefined;
					for (0..3) |c| {
						multipliers[c] = try readNonzeroF16(br);
					}
					self.encodings[i] = .{
						.mode = .dct4x8,
						.dct4x8multipliers = multipliers,
						.dct_params = try decodeDctParams(br),
					};
				},
				.afv => {
					if (requiredSize(i) != 1) return error.GenericError;
					var weights: [3][9]f32 = undefined;
					for (0..3) |c| {
						for (0..9) |j| {
							weights[c][j] = try fc.F16Coder.read(br);
						}
						for (0..6) |j| {
							weights[c][j] *= 64.0;
						}
					}
					self.encodings[i] = .{
						.mode = .afv,
						.afv_weights = weights,
						.dct_params = try decodeDctParams(br),
						.dct_params_afv_4x4 = try decodeDctParams(br),
					};
				},
				.raw => return unsupported_mod.unsupported(.vardct_frame),
			}
		}
	}
};

// ── ModularStreamId ──

pub const ModularStreamKind = enum {
    global_data,
    var_dct_dc,
    modular_dc,
    ac_metadata,
    quant_table,
    modular_ac,
};

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

/// Returns the extent of a full-image channel covered by one raw group rect.
/// The group is shifted first, then clamped to the channel, matching libjxl's
/// `Rect` construction for differently-sized subsampled channels at an edge.
fn groupChannelExtent(
    full_size: usize,
    group_start: usize,
    group_size: usize,
    shift: i32,
) usize {
	if (shift <= 0) {
		if (group_start >= full_size) return 0;
		return @min(group_size, full_size - group_start);
	}
	if (shift >= @bitSizeOf(usize)) return 0;

	const shifted_start = group_start >> @intCast(shift);
	if (shifted_start >= full_size) return 0;
	const shifted_size = group_size >> @intCast(shift);
	return @min(shifted_size, full_size - shifted_start);
}

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
                .channels = .empty,
                .transforms = .empty,
                .allocator = allocator,
            },
            .tree = .empty,
            .code = ANSCode.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModularFrameDecoder) void {
        self.full_image.deinit();
        self.global_header.deinit();
        self.tree.deinit(self.allocator);
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
    pub fn decodeGlobalInfoWithReaderStrategy(
        self: *ModularFrameDecoder,
        comptime reader_strategy: ReaderStrategy,
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
            @intCast(metadata.m.bit_depth.bits_per_sample),
            nb_chans + nb_extra,
        );

        // Set up channel subsampling for YCbCr
        if (frame_header.color_transform == .ycbcr) {
            try applyYCbCrChromaSubsampling(
                self.allocator,
                &self.full_image,
                self.frame_dim,
                frame_header.chroma_subsampling,
                nb_chans,
            );
        }
        if (nb_extra != 0) {
            try applyExtraChannelDimShift(
                self.allocator,
                &self.full_image,
                self.frame_dim,
                metadata,
                nb_chans,
            );
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

        try encoding.modularGenericDecompressWithReaderStrategy(
            reader_strategy,
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

    /// Decode global modular info using the default hot-path reader strategy.
    pub fn decodeGlobalInfo(
        self: *ModularFrameDecoder,
        br: *BitReader,
        frame_header: *const FrameHeader,
        metadata: *const CodecMetadata,
    ) JxlError!void {
        return self.decodeGlobalInfoWithReaderStrategy(.specialized, br, frame_header, metadata);
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
        if (x0 >= self.frame_dim.xsize or y0 >= self.frame_dim.ysize) return;
        const xsize = self.frame_dim.grp_dim;
        const ysize = self.frame_dim.grp_dim;

        if (xsize == 0 or ysize == 0) return;

        // Create per-group image
        var gi = try Image.create(self.allocator, xsize, ysize, self.full_image.bitdepth, 0);
        defer gi.deinit();

        // Find channels that need per-group decoding.
        // Channels larger than the group dimensions are tiled across sections;
        // small channels are already fully represented in the global image.
        var c = self.full_image.nb_meta_channels;
        while (c < self.full_image.channels.items.len) : (c += 1) {
            const fch = &self.full_image.channels.items[c];
            if (fch.w > self.frame_dim.grp_dim or fch.h > self.frame_dim.grp_dim) break;
        }
        const beginc = c;
        const group_channel_capacity = self.full_image.channels.items.len - beginc;
        try gi.channels.ensureTotalCapacity(self.allocator, group_channel_capacity);

		while (c < self.full_image.channels.items.len) : (c += 1) {
			const fch = &self.full_image.channels.items[c];
			const rw = groupChannelExtent(fch.w, x0, xsize, fch.hshift);
			const rh = groupChannelExtent(fch.h, y0, ysize, fch.vshift);
			if (rw == 0 or rh == 0) continue;
            var gc = try Channel.create(self.allocator, rw, rh, fch.hshift, fch.vshift);
            _ = &gc;
            try gi.channels.append(self.allocator, gc);
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
            const copy_w = @min(gch.w, if (fch.w > rx0) fch.w - rx0 else 0);
            const copy_h = @min(gch.h, if (fch.h > ry0) fch.h - ry0 else 0);
            if (copy_w == 0 or copy_h == 0) {
                gi_c += 1;
                continue;
            }

            for (0..copy_h) |y| {
                const src = gch.rowConst(y);
                const dst = fch.row(ry0 + y);
                @memcpy(dst[rx0 .. rx0 + copy_w], src[0..copy_w]);
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
    splines: splines_mod.Splines,
    dequant_matrices: DequantMatrices = .{},
    rendered_image: ?render_mod.FloatImage = null,
    metadata: *const CodecMetadata,
    decoded_dc_global: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, metadata: *const CodecMetadata) FrameDecoder {
        return .{
            .modular_decoder = ModularFrameDecoder.init(allocator),
            .splines = splines_mod.Splines.init(allocator),
            .metadata = metadata,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameDecoder) void {
        self.clearRenderedImage();
        self.modular_decoder.deinit();
        self.splines.deinit();
        if (self.toc_entries.len > 0) {
            self.allocator.free(self.toc_entries);
            self.toc_entries = &.{};
        }
    }

    /// Read frame header and TOC.
    pub fn initFrame(self: *FrameDecoder, br: *BitReader) JxlError!void {
        self.frame_header = try FrameHeader.readFromBitStream(br, self.metadata, false);
        self.frame_dim = self.frame_header.toFrameDimensions(self.metadata, false);
        self.modular_decoder.initFrame(self.frame_dim);
        self.splines.clear();
        self.dequant_matrices = .{};
        self.clearRenderedImage();

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
    /// Matches C++ FrameDecoder::ProcessDCGlobal: patches/splines/noise (conditional),
    /// then DecodeDC (unconditional), then DecodeGlobalInfo.
    pub fn processDCGlobalWithReaderStrategy(
        self: *FrameDecoder,
        comptime reader_strategy: ReaderStrategy,
        br: *BitReader,
    ) JxlError!void {
        const unsupported_flags = frame_header_mod.FrameFlags.noise |
            frame_header_mod.FrameFlags.patches;
        if ((self.frame_header.flags & unsupported_flags) != 0) {
            return unsupported_mod.unsupported(
                if ((self.frame_header.flags & frame_header_mod.FrameFlags.patches) != 0) .patches else .noise,
            );
        }

        if ((self.frame_header.flags & frame_header_mod.FrameFlags.splines) != 0) {
            try self.splines.decode(br, self.frame_dim.xsize * self.frame_dim.ysize);
        }

        // DequantMatrices::DecodeDC — always called, even for modular frames
        self.dequant_matrices = .{};
        try self.dequant_matrices.decodeDC(br);

        // For modular frames: decode global modular info
        if (self.frame_header.encoding == .modular) {
            try self.modular_decoder.decodeGlobalInfoWithReaderStrategy(reader_strategy, br, &self.frame_header, self.metadata);
        }
        self.decoded_dc_global = true;
    }

    /// Process the DC global section using the default hot-path reader strategy.
    pub fn processDCGlobal(self: *FrameDecoder, br: *BitReader) JxlError!void {
        return self.processDCGlobalWithReaderStrategy(.specialized, br);
    }

    /// Decode entire frame from a contiguous byte buffer.
    /// This is the simple single-pass entry point.
    pub fn decodeFrameWithReaderStrategy(
        self: *FrameDecoder,
        comptime reader_strategy: ReaderStrategy,
        data: []const u8,
    ) JxlError!void {
        // Read frame header + TOC
        var header_br = BitReader.init(data);
        try self.initFrame(&header_br);
        const header_byte_offset = self.headerBytes(&header_br);
        try header_br.close();

        if (self.frame_header.encoding != .modular) {
            return unsupported_mod.unsupported(.vardct_frame);
        }

        const layout = try computeSectionLayout(self.allocator, header_byte_offset, data.len, self.toc_entries);
        defer self.allocator.free(layout.offsets);

        var found_dc_global = false;
        for (self.toc_entries, 0..) |entry, i| {
            if (entry.id != 0) continue;
            if (entry.size == 0) continue;

            const data_slice = try sectionData(data, header_byte_offset, layout.offsets[i], entry.size);
            var section_br = BitReader.init(data_slice);
            try self.processDCGlobalWithReaderStrategy(reader_strategy, &section_br);
            try section_br.close();
            found_dc_global = true;
            break;
        }
        if (!found_dc_global) return error.GenericError;

        for (self.toc_entries, 0..) |entry, i| {
            if (entry.id < 1 or entry.id > self.frame_dim.num_dc_groups) continue;
            if (entry.size == 0) continue;

            const group_id = entry.id - 1;
            const data_slice = try sectionData(data, header_byte_offset, layout.offsets[i], entry.size);
            var section_br = BitReader.init(data_slice);
            try self.modular_decoder.decodeGroup(&section_br, group_id, 0, true);
            try section_br.close();
        }

        const ac_global_index = 1 + self.frame_dim.num_dc_groups;
        for (self.toc_entries, 0..) |entry, i| {
            if (entry.id <= ac_global_index) continue;
            if (entry.size == 0) continue;

			const ac_idx = entry.id - ac_global_index - 1;
			const group_id = ac_idx % self.frame_dim.num_groups;
			const pass_id = ac_idx / self.frame_dim.num_groups;
			const data_slice = try sectionData(data, header_byte_offset, layout.offsets[i], entry.size);
			var section_br = BitReader.init(data_slice);
			try self.modular_decoder.decodeGroup(&section_br, group_id, pass_id, false);
			try section_br.close();
		}

        // Finalize: undo transforms on full image
        try self.modular_decoder.finalizeDecoding();
        try self.renderSplineOverlays();
    }

    /// Decode an entire frame using the default hot-path reader strategy.
    pub fn decodeFrame(self: *FrameDecoder, data: []const u8) JxlError!void {
        return self.decodeFrameWithReaderStrategy(.specialized, data);
    }

    /// Get the decoded image (after decodeFrame).
    pub fn getDecodedImage(self: *FrameDecoder) *Image {
        return &self.modular_decoder.full_image;
    }

    fn clearRenderedImage(self: *FrameDecoder) void {
        if (self.rendered_image) |*image| {
            image.deinit();
            self.rendered_image = null;
        }
    }

    /// Builds the narrow float render output for already-decoded full-resolution
    /// modular color planes and applies parsed spline overlays after transforms.
    pub fn renderSplineOverlays(self: *FrameDecoder) JxlError!void {
        self.clearRenderedImage();
        if (!self.splines.hasAny()) return;
        if (self.modular_decoder.full_image.channels.items.len < 3) return unsupported_mod.unsupported(.color_channel_count);

        try self.splines.initializeDrawCache(self.frame_dim.xsize, self.frame_dim.ysize, .{});
        const use_xyb_lift = self.metadata.m.xyb_encoded or self.frame_header.color_transform == .xyb;
        var rendered = if (use_xyb_lift)
            try render_mod.FloatImage.fromXYBModularImage(
                self.allocator,
                &self.modular_decoder.full_image,
                self.dequant_matrices.dc_quant,
            )
        else
            try render_mod.FloatImage.fromModularImage(
                self.allocator,
                &self.modular_decoder.full_image,
                3,
            );
        errdefer rendered.deinit();
        try rendered.applySplines(&self.splines);
        self.rendered_image = rendered;
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

test "groupChannelExtent clamps shifted edge groups per channel" {
	try testing.expectEqual(@as(usize, 60), groupChannelExtent(316, 512, 256, 1));
	try testing.expectEqual(@as(usize, 30), groupChannelExtent(158, 512, 256, 2));
	try testing.expectEqual(@as(usize, 59), groupChannelExtent(315, 512, 256, 1));
	try testing.expectEqual(@as(usize, 119), groupChannelExtent(631, 512, 256, 0));
	try testing.expectEqual(@as(usize, 0), groupChannelExtent(315, 768, 256, 1));
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

test "computeSectionLayout computes exact offsets" {
    const allocator = testing.allocator;
    const entries = [_]TocEntry{
        .{ .id = 0, .size = 4 },
        .{ .id = 1, .size = 0 },
        .{ .id = 2, .size = 3 },
    };

    const layout = try computeSectionLayout(allocator, 5, 12, &entries);
    defer allocator.free(layout.offsets);

    try testing.expectEqual(@as(u64, 7), layout.total_size);
    try testing.expectEqual(@as(u64, 0), layout.offsets[0]);
    try testing.expectEqual(@as(u64, 4), layout.offsets[1]);
    try testing.expectEqual(@as(u64, 4), layout.offsets[2]);
}

test "computeSectionLayout rejects truncated payload" {
    const allocator = testing.allocator;
    const entries = [_]TocEntry{
        .{ .id = 0, .size = 4 },
        .{ .id = 1, .size = 12 },
    };

    try testing.expectError(error.GenericError, computeSectionLayout(allocator, 5, 16, &entries));
}

test "DequantMatrices.decode all_default consumes one bit and uses library encodings" {
	// C++ DequantMatrices::Decode: a 1-bit all_default flag. When set, every
	// one of the 17 quant tables is QuantEncoding::Library<0>() and no further
	// bits are read. This is the path default cjxl lossy encodes take.
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(@as(usize, 1), br.totalBitsConsumed());
	try testing.expectEqual(@as(usize, kNumQuantTables), matrices.encodings.len);
	for (matrices.encodings) |enc| {
		try testing.expectEqual(QuantMode.library, enc.mode);
		try testing.expectEqual(@as(u8, 0), enc.predefined);
	}
}

test "DequantMatrices.decode custom-flag library tables consume 3 bits each" {
	// all_default=0, then 17 tables each with 3-bit mode=library and no
	// predefined index bits (kCeilLog2NumPredefinedTables == 0).
	var data = [_]u8{0} ** 8;
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(@as(usize, 1 + 3 * kNumQuantTables), br.totalBitsConsumed());
	for (matrices.encodings) |enc| {
		try testing.expectEqual(QuantMode.library, enc.mode);
		try testing.expectEqual(@as(u8, 0), enc.predefined);
	}
}

test "DequantMatrices.decode identity table scales F16 weights by 64" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.identity));
	for (0..9) |_| {
		try writer.write(16, 0x3C00);
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.identity, matrices.encodings[0].mode);
	for (matrices.encodings[0].idweights) |row| {
		for (row) |weight| {
			try testing.expectEqual(@as(f32, 64.0), weight);
		}
	}
	for (matrices.encodings[1..]) |enc| {
		try testing.expectEqual(QuantMode.library, enc.mode);
	}
}

test "DequantMatrices.decode rejects identity mode on a table that is not 1x1" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	// Tables 0-3 are 1x1; table 4 (DCT16X16) is 2x2. Identity is illegal there.
	for (0..4) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.write(3, @intFromEnum(QuantMode.identity));
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try testing.expectError(error.GenericError, matrices.decode(&br));
}

test "DequantMatrices.decode dct2 table scales F16 weights by 64" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.dct2));
	for (0..18) |_| {
		try writer.write(16, 0x3C00);
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.dct2, matrices.encodings[0].mode);
	for (matrices.encodings[0].dct2weights) |row| {
		for (row) |weight| {
			try testing.expectEqual(@as(f32, 64.0), weight);
		}
	}
}

test "DequantMatrices.decode dct params scale the seed band by 64" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.dct));
	try writer.write(4, 0);
	for (0..3) |_| {
		try writer.write(16, 0x3C00);
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.dct, matrices.encodings[0].mode);
	try testing.expectEqual(@as(u8, 1), matrices.encodings[0].dct_params.num_distance_bands);
	for (0..3) |c| {
		try testing.expectEqual(@as(f32, 64.0), matrices.encodings[0].dct_params.distance_bands[c][0]);
	}
}

test "DequantMatrices.decode dct4 multipliers stay unscaled" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.dct4));
	for (0..6) |_| {
		try writer.write(16, 0x3C00);
	}
	try writer.write(4, 0);
	for (0..3) |_| {
		try writer.write(16, 0x3C00);
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.dct4, matrices.encodings[0].mode);
	for (matrices.encodings[0].dct4multipliers) |row| {
		for (row) |mul| {
			try testing.expectEqual(@as(f32, 1.0), mul);
		}
	}
	try testing.expectEqual(@as(f32, 64.0), matrices.encodings[0].dct_params.distance_bands[0][0]);
}

test "DequantMatrices.decode dct4x8 multipliers stay unscaled" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.dct4x8));
	for (0..3) |_| {
		try writer.write(16, 0x3C00);
	}
	try writer.write(4, 0);
	for (0..3) |_| {
		try writer.write(16, 0x3C00);
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.dct4x8, matrices.encodings[0].mode);
	for (matrices.encodings[0].dct4x8multipliers) |mul| {
		try testing.expectEqual(@as(f32, 1.0), mul);
	}
}

test "DequantMatrices.decode afv scales the first six weights of each channel" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.afv));
	for (0..27) |_| {
		try writer.write(16, 0x3C00);
	}
	for (0..2) |_| {
		try writer.write(4, 0);
		for (0..3) |_| {
			try writer.write(16, 0x3C00);
		}
	}
	for (1..kNumQuantTables) |_| {
		try writer.write(3, @intFromEnum(QuantMode.library));
	}
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decode(&br);
	try testing.expectEqual(QuantMode.afv, matrices.encodings[0].mode);
	for (0..3) |c| {
		for (0..6) |j| {
			try testing.expectEqual(@as(f32, 64.0), matrices.encodings[0].afv_weights[c][j]);
		}
		for (6..9) |j| {
			try testing.expectEqual(@as(f32, 1.0), matrices.encodings[0].afv_weights[c][j]);
		}
	}
	try testing.expectEqual(@as(u8, 1), matrices.encodings[0].dct_params.num_distance_bands);
	try testing.expectEqual(@as(u8, 1), matrices.encodings[0].dct_params_afv_4x4.num_distance_bands);
}

test "DequantMatrices.decode raw tables stay unsupported until modular quant tables exist" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const allocator = testing.allocator;
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	try writer.write(3, @intFromEnum(QuantMode.raw));
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try testing.expectError(error.Unsupported, matrices.decode(&br));
}

test "processDCGlobal rejects unsupported frame features" {
    const allocator = testing.allocator;
    var metadata = CodecMetadata{};
    var dec = FrameDecoder.init(allocator, &metadata);
    defer dec.deinit();
    dec.frame_header.flags = frame_header_mod.FrameFlags.noise;

    var data = [_]u8{0x01};
    var br = BitReader.init(&data);

    try testing.expectError(error.Unsupported, dec.processDCGlobalWithReaderStrategy(.specialized, &br));
}

fn makeSplinePayloadForTest(allocator: std.mem.Allocator) ![]u8 {
	const enc_ans = @import("../entropy/enc_ans.zig");
	const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const pack_signed = @import("../base/pack_signed.zig");

	var tokens: [137]enc_ans.Token = undefined;
	var token_count: usize = 0;
	tokens[token_count] = enc_ans.Token.init(2, 0);
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(1, 10);
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(1, 20);
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(0, pack_signed.packSigned(-3));
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(3, 2);
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(4, pack_signed.packSigned(5));
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(4, pack_signed.packSigned(0));
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(4, pack_signed.packSigned(0));
	token_count += 1;
	tokens[token_count] = enc_ans.Token.init(4, pack_signed.packSigned(5));
	token_count += 1;
	while (token_count < tokens.len) : (token_count += 1) {
		tokens[token_count] = enc_ans.Token.init(5, 0);
	}

	const ctx_map = [_]u8{ 0, 1, 2, 3, 4, 5 };
	const uint_configs = [_]HybridUintConfig{HybridUintConfig.init(5, 0, 0)} ** 6;
	var bundle = try enc_ans.buildContextualHistogramBundle(allocator, &tokens, &ctx_map, &uint_configs, 5);
	defer bundle.deinit(allocator);

	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try enc_ans.writeSimpleContextMapNormalizedHistograms(
		bundle.context_map,
		bundle.normalized_counts.len,
		bundle.normalized_counts,
		bundle.uint_configs,
		5,
		&writer,
	);
	_ = try enc_ans.writeContextualHistogramTokens(
		&tokens,
		bundle.infos,
		bundle.context_map,
		bundle.uint_configs,
		&writer,
	);
	try writer.zeroPadToByte();
	return allocator.dupe(u8, writer.bytes());
}

test "processDCGlobal decodes spline state before continuing to DC data" {
	const allocator = testing.allocator;
	var metadata = CodecMetadata{};
	var dec = FrameDecoder.init(allocator, &metadata);
	defer dec.deinit();
	dec.frame_header.flags = frame_header_mod.FrameFlags.splines;
	dec.frame_header.encoding = .modular;
	dec.frame_dim.set(64, 64, 1, 0, 0, true, 1);

	const payload = try makeSplinePayloadForTest(allocator);
	defer allocator.free(payload);
	var br = BitReader.init(payload);

	try testing.expectError(error.GenericError, dec.processDCGlobalWithReaderStrategy(.specialized, &br));
	try testing.expect(dec.splines.hasAny());
	try testing.expectEqual(@as(i32, -3), dec.splines.quantization_adjustment);
	try testing.expectEqual(@as(usize, 1), dec.splines.splines.len);
	try testing.expect(dec.splines.starting_points[0].approxEq(.{ .x = 10, .y = 20 }, 1.0e-3));
}

test "renderSplineOverlays creates float image when parsed splines are present" {
	const allocator = testing.allocator;
	var metadata = CodecMetadata{};
	var dec = FrameDecoder.init(allocator, &metadata);
	defer dec.deinit();
	dec.frame_dim.set(64, 64, 1, 0, 0, true, 1);
	dec.modular_decoder.full_image.deinit();
	dec.modular_decoder.full_image = try Image.create(allocator, 64, 64, 8, 3);

	var color = splines_mod.zero_dct32;
	color[0] = 0.49497476;
	var sigma = splines_mod.zero_dct32;
	sigma[0] = 2.357;
	var spline = splines_mod.Spline{
		.control_points = try allocator.dupe(splines_mod.Point, &.{
			.{ .x = 10, .y = 10 },
			.{ .x = 20, .y = 10 },
			.{ .x = 30, .y = 10 },
		}),
		.color_dct = .{ splines_mod.zero_dct32, splines_mod.zero_dct32, color },
		.sigma_dct = sigma,
	};
	defer spline.deinit(allocator);

	const quantized = try splines_mod.QuantizedSpline.create(allocator, &spline, 0, 0.0, 1.0);
	var owned_splines = try allocator.alloc(splines_mod.QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try allocator.dupe(splines_mod.Point, &.{spline.control_points[0]});
	dec.splines.assignOwned(0, owned_splines, starting_points);

	try dec.renderSplineOverlays();

	try testing.expect(dec.rendered_image != null);
	const rendered = &dec.rendered_image.?;
	var touched = false;
	for (0..64) |x| {
		if (@abs(rendered.rowConst(10, 2)[x]) > 0.0) {
			touched = true;
			break;
		}
	}
	try testing.expect(touched);
}

test "renderSplineOverlays lifts XYB modular planes with decoded DC quants" {
	const allocator = testing.allocator;
	var metadata = CodecMetadata{};
	metadata.m.xyb_encoded = true;
	var dec = FrameDecoder.init(allocator, &metadata);
	defer dec.deinit();
	dec.frame_header.color_transform = .xyb;
	dec.frame_dim.set(64, 64, 1, 0, 0, true, 1);
	dec.dequant_matrices.dc_quant = .{ 0.25, 0.5, 2.0 };
	dec.modular_decoder.full_image.deinit();
	dec.modular_decoder.full_image = try Image.create(allocator, 64, 64, 8, 3);
	dec.modular_decoder.full_image.channels.items[0].row(0)[0] = 10;
	dec.modular_decoder.full_image.channels.items[1].row(0)[0] = 30;
	dec.modular_decoder.full_image.channels.items[2].row(0)[0] = 50;

	var spline = splines_mod.Spline{
		.control_points = try allocator.dupe(splines_mod.Point, &.{
			.{ .x = 10, .y = 10 },
			.{ .x = 20, .y = 10 },
			.{ .x = 30, .y = 10 },
		}),
		.color_dct = .{ splines_mod.zero_dct32, splines_mod.zero_dct32, splines_mod.zero_dct32 },
		.sigma_dct = splines_mod.zero_dct32,
	};
	defer spline.deinit(allocator);

	const quantized = try splines_mod.QuantizedSpline.create(allocator, &spline, 0, 0.0, 0.0);
	var owned_splines = try allocator.alloc(splines_mod.QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try allocator.dupe(splines_mod.Point, &.{spline.control_points[0]});
	dec.splines.assignOwned(0, owned_splines, starting_points);

	try dec.renderSplineOverlays();

	const rendered = &dec.rendered_image.?;
	try testing.expectApproxEqAbs(@as(f32, 30.0 * 0.25), rendered.rowConst(0, 0)[0], 1.0e-6);
	try testing.expectApproxEqAbs(@as(f32, 10.0 * 0.5), rendered.rowConst(0, 1)[0], 1.0e-6);
	try testing.expectApproxEqAbs(@as(f32, (50.0 + 10.0) * 2.0), rendered.rowConst(0, 2)[0], 1.0e-6);
}

test "renderSplineOverlays uses upstream decoder default spline color correlation" {
	const allocator = testing.allocator;
	var metadata = CodecMetadata{};
	metadata.m.xyb_encoded = false;
	var dec = FrameDecoder.init(allocator, &metadata);
	defer dec.deinit();
	dec.frame_header.color_transform = .none;
	dec.frame_dim.set(64, 64, 1, 0, 0, true, 1);
	dec.modular_decoder.full_image.deinit();
	dec.modular_decoder.full_image = try Image.create(allocator, 64, 64, 8, 3);

	var y_color = splines_mod.zero_dct32;
	y_color[0] = 0.49497476;
	var sigma = splines_mod.zero_dct32;
	sigma[0] = 2.357;
	var spline = splines_mod.Spline{
		.control_points = try allocator.dupe(splines_mod.Point, &.{
			.{ .x = 10, .y = 10 },
			.{ .x = 20, .y = 10 },
			.{ .x = 30, .y = 10 },
		}),
		.color_dct = .{ splines_mod.zero_dct32, y_color, splines_mod.zero_dct32 },
		.sigma_dct = sigma,
	};
	defer spline.deinit(allocator);

	const quantized = try splines_mod.QuantizedSpline.create(allocator, &spline, 0, 0.0, 0.0);
	var owned_splines = try allocator.alloc(splines_mod.QuantizedSpline, 1);
	owned_splines[0] = quantized;
	const starting_points = try allocator.dupe(splines_mod.Point, &.{spline.control_points[0]});
	dec.splines.assignOwned(0, owned_splines, starting_points);

	try dec.renderSplineOverlays();

	const rendered = &dec.rendered_image.?;
	var y_touched = false;
	var b_touched = false;
	for (0..64) |x| {
		y_touched = y_touched or @abs(rendered.rowConst(10, 1)[x]) > 0.0;
		b_touched = b_touched or @abs(rendered.rowConst(10, 2)[x]) > 0.0;
	}
	try testing.expect(y_touched);
	try testing.expect(b_touched);
}

test "applyYCbCrChromaSubsampling shrinks chroma channels" {
    const allocator = testing.allocator;
    var image = try Image.create(allocator, 13, 9, 8, 3);
    defer image.deinit();

    var frame_dim = FrameDimensions{};
    frame_dim.set(13, 9, 1, 0, 0, true, 1);
    const subsampling = frame_header_mod.YCbCrChromaSubsampling{
        .channel_mode = .{ 0, 1, 1 },
        .maxhs = 1,
        .maxvs = 1,
    };

    try applyYCbCrChromaSubsampling(allocator, &image, frame_dim, subsampling, 3);

    try testing.expectEqual(@as(usize, 13), image.channels.items[0].w);
    try testing.expectEqual(@as(usize, 9), image.channels.items[0].h);
    try testing.expectEqual(@as(i32, 0), image.channels.items[0].hshift);
    try testing.expectEqual(@as(i32, 0), image.channels.items[0].vshift);
    try testing.expectEqual(@as(usize, 7), image.channels.items[1].w);
    try testing.expectEqual(@as(usize, 5), image.channels.items[1].h);
    try testing.expectEqual(@as(i32, 1), image.channels.items[1].hshift);
    try testing.expectEqual(@as(i32, 1), image.channels.items[1].vshift);
    try testing.expectEqual(@as(usize, 7), image.channels.items[2].w);
    try testing.expectEqual(@as(usize, 5), image.channels.items[2].h);
}

test "applyExtraChannelDimShift shrinks extra channels" {
	const allocator = testing.allocator;
	var image = try Image.create(allocator, 4, 2, 8, 4);
	defer image.deinit();

	var frame_dim = FrameDimensions{};
	frame_dim.set(4, 2, 1, 0, 0, true, 1);

	var metadata = CodecMetadata{};
	metadata.size = .{
		.small = false,
		.ysize_raw = 2,
		.ratio = 0,
		.xsize_raw = 4,
	};
	metadata.m.num_extra_channels = 1;
	metadata.m.extra_channel_count = 1;
	metadata.m.extra_channel_info[0] = .{ .dim_shift = 1 };

	try applyExtraChannelDimShift(allocator, &image, frame_dim, &metadata, 3);

	try testing.expectEqual(@as(usize, 4), image.channels.items[0].w);
	try testing.expectEqual(@as(usize, 2), image.channels.items[0].h);
	try testing.expectEqual(@as(usize, 2), image.channels.items[3].w);
	try testing.expectEqual(@as(usize, 1), image.channels.items[3].h);
	try testing.expectEqual(@as(i32, 1), image.channels.items[3].hshift);
	try testing.expectEqual(@as(i32, 1), image.channels.items[3].vshift);
}
