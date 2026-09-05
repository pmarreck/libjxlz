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
const sf = @import("../base/soft_float.zig");
pub const Quantizer = @import("quantizer.zig").Quantizer;
const ac_metadata = @import("ac_metadata.zig");
const vardct = @import("vardct_global.zig");

const VarDctGlobal = struct {
	quantizer: Quantizer,
	block_context: vardct.BlockContextMap,
	color_correlation: vardct.ColorCorrelation,

	fn deinit(self: *VarDctGlobal) void {
		self.block_context.deinit();
	}
};

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
/// C++ AcStrategyType. Values are bitstream ABI and EnsureComputed mask bits.
pub const AcStrategyType = enum(u32) {
	dct = 0,
	identity = 1,
	dct2x2 = 2,
	dct4x4 = 3,
	dct16x16 = 4,
	dct32x32 = 5,
	dct16x8 = 6,
	dct8x16 = 7,
	dct32x8 = 8,
	dct8x32 = 9,
	dct32x16 = 10,
	dct16x32 = 11,
	dct4x8 = 12,
	dct8x4 = 13,
	afv0 = 14,
	afv1 = 15,
	afv2 = 16,
	afv3 = 17,
	dct64x64 = 18,
	dct64x32 = 19,
	dct32x64 = 20,
};

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
	distance_bands: [3][kMaxDistanceBands]sf.Fixed = @splat(@splat(sf.Fixed.zero)),
};

pub const QuantEncoding = struct {
	mode: QuantMode = .library,
	predefined: u8 = 0,
	idweights: [3][3]sf.Fixed = @splat(@splat(sf.Fixed.zero)),
	dct2weights: [3][6]sf.Fixed = @splat(@splat(sf.Fixed.zero)),
	dct4multipliers: [3][2]sf.Fixed = @splat(@splat(sf.Fixed.zero)),
	dct4x8multipliers: [3]sf.Fixed = @splat(sf.Fixed.zero),
	afv_weights: [3][9]sf.Fixed = @splat(@splat(sf.Fixed.zero)),
	dct_params: DctQuantWeightParams = .{},
	dct_params_afv_4x4: DctQuantWeightParams = .{},
};

const kNumQuantTables: usize = 17; // DequantMatrices::kNum in C++
const kDctBlockSize: usize = 64;
const kSumRequiredXy: usize = 2056;
const kTotalTableSize: usize = kSumRequiredXy * kDctBlockSize * 3;
const kRequiredSizeX = [_]u8{ 1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16 };
const kRequiredSizeY = [_]u8{ 1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32 };
const kAcStrategyToQuantTable = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 10, 10, 11, 12, 12 };
const kLibraryIdentity = QuantEncoding{
	.mode = .identity,
	.idweights = .{
		.{ sf.fromInt(280), sf.fromInt(3160), sf.fromInt(3160) },
		.{ sf.fromInt(60), sf.fromInt(864), sf.fromInt(864) },
		.{ sf.fromInt(18), sf.fromInt(200), sf.fromInt(200) },
	},
};
const kLibraryDct2 = QuantEncoding{
	.mode = .dct2,
	.dct2weights = .{
		.{ sf.fromInt(3840), sf.fromInt(2560), sf.fromInt(1280), sf.fromInt(640), sf.fromInt(480), sf.fromInt(300) },
		.{ sf.fromInt(960), sf.fromInt(640), sf.fromInt(320), sf.fromInt(180), sf.fromInt(140), sf.fromInt(120) },
		.{ sf.fromInt(640), sf.fromInt(320), sf.fromInt(128), sf.fromInt(64), sf.fromInt(32), sf.fromInt(16) },
	},
};

fn libraryDct() QuantEncoding {
	const neg_two_fifths = sf.div(sf.fromInt(-2), sf.fromInt(5));
	const neg_three_tenths = sf.div(sf.fromInt(-3), sf.fromInt(10));
	var params = DctQuantWeightParams{ .num_distance_bands = 6 };
	params.distance_bands[0][0] = sf.fromInt(3150);
	params.distance_bands[0][1] = sf.fromInt(0);
	params.distance_bands[0][2] = neg_two_fifths;
	params.distance_bands[0][3] = neg_two_fifths;
	params.distance_bands[0][4] = neg_two_fifths;
	params.distance_bands[0][5] = sf.fromInt(-2);
	params.distance_bands[1][0] = sf.fromInt(560);
	params.distance_bands[1][1] = sf.fromInt(0);
	params.distance_bands[1][2] = neg_three_tenths;
	params.distance_bands[1][3] = neg_three_tenths;
	params.distance_bands[1][4] = neg_three_tenths;
	params.distance_bands[1][5] = neg_three_tenths;
	params.distance_bands[2][0] = sf.fromInt(512);
	params.distance_bands[2][1] = sf.fromInt(-2);
	params.distance_bands[2][2] = sf.fromInt(-1);
	params.distance_bands[2][3] = sf.fromInt(0);
	params.distance_bands[2][4] = sf.fromInt(-1);
	params.distance_bands[2][5] = sf.fromInt(-2);
	return .{ .mode = .dct, .dct_params = params };
}

fn libraryFixed(s: []const u8) sf.Fixed {
	return sf.parse(s) orelse unreachable;
}

fn libraryDctParams(num_bands: u8, x: []const []const u8, y: []const []const u8, b: []const []const u8) DctQuantWeightParams {
	var params = DctQuantWeightParams{ .num_distance_bands = num_bands };
	for (x, 0..) |s, i| params.distance_bands[0][i] = libraryFixed(s);
	for (y, 0..) |s, i| params.distance_bands[1][i] = libraryFixed(s);
	for (b, 0..) |s, i| params.distance_bands[2][i] = libraryFixed(s);
	return params;
}

fn libraryDct16() QuantEncoding {
	return .{
		.mode = .dct,
		.dct_params = libraryDctParams(7, &.{
			"8996.8725711814115328",
			"-1.3000777393353804",
			"-0.49424529824571225",
			"-0.439093774457103443",
			"-0.6350101832695744",
			"-0.90177264050827612",
			"-1.6162099239887414",
		}, &.{
			"3191.48366296844234752",
			"-0.67424582104194355",
			"-0.80745813428471001",
			"-0.44925837484843441",
			"-0.35865440981033403",
			"-0.31322389111877305",
			"-0.37615025315725483",
		}, &.{
			"1157.50408145487200256",
			"-2.0531423165804414",
			"-1.4",
			"-0.50687130033378396",
			"-0.42708730624733904",
			"-1.4856834539296244",
			"-4.9209142884401604",
		}),
	};
}

fn libraryDct32() QuantEncoding {
	return .{
		.mode = .dct,
		.dct_params = libraryDctParams(8, &.{
			"15718.40830982518931456",
			"-1.025",
			"-0.98",
			"-0.9012",
			"-0.4",
			"-0.48819395464",
			"-0.421064",
			"-0.27",
		}, &.{
			"7305.7636810695983104",
			"-0.8041958212306401",
			"-0.7633036457487539",
			"-0.55660379990111464",
			"-0.49785304658857626",
			"-0.43699592683512467",
			"-0.40180866526242109",
			"-0.27321683125358037",
		}, &.{
			"3803.53173721215041536",
			"-3.060733579805728",
			"-2.0413270132490346",
			"-2.0235650159727417",
			"-0.5495389509954993",
			"-0.4",
			"-0.4",
			"-0.3",
		}),
	};
}

fn libraryDct8x16() QuantEncoding {
	return .{
		.mode = .dct,
		.dct_params = libraryDctParams(7, &.{
			"7240.7734393502",
			"-0.7",
			"-0.7",
			"-0.2",
			"-0.2",
			"-0.2",
			"-0.5",
		}, &.{
			"1448.15468787004",
			"-0.5",
			"-0.5",
			"-0.5",
			"-0.2",
			"-0.2",
			"-0.2",
		}, &.{
			"506.854140754517",
			"-1.4",
			"-0.2",
			"-0.5",
			"-0.5",
			"-1.5",
			"-3.6",
		}),
	};
}

fn libraryDct8x32() QuantEncoding {
	return .{
		.mode = .dct,
		.dct_params = libraryDctParams(8, &.{
			"16283.2494710648897",
			"-1.7812845336559429",
			"-1.6309059012653515",
			"-1.0382179034313539",
			"-0.85",
			"-0.7",
			"-0.9",
			"-1.2360638576849587",
		}, &.{
			"5089.15750884921511936",
			"-0.320049391452786891",
			"-0.35362849922161446",
			"-0.30340000000000003",
			"-0.61",
			"-0.5",
			"-0.5",
			"-0.6",
		}, &.{
			"3397.77603275308720128",
			"-0.321327362693153371",
			"-0.34507619223117997",
			"-0.70340000000000003",
			"-0.9",
			"-1.0",
			"-1.0",
			"-1.1754605576265209",
		}),
	};
}

fn libraryDct16x32() QuantEncoding {
	return .{
		.mode = .dct,
		.dct_params = libraryDctParams(8, &.{
			"13844.97076442300573",
			"-0.97113799999999995",
			"-0.658",
			"-0.42026",
			"-0.22712",
			"-0.2206",
			"-0.226",
			"-0.6",
		}, &.{
			"4798.964084220744293",
			"-0.61125308982767057",
			"-0.83770786552491361",
			"-0.79014862079498627",
			"-0.2692727459704829",
			"-0.38272769465388551",
			"-0.22924222653091453",
			"-0.20719098826199578",
		}, &.{
			"1807.236946760964614",
			"-1.2",
			"-1.2",
			"-0.7",
			"-0.7",
			"-0.7",
			"-0.4",
			"-0.5",
		}),
	};
}

fn scaleBand0(params: *DctQuantWeightParams, factor: []const u8, x0: []const u8, y0: []const u8, b0: []const u8) void {
	const f = libraryFixed(factor);
	params.distance_bands[0][0] = sf.mul(f, libraryFixed(x0));
	params.distance_bands[1][0] = sf.mul(f, libraryFixed(y0));
	params.distance_bands[2][0] = sf.mul(f, libraryFixed(b0));
}

fn libraryDct64() QuantEncoding {
	var params = libraryDctParams(8, &.{
		"26629.073922049845",
		"-1.025",
		"-0.78",
		"-0.65012",
		"-0.19041574084286472",
		"-0.20819395464",
		"-0.421064",
		"-0.32733845535848671",
	}, &.{
		"9311.3238710010046",
		"-0.3041958212306401",
		"-0.3633036457487539",
		"-0.35660379990111464",
		"-0.3443074455424403",
		"-0.33699592683512467",
		"-0.30180866526242109",
		"-0.27321683125358037",
	}, &.{
		"4992.2486445538634",
		"-1.2",
		"-1.2",
		"-0.8",
		"-0.7",
		"-0.7",
		"-0.4",
		"-0.5",
	});
	scaleBand0(&params, "0.9", "26629.073922049845", "9311.3238710010046", "4992.2486445538634");
	return .{ .mode = .dct, .dct_params = params };
}

fn libraryDct32x64() QuantEncoding {
	var params = libraryDctParams(8, &.{
		"23629.073922049845",
		"-1.025",
		"-0.78",
		"-0.65012",
		"-0.19041574084286472",
		"-0.20819395464",
		"-0.421064",
		"-0.32733845535848671",
	}, &.{
		"8611.3238710010046",
		"-0.3041958212306401",
		"-0.3633036457487539",
		"-0.35660379990111464",
		"-0.3443074455424403",
		"-0.33699592683512467",
		"-0.30180866526242109",
		"-0.27321683125358037",
	}, &.{
		"4492.2486445538634",
		"-1.2",
		"-1.2",
		"-0.8",
		"-0.7",
		"-0.7",
		"-0.4",
		"-0.5",
	});
	scaleBand0(&params, "0.65", "23629.073922049845", "8611.3238710010046", "4492.2486445538634");
	return .{ .mode = .dct, .dct_params = params };
}

fn libraryAfv() QuantEncoding {
	const d4 = libraryDct4();
	const d48 = libraryDct4x8();
	var afv_weights: [3][9]sf.Fixed = @splat(@splat(sf.Fixed.zero));
	const rows = [_][9][]const u8{
		.{ "3072", "3072", "256", "256", "256", "414", "0", "0", "0" },
		.{ "1024", "1024", "50", "50", "50", "58", "0", "0", "0" },
		.{ "384", "384", "12", "12", "12", "22", "-0.25", "-0.25", "-0.25" },
	};
	for (rows, 0..) |row, c| {
		for (row, 0..) |s, j| afv_weights[c][j] = libraryFixed(s);
	}
	return .{
		.mode = .afv,
		.afv_weights = afv_weights,
		.dct_params = d48.dct_params,
		.dct_params_afv_4x4 = d4.dct_params,
	};
}

fn libraryDct4() QuantEncoding {
	return .{
		.mode = .dct4,
		.dct4multipliers = .{
			.{ sf.fromInt(1), sf.fromInt(1) },
			.{ sf.fromInt(1), sf.fromInt(1) },
			.{ sf.fromInt(1), sf.fromInt(1) },
		},
		.dct_params = libraryDctParams(4, &.{
			"2200",
			"0",
			"0",
			"0",
		}, &.{
			"392",
			"0",
			"0",
			"0",
		}, &.{
			"112",
			"-0.25",
			"-0.25",
			"-0.5",
		}),
	};
}

fn libraryDct4x8() QuantEncoding {
	return .{
		.mode = .dct4x8,
		.dct4x8multipliers = .{ sf.fromInt(1), sf.fromInt(1), sf.fromInt(1) },
		.dct_params = libraryDctParams(4, &.{
			"2198.050556016380522",
			"-0.96269623020744692",
			"-0.76194253026666783",
			"-0.6551140670773547",
		}, &.{
			"764.3655248643528689",
			"-0.92630200888366945",
			"-0.9675229603596517",
			"-0.27845290869168118",
		}, &.{
			"527.107573587542228",
			"-1.4594385811273854",
			"-1.450082094097871593",
			"-1.5843722511996204",
		}),
	};
}
const kOne = sf.fromInt(1);
const kSixtyFour = sf.fromInt(64);
// randomz Fixed: |value| ∈ [2^e, 2^(e+1)), so e is a bit count. C++ used
// decimal 1e-8 / 1e8 (~2^-26.6 / 2^26.6); we bound on the exponent itself.
const kMinWeightExp: i32 = -26;
const kMaxWeightExp: i32 = 26;
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

fn absFixed(value: sf.Fixed) sf.Fixed {
	return if (value.m < 0) sf.neg(value) else value;
}

fn tooSmall(value: sf.Fixed) bool {
	return value.m == 0 or absFixed(value).e < kMinWeightExp;
}

fn tooLarge(value: sf.Fixed) bool {
	return value.m != 0 and absFixed(value).e > kMaxWeightExp;
}

const fromF16Bits = @import("../base/float.zig").loadFloat16Fixed;

fn readF16(br: *BitReader) JxlError!sf.Fixed {
	const bits: u16 = @intCast(br.readBits(16));
	return fromF16Bits(bits);
}

fn readScaledF16(br: *BitReader) JxlError!sf.Fixed {
	const val = try readF16(br);
	if (tooSmall(val)) return error.GenericError;
	return sf.mul(val, kSixtyFour);
}

fn readNonzeroF16(br: *BitReader) JxlError!sf.Fixed {
	const val = try readF16(br);
	if (tooSmall(val)) return error.GenericError;
	return val;
}

fn decodeDctParams(br: *BitReader) JxlError!DctQuantWeightParams {
	var params = DctQuantWeightParams{};
	params.num_distance_bands = @intCast(br.readBits(kLog2MaxDistanceBands) + 1);
	for (0..3) |c| {
		for (0..params.num_distance_bands) |j| {
			params.distance_bands[c][j] = try readF16(br);
		}
		if (tooSmall(params.distance_bands[c][0])) return error.GenericError;
		params.distance_bands[c][0] = sf.mul(params.distance_bands[c][0], kSixtyFour);
	}
	return params;
}

pub const DequantMatrices = struct {
	const default_dc_quant: [3]sf.Fixed = .{
		sf.div(kOne, sf.fromInt(4096)), sf.div(kOne, sf.fromInt(512)), sf.div(kOne, sf.fromInt(256)),
	};
	dc_quant: [3]sf.Fixed = default_dc_quant,
	encodings: [kNumQuantTables]QuantEncoding = [_]QuantEncoding{.{}} ** kNumQuantTables,
	storage: []sf.Fixed = &.{},
	table: []sf.Fixed = &.{},
	inv_table: []sf.Fixed = &.{},
	table_offsets: [kNumQuantTables * 3]usize = @splat(0),
	computed_mask: u32 = 0,

	/// Read DC quantization parameters from the bitstream.
	/// Must be called before DecodeGlobalInfo, matching C++ ProcessDCGlobal flow.
	pub fn decodeDC(self: *DequantMatrices, br: *BitReader) JxlError!void {
		const all_default = br.readBits(1);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		var dc_quant = default_dc_quant;
		if (all_default == 0) {
			for (0..3) |c| {
				const bits16: u16 = @intCast(br.readBits(16));
				if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
				dc_quant[c] = sf.div(try fromF16Bits(bits16), sf.fromInt(128));
				// Preserve DecodeDC's existing 1e-8 bound using integer arithmetic.
				if (sf.cmp(dc_quant[c], comptime sf.parse("0.00000001").?) < 0) return error.GenericError;
			}
		}
		self.dc_quant = dc_quant;
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
					var weights: [3][3]sf.Fixed = undefined;
					for (0..3) |c| {
						for (0..3) |j| {
							weights[c][j] = try readScaledF16(br);
						}
					}
					self.encodings[i] = .{ .mode = .identity, .idweights = weights };
				},
				.dct2 => {
					if (requiredSize(i) != 1) return error.GenericError;
					var weights: [3][6]sf.Fixed = undefined;
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
					var multipliers: [3][2]sf.Fixed = undefined;
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
					var multipliers: [3]sf.Fixed = undefined;
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
					var weights: [3][9]sf.Fixed = undefined;
					for (0..3) |c| {
						for (0..9) |j| {
							weights[c][j] = try readF16(br);
						}
						for (0..6) |j| {
							weights[c][j] = sf.mul(weights[c][j], kSixtyFour);
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

	pub fn deinit(self: *DequantMatrices, allocator: std.mem.Allocator) void {
		if (self.storage.len != 0) {
			allocator.free(self.storage);
			self.storage = &.{};
			self.table = &.{};
			self.inv_table = &.{};
		}
		self.computed_mask = 0;
	}

	/// C++ DequantMatrices::Matrix. `kind` must have been requested in a prior
	/// `ensureComputed` call.
	pub fn matrix(self: *const DequantMatrices, kind: AcStrategyType, c: usize) []const sf.Fixed {
		const table_idx = kAcStrategyToQuantTable[@intFromEnum(kind)];
		const num = requiredSize(table_idx) * kDctBlockSize;
		const off = self.table_offsets[table_idx * 3 + c];
		return self.table[off .. off + num];
	}

	/// Materialize dequant tables for the AC strategies in `acs_mask`.
	/// C++ DequantMatrices::EnsureComputed. Identity, DCT2, DCT4, DCT4x8, AFV,
	/// and DCT 8–64 (square and rectangular through 32×64) library tables
	/// are live; DCT128+ and raw encodings stay unsupported.
	pub fn ensureComputed(self: *DequantMatrices, allocator: std.mem.Allocator, acs_mask: u32) JxlError!void {
		const valid_mask = (@as(u32, 1) << @import("ac_strategy.zig").kNumValidStrategies) - 1;
		const implemented_mask = (@as(u32, 1) << kAcStrategyToQuantTable.len) - 1;
		if ((acs_mask & ~valid_mask) != 0) return error.GenericError;
		if ((acs_mask & ~implemented_mask) != 0) return unsupported_mod.unsupported(.vardct_frame);
		if (self.storage.len == 0) {
			const storage = try allocator.alloc(sf.Fixed, 2 * kTotalTableSize);
			@memset(storage, sf.Fixed.zero);
			self.storage = storage;
			self.table = storage[0..kTotalTableSize];
			self.inv_table = storage[kTotalTableSize..];
			var pos: usize = 0;
			for (0..kNumQuantTables) |i| {
				const num = requiredSize(i) * kDctBlockSize;
				for (0..3) |c| {
					self.table_offsets[3 * i + c] = pos + c * num;
				}
				pos += 3 * num;
			}
		}

		var kind_mask: u32 = 0;
		var computed_kind_mask: u32 = 0;
		for (0..kAcStrategyToQuantTable.len) |i| {
			const strategy_bit = @as(u32, 1) << @intCast(i);
			const table_bit = @as(u32, 1) << @intCast(kAcStrategyToQuantTable[i]);
			if ((acs_mask & strategy_bit) != 0) kind_mask |= table_bit;
			if ((self.computed_mask & strategy_bit) != 0) computed_kind_mask |= table_bit;
		}

		for (0..kNumQuantTables) |table_idx| {
			const table_bit = @as(u32, 1) << @intCast(table_idx);
			if ((kind_mask & table_bit) == 0) continue;
			if ((computed_kind_mask & table_bit) != 0) continue;
			var quant_enc = self.encodings[table_idx];
			if (quant_enc.mode == .library) {
				quant_enc = libraryEncoding(table_idx) orelse return unsupported_mod.unsupported(.vardct_frame);
			}
			switch (quant_enc.mode) {
				.identity => try computeIdentityTable(self, table_idx, quant_enc),
				.dct2 => try computeDct2Table(self, table_idx, quant_enc),
				.dct4 => try computeDct4Table(self, table_idx, quant_enc),
				.dct4x8 => try computeDct4x8Table(self, table_idx, quant_enc),
				.afv => try computeAfvTable(self, table_idx, quant_enc),
				.dct => try computeDctTable(self, allocator, table_idx, quant_enc),
				else => return unsupported_mod.unsupported(.vardct_frame),
			}
		}
		self.computed_mask |= acs_mask;
	}
};

fn libraryEncoding(table_idx: usize) ?QuantEncoding {
	return switch (table_idx) {
		0 => libraryDct(),
		1 => kLibraryIdentity,
		2 => kLibraryDct2,
		3 => libraryDct4(),
		4 => libraryDct16(),
		5 => libraryDct32(),
		6 => libraryDct8x16(),
		7 => libraryDct8x32(),
		8 => libraryDct16x32(),
		9 => libraryDct4x8(),
		10 => libraryAfv(),
		11 => libraryDct64(),
		12 => libraryDct32x64(),
		else => null,
	};
}

fn bandMult(v: sf.Fixed) sf.Fixed {
	if (sf.cmp(v, sf.Fixed.zero) > 0) return sf.add(kOne, v);
	return sf.div(kOne, sf.sub(kOne, v));
}

fn interpolateBands(pos: sf.Fixed, bands: []const sf.Fixed) JxlError!sf.Fixed {
	const idx_i = sf.toIntTrunc(pos);
	if (idx_i < 0) return error.GenericError;
	const idx: usize = @intCast(idx_i);
	if (idx + 1 >= bands.len) return error.GenericError;
	const frac_part = sf.sub(pos, sf.fromInt(idx_i));
	if (frac_part.m == 0) return bands[idx];
	const a = bands[idx];
	const b = bands[idx + 1];
	return sf.mul(a, sf.pow(sf.div(b, a), frac_part));
}

fn interpolateRange(pos: sf.Fixed, maxv: sf.Fixed, bands: []const sf.Fixed) JxlError!sf.Fixed {
	const scaled = sf.div(sf.mul(pos, sf.fromInt(@intCast(bands.len - 1))), maxv);
	return interpolateBands(scaled, bands);
}

/// Fills `out` with 3·rows·cols distance-band quant weights.
/// C++ GetQuantWeights: eccentricity bands, radial `sqrt`, geometric lerp.
/// complexity: O(rows·cols) per channel (band Mult is O(num_bands) setup).
pub fn getQuantWeights(
	rows: usize,
	cols: usize,
	params: DctQuantWeightParams,
	out: []sf.Fixed,
) JxlError!void {
	if (rows == 0 or cols == 0) return error.GenericError;
	const num = rows * cols;
	if (out.len != 3 * num) return error.GenericError;
	const num_bands: usize = params.num_distance_bands;
	if (num_bands == 0 or num_bands > kMaxDistanceBands) return error.GenericError;

	const sqrt2 = sf.sqrt(sf.fromInt(2));
	const eps = sf.div(kOne, sf.fromInt(1_000_000));
	const scale = sf.div(sf.fromInt(@intCast(num_bands - 1)), sf.add(sqrt2, eps));
	const rcpcol = if (cols > 1) sf.div(scale, sf.fromInt(@intCast(cols - 1))) else sf.Fixed.zero;
	const rcprow = if (rows > 1) sf.div(scale, sf.fromInt(@intCast(rows - 1))) else sf.Fixed.zero;

	for (0..3) |c| {
		var bands: [kMaxDistanceBands]sf.Fixed = @splat(sf.Fixed.zero);
		bands[0] = params.distance_bands[c][0];
		if (tooSmall(bands[0])) return error.GenericError;
		var i: usize = 1;
		while (i < num_bands) : (i += 1) {
			bands[i] = sf.mul(bands[i - 1], bandMult(params.distance_bands[c][i]));
			if (tooSmall(bands[i])) return error.GenericError;
		}
		for (0..rows) |y| {
			const dy = sf.mul(sf.fromInt(@intCast(y)), rcprow);
			const dy2 = sf.mul(dy, dy);
			for (0..cols) |x| {
				const dx = sf.mul(sf.fromInt(@intCast(x)), rcpcol);
				const dist = sf.sqrt(sf.add(sf.mul(dx, dx), dy2));
				const weight = if (num_bands == 1) bands[0] else try interpolateBands(dist, bands[0..num_bands]);
				out[c * num + y * cols + x] = weight;
			}
		}
	}
}

fn computeDctTable(
	self: *DequantMatrices,
	allocator: std.mem.Allocator,
	table_idx: usize,
	quant_encoding: QuantEncoding,
) JxlError!void {
	const rows: usize = 8 * @as(usize, kRequiredSizeX[table_idx]);
	const cols: usize = 8 * @as(usize, kRequiredSizeY[table_idx]);
	const num = rows * cols;
	// Live sizes through 64×64. DCT128+ stays unsupported.
	const kMaxLiveCells: usize = 64 * 64;
	if (num > kMaxLiveCells) return unsupported_mod.unsupported(.vardct_frame);
	const weights = try allocator.alloc(sf.Fixed, 3 * num);
	defer allocator.free(weights);
	try getQuantWeights(rows, cols, quant_encoding.dct_params, weights);
	try invertAndStore(self, table_idx, weights);
}

fn computeDct4Table(self: *DequantMatrices, table_idx: usize, quant_encoding: QuantEncoding) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (num != kDctBlockSize) return error.GenericError;
	var w4: [3 * 16]sf.Fixed = undefined;
	try getQuantWeights(4, 4, quant_encoding.dct_params, &w4);
	var weights: [3 * kDctBlockSize]sf.Fixed = undefined;
	for (0..3) |c| {
		const start = c * kDctBlockSize;
		for (0..8) |y| {
			for (0..8) |x| {
				weights[start + y * 8 + x] = w4[c * 16 + (y / 2) * 4 + (x / 2)];
			}
		}
		weights[start + 1] = sf.div(weights[start + 1], quant_encoding.dct4multipliers[c][0]);
		weights[start + 8] = sf.div(weights[start + 8], quant_encoding.dct4multipliers[c][0]);
		weights[start + 9] = sf.div(weights[start + 9], quant_encoding.dct4multipliers[c][1]);
	}
	try invertAndStore(self, table_idx, &weights);
}

fn computeDct4x8Table(self: *DequantMatrices, table_idx: usize, quant_encoding: QuantEncoding) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (num != kDctBlockSize) return error.GenericError;
	var w48: [3 * 32]sf.Fixed = undefined;
	try getQuantWeights(4, 8, quant_encoding.dct_params, &w48);
	var weights: [3 * kDctBlockSize]sf.Fixed = undefined;
	for (0..3) |c| {
		const start = c * kDctBlockSize;
		for (0..8) |y| {
			for (0..8) |x| {
				weights[start + y * 8 + x] = w48[c * 32 + (y / 2) * 8 + x];
			}
		}
		weights[start + 8] = sf.div(weights[start + 8], quant_encoding.dct4x8multipliers[c]);
	}
	try invertAndStore(self, table_idx, &weights);
}

fn computeAfvTable(self: *DequantMatrices, table_idx: usize, quant_encoding: QuantEncoding) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (num != kDctBlockSize) return error.GenericError;
	var w48: [3 * 32]sf.Fixed = undefined;
	try getQuantWeights(4, 8, quant_encoding.dct_params, &w48);
	var w44: [3 * 16]sf.Fixed = undefined;
	try getQuantWeights(4, 4, quant_encoding.dct_params_afv_4x4, &w44);

	const kFreqs = [_]sf.Fixed{
		sf.Fixed.zero,
		sf.Fixed.zero,
		libraryFixed("0.8517778890324296"),
		libraryFixed("5.37778436506804"),
		sf.Fixed.zero,
		sf.Fixed.zero,
		libraryFixed("4.734747904497923"),
		libraryFixed("5.449245381693219"),
		libraryFixed("1.6598270267479331"),
		sf.fromInt(4),
		libraryFixed("7.275749096817861"),
		libraryFixed("10.423227632456525"),
		libraryFixed("2.662932286148962"),
		libraryFixed("7.630657783650829"),
		libraryFixed("8.962388608184032"),
		libraryFixed("12.97166202570235"),
	};
	const lo = kFreqs[2];
	const hi = sf.add(sf.sub(kFreqs[15], lo), sf.div(kOne, sf.fromInt(1_000_000)));

	var weights: [3 * kDctBlockSize]sf.Fixed = undefined;
	for (0..3) |c| {
		var bands: [4]sf.Fixed = undefined;
		bands[0] = quant_encoding.afv_weights[c][5];
		if (tooSmall(bands[0])) return error.GenericError;
		var i: usize = 1;
		while (i < 4) : (i += 1) {
			bands[i] = sf.mul(bands[i - 1], bandMult(quant_encoding.afv_weights[c][i + 5]));
			if (tooSmall(bands[i])) return error.GenericError;
		}
		const start = c * kDctBlockSize;
		weights[start] = kOne;
		weights[start + 8] = quant_encoding.afv_weights[c][0];
		weights[start + 1] = quant_encoding.afv_weights[c][1];
		weights[start + 16] = quant_encoding.afv_weights[c][2];
		weights[start + 2] = quant_encoding.afv_weights[c][3];
		weights[start + 18] = quant_encoding.afv_weights[c][4];
		for (0..4) |y| {
			for (0..4) |x| {
				if (x < 2 and y < 2) continue;
				const val = try interpolateRange(sf.sub(kFreqs[y * 4 + x], lo), hi, bands[0..]);
				weights[start + (2 * y) * 8 + (2 * x)] = val;
			}
		}
		for (0..4) |y| {
			for (0..8) |x| {
				if (x == 0 and y == 0) continue;
				weights[start + (2 * y + 1) * 8 + x] = w48[c * 32 + y * 8 + x];
			}
		}
		for (0..4) |y| {
			for (0..4) |x| {
				if (x == 0 and y == 0) continue;
				weights[start + (2 * y) * 8 + (2 * x + 1)] = w44[c * 16 + y * 4 + x];
			}
		}
	}
	try invertAndStore(self, table_idx, &weights);
}

fn invertAndStore(self: *DequantMatrices, table_idx: usize, weights: []const sf.Fixed) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (weights.len != 3 * num) return error.GenericError;
	const dest = self.table_offsets[table_idx * 3];
	for (0..3 * num) |i| {
		const w = weights[i];
		if (tooSmall(w) or tooLarge(w)) return error.GenericError;
		self.table[dest + i] = sf.div(kOne, w);
		self.inv_table[dest + i] = w;
	}
	for (0..3) |c| {
		self.inv_table[dest + c * num] = sf.Fixed.zero;
	}
}

fn computeIdentityTable(self: *DequantMatrices, table_idx: usize, quant_encoding: QuantEncoding) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (num != kDctBlockSize) return error.GenericError;
	var weights: [3 * kDctBlockSize]sf.Fixed = undefined;
	for (0..3) |c| {
		const start = c * kDctBlockSize;
		for (0..kDctBlockSize) |i| {
			weights[start + i] = quant_encoding.idweights[c][0];
		}
		weights[start + 1] = quant_encoding.idweights[c][1];
		weights[start + 8] = quant_encoding.idweights[c][1];
		weights[start + 9] = quant_encoding.idweights[c][2];
	}
	try invertAndStore(self, table_idx, &weights);
}

fn computeDct2Table(self: *DequantMatrices, table_idx: usize, quant_encoding: QuantEncoding) JxlError!void {
	const num = requiredSize(table_idx) * kDctBlockSize;
	if (num != kDctBlockSize) return error.GenericError;
	var weights: [3 * kDctBlockSize]sf.Fixed = undefined;
	for (0..3) |c| {
		const start = c * kDctBlockSize;
		const w = quant_encoding.dct2weights[c];
		weights[start] = sf.fromInt(0xBAD);
		weights[start + 1] = w[0];
		weights[start + 8] = w[0];
		weights[start + 9] = w[1];
		for (0..2) |y| {
			for (0..2) |x| {
				weights[start + y * 8 + x + 2] = w[2];
				weights[start + (y + 2) * 8 + x] = w[2];
				weights[start + (y + 2) * 8 + x + 2] = w[3];
			}
		}
		for (0..4) |y| {
			for (0..4) |x| {
				weights[start + y * 8 + x + 4] = w[4];
				weights[start + (y + 4) * 8 + x] = w[4];
				weights[start + (y + 4) * 8 + x + 4] = w[5];
			}
		}
	}
	try invertAndStore(self, table_idx, &weights);
}

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
		// VarDCT's global tree can serve its color metadata even though its
		// full modular image contains only extra channels.
		if (!decode_color) nb_chans = 0;

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

	/// Decode the adaptive quantization, strategy, CfL and sharpness maps for
	/// one VarDCT DC group, reusing the frame's borrowed modular entropy tables.
	pub fn decodeAcMetadata(self: *ModularFrameDecoder, br: *BitReader,
		group_id: usize, header: *const FrameHeader) JxlError!ac_metadata.AcMetadata
	{
		if (header.encoding != .var_dct or group_id >= self.frame_dim.num_dc_groups)
			return error.GenericError;
		const rect = self.frame_dim.dcGroupRect(group_id);
		const stream_id = (ModularStreamId{ .kind = .ac_metadata, .group_id = group_id }).id(self.frame_dim);
		return ac_metadata.AcMetadata.decode(self.allocator, br, rect.xsize(), rect.ysize(),
			header.chroma_subsampling.is444(), self.full_image.bitdepth, stream_id, .{
				.tree = if (self.has_tree) self.tree.items else null,
				.code = if (self.has_tree) &self.code else null,
				.context_map = if (self.has_tree) self.context_map else null,
			});
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
    vardct_global: ?VarDctGlobal = null,
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
        self.clearVarDctGlobal();
        self.dequant_matrices.deinit(self.allocator);
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
        self.clearVarDctGlobal();
        self.decoded_dc_global = false;
        self.dequant_matrices.deinit(self.allocator);
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

    fn clearVarDctGlobal(self: *FrameDecoder) void {
        if (self.vardct_global) |*global| global.deinit();
        self.vardct_global = null;
    }

    /// Process DC Global section (section ID 0).
    /// Matches C++ FrameDecoder::ProcessDCGlobal: patches/splines/noise (conditional),
    /// then DecodeDC (unconditional), then DecodeGlobalInfo.
    pub fn processDCGlobalWithReaderStrategy(
        self: *FrameDecoder,
        comptime reader_strategy: ReaderStrategy,
        br: *BitReader,
    ) JxlError!void {
        self.decoded_dc_global = false;
        self.clearVarDctGlobal();
        errdefer self.clearVarDctGlobal();
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
        self.dequant_matrices.deinit(self.allocator);
        self.dequant_matrices = .{};
        try self.dequant_matrices.decodeDC(br);

        if (self.frame_header.encoding == .var_dct) {
            const quantizer = try Quantizer.decode(br);
            var block_context = try vardct.BlockContextMap.decode(self.allocator, br);
            errdefer block_context.deinit();
            const color_correlation = try vardct.ColorCorrelation.decode(br, self.metadata.m.xyb_encoded);
            self.vardct_global = .{
                .quantizer = quantizer,
                .block_context = block_context,
                .color_correlation = color_correlation,
            };
        }
        // VarDCT also carries the global modular tree and extra channels.
        try self.modular_decoder.decodeGlobalInfoWithReaderStrategy(reader_strategy, br, &self.frame_header, self.metadata);
        if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
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

test "Quantizer decodes every selector endpoint without consuming the next field" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	// lib/jxl/quantizer.cc, QuantizerParams::VisitFields. Write the wire
	// selectors directly so this does not round-trip our U32 encoder.
	const scales = [_]struct { selector: u2, bits: u6, payload: u32, value: u32 }{
		.{ .selector = 0, .bits = 11, .payload = 0, .value = 1 },
		.{ .selector = 0, .bits = 11, .payload = 2047, .value = 2048 },
		.{ .selector = 1, .bits = 11, .payload = 0, .value = 2049 },
		.{ .selector = 1, .bits = 11, .payload = 2047, .value = 4096 },
		.{ .selector = 2, .bits = 12, .payload = 0, .value = 4097 },
		.{ .selector = 2, .bits = 12, .payload = 4095, .value = 8192 },
		.{ .selector = 3, .bits = 16, .payload = 0, .value = 8193 },
		.{ .selector = 3, .bits = 16, .payload = 65535, .value = 73728 },
	};
	const dc_values = [_]struct { selector: u2, bits: u6, payload: u32, value: u32 }{
		.{ .selector = 0, .bits = 0, .payload = 0, .value = 16 },
		.{ .selector = 1, .bits = 5, .payload = 0, .value = 1 },
		.{ .selector = 1, .bits = 5, .payload = 31, .value = 32 },
		.{ .selector = 2, .bits = 8, .payload = 0, .value = 1 },
		.{ .selector = 2, .bits = 8, .payload = 255, .value = 256 },
		.{ .selector = 3, .bits = 16, .payload = 0, .value = 1 },
		.{ .selector = 3, .bits = 16, .payload = 65535, .value = 65536 },
	};
	for (scales) |scale| {
		for (dc_values) |dc| {
			var writer = BitWriter.init(testing.allocator);
			defer writer.deinit();
			try writer.write(2, scale.selector);
			try writer.write(scale.bits, scale.payload);
			try writer.write(2, dc.selector);
			try writer.write(dc.bits, dc.payload);
			try writer.write(8, 0xA5);
			try writer.zeroPadToByte();
			var br = BitReader.init(writer.bytes());
			const q = try Quantizer.decode(&br);
			try testing.expectEqual(scale.value, q.global_scale);
			try testing.expectEqual(dc.value, q.quant_dc);
			try testing.expectEqual(@as(usize, 4) + scale.bits + dc.bits, br.totalBitsConsumed());
			try testing.expectEqual(@as(u64, 0xA5), br.readBits(8));
			try br.close();
		}
	}
}

test "Quantizer rejects every truncated prefix of the longest encoding" {
	// Both selectors 3, both 16-bit payloads all ones: 36 one bits.
	const bytes = [_]u8{0xFF} ** 5;
	for (0..36) |available_bits| {
		const byte_count = (available_bits + 7) / 8;
		var br = BitReader.init(bytes[0..byte_count]);
		br.skipBits(byte_count * 8 - available_bits);
		try testing.expectError(error.NotEnoughBytes, Quantizer.decode(&br));
	}
}

test "Quantizer derives DC and AC scales with integer soft-floats" {
	const q = try Quantizer.init(1024, 64);
	try testing.expectEqual(sf.div(sf.fromInt(1), sf.fromInt(64)), q.scale());
	try testing.expectEqual(sf.fromInt(64), q.invGlobalScale());
	try testing.expectEqual(sf.fromInt(1), q.invQuantDC());
	try testing.expectEqual(sf.fromInt(8), try q.invQuantAC(8));
	try testing.expectEqual(sf.div(sf.fromInt(1), sf.fromInt(4)), try q.invQuantAC(256));
	const dc_steps = q.dcSteps(.{ sf.div(kOne, sf.fromInt(4096)), sf.div(kOne, sf.fromInt(512)), sf.div(kOne, sf.fromInt(256)) });
	try testing.expectEqual(sf.div(kOne, sf.fromInt(4096)), dc_steps[0]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(512)), dc_steps[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(256)), dc_steps[2]);
	const scaled = try Quantizer.init(2048, 16);
	try testing.expectEqual(sf.fromInt(2), scaled.invQuantDC());
	try testing.expectEqual(sf.fromInt(4), try scaled.invQuantAC(8));
	try testing.expectError(error.GenericError, Quantizer.init(0, 1));
	try testing.expectError(error.GenericError, Quantizer.init(1, 0));
	try testing.expectError(error.GenericError, Quantizer.init(73729, 1));
	try testing.expectError(error.GenericError, Quantizer.init(1, 65537));
	try testing.expectError(error.GenericError, q.invQuantAC(0));
	try testing.expectError(error.GenericError, q.invQuantAC(257));
}

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

test "VarDCT global tree limit includes color dimensions before omitting modular color planes" {
	const enc = @import("../modular/enc_encoding.zig");
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const HybridUintConfig = @import("../entropy/hybrid_uint.zig").HybridUintConfig;
	const a = testing.allocator;
	const nodes = try a.alloc(dec_ma.PropertyDecisionNode, 2047);
	defer a.free(nodes);
	for (nodes, 0..) |*node, i| {
		node.* = if (i < 1023)
			dec_ma.PropertyDecisionNode.split(0, 0, @intCast(2 * i + 1), @intCast(2 * i + 2))
		else dec_ma.PropertyDecisionNode.leaf(.zero, 0, 1);
	}
	var writer = BitWriter.init(a);
	defer writer.deinit();
	try enc.writeGlobalTreeDcSection(a, nodes, 16, HybridUintConfig.initDefault(), 5, &writer);
	try writer.zeroPadToByte();
	var metadata = CodecMetadata{};
	var header = FrameHeader{};
	header.encoding = .var_dct;
	var dimensions = FrameDimensions{};
	dimensions.set(128, 128, 1, 0, 0, false, 1);
	var decoder = ModularFrameDecoder.init(a);
	defer decoder.deinit();
	decoder.initFrame(dimensions);
	var br = BitReader.init(writer.bytes());
	try decoder.decodeGlobalInfo(&br, &header, &metadata);
	try testing.expectEqual(@as(usize, 2047), decoder.tree.items.len);
	try testing.expectEqual(@as(usize, 0), decoder.full_image.channels.items.len);
	try br.close();
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

test "fromF16Bits reconstructs 1, 2, and 1/2 as randomz soft-floats" {
	try testing.expectEqual(kOne, try fromF16Bits(0x3C00));
	try testing.expectEqual(sf.fromInt(2), try fromF16Bits(0x4000));
	try testing.expectEqual(sf.div(kOne, sf.fromInt(2)), try fromF16Bits(0x3800));
	try testing.expectEqual(sf.Fixed.zero, try fromF16Bits(0x0000));
	try testing.expectError(error.GenericError, fromF16Bits(0x7C00));
}

test "DC quant rejects truncated fields and preserves prior values" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	for (0..3) |_| try writer.write(16, 0x3C00);
	try writer.zeroPadToByte();
	for (0..writer.bytes().len) |len| {
		var matrices = DequantMatrices{};
		const original = matrices.dc_quant;
		var br = BitReader.init(writer.bytes()[0..len]);
		try testing.expectError(error.NotEnoughBytes, matrices.decodeDC(&br));
		try testing.expectEqualDeep(original, matrices.dc_quant);
	}
}

test "DC quant default flag resets a previously customized matrix" {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();
	try writer.write(1, 0);
	for (0..3) |_| try writer.write(16, 0x3C00);
	try writer.write(1, 1);
	try writer.zeroPadToByte();
	var br = BitReader.init(writer.bytes());
	var matrices = DequantMatrices{};
	try matrices.decodeDC(&br);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(128)), matrices.dc_quant[0]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(128)), matrices.dc_quant[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(128)), matrices.dc_quant[2]);
	try matrices.decodeDC(&br);
	try testing.expectEqualDeep((DequantMatrices{}).dc_quant, matrices.dc_quant);
	try testing.expectEqual(@as(usize, 50), br.totalBitsConsumed());
}

test "weight bounds use the binary exponent, not a decimal 1e-8 fence" {
	// randomz Fixed: |value| ∈ [2^e, 2^(e+1)). A 1.5 × 2^-27 weight is
	// ~1.12e-8, which a decimal 1e-8 fence accepts and a bit-count fence
	// (e < -26) rejects.
	const one_and_half: i64 = @bitCast(sf.TWO62 + sf.TWO61);
	const just_under_two_minus_26 = sf.Fixed{ .m = one_and_half, .e = -27 };
	try testing.expect(tooSmall(just_under_two_minus_26));
	try testing.expect(!tooSmall(sf.Fixed{ .m = @bitCast(sf.TWO62), .e = -26 }));
	try testing.expect(tooSmall(sf.Fixed.zero));
	const just_over_1e8 = sf.Fixed{ .m = one_and_half, .e = 26 };
	try testing.expect(!tooLarge(just_over_1e8));
	try testing.expect(tooLarge(sf.Fixed{ .m = @bitCast(sf.TWO62), .e = 27 }));
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
			try testing.expectEqual(kSixtyFour, weight);
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
			try testing.expectEqual(kSixtyFour, weight);
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
		try testing.expectEqual(kSixtyFour, matrices.encodings[0].dct_params.distance_bands[c][0]);
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
			try testing.expectEqual(kOne, mul);
		}
	}
	try testing.expectEqual(kSixtyFour, matrices.encodings[0].dct_params.distance_bands[0][0]);
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
		try testing.expectEqual(kOne, mul);
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
			try testing.expectEqual(kSixtyFour, matrices.encodings[0].afv_weights[c][j]);
		}
		for (6..9) |j| {
			try testing.expectEqual(kOne, matrices.encodings[0].afv_weights[c][j]);
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

test "ensureComputed identity library table inverts the known weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.identity));
	const x = matrices.matrix(.identity, 0);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(280)), x[0]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3160)), x[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3160)), x[8]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3160)), x[9]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(280)), x[2]);
	const y = matrices.matrix(.identity, 1);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(60)), y[0]);
	const b = matrices.matrix(.identity, 2);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(18)), b[0]);
}

test "ensureComputed rejects unimplemented and invalid strategy mask bits" {
	for (21..32) |bit| {
		var matrices = DequantMatrices{};
		defer matrices.deinit(testing.allocator);
		const mask = (@as(u32, 1) << @intCast(bit)) | 1;
		const expected = if (bit < 27) error.Unsupported else error.GenericError;
		try testing.expectError(expected, matrices.ensureComputed(testing.allocator, mask));
		try testing.expectEqual(@as(u32, 0), matrices.computed_mask);
		try testing.expectEqual(@as(usize, 0), matrices.storage.len);
	}
}

test "ensureComputed dct2 library table inverts the known weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct2x2));
	const x = matrices.matrix(.dct2x2, 0);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3840)), x[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3840)), x[8]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(2560)), x[9]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(1280)), x[2]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(640)), x[18]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(480)), x[4]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(300)), x[36]);
}

test "ensureComputed dct library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct));
	const x = matrices.matrix(.dct, 0);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3150)), x[0]);
	const y = matrices.matrix(.dct, 1);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(560)), y[0]);
	const b = matrices.matrix(.dct, 2);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(512)), b[0]);
}

test "ensureComputed dct one-band fills every cell with the seed" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	const seed = sf.fromInt(100);
	var params = DctQuantWeightParams{ .num_distance_bands = 1 };
	params.distance_bands[0][0] = seed;
	params.distance_bands[1][0] = seed;
	params.distance_bands[2][0] = seed;
	matrices.encodings[0] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct));
	const expected = sf.div(kOne, seed);
	for (0..3) |c| {
		for (matrices.matrix(.dct, c)) |w| {
			try testing.expectEqual(expected, w);
		}
	}
}

test "ensureComputed dct two-band interpolates away from DC at the corner" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	var params = DctQuantWeightParams{ .num_distance_bands = 2 };
	for (0..3) |c| {
		params.distance_bands[c][0] = sf.fromInt(100);
		params.distance_bands[c][1] = sf.fromInt(1);
	}
	matrices.encodings[0] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct));
	const x = matrices.matrix(.dct, 0);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(100)), x[0]);
	try testing.expect(sf.cmp(x[63], x[0]) < 0);
}

test "ensureComputed dct16 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct16x16));
	const x = matrices.matrix(.dct16x16, 0);
	try testing.expectEqual(@as(usize, 256), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("8996.8725711814115328").?), x[0]);
	const y = matrices.matrix(.dct16x16, 1);
	try testing.expectEqual(sf.div(kOne, sf.parse("3191.48366296844234752").?), y[0]);
	const b = matrices.matrix(.dct16x16, 2);
	try testing.expectEqual(sf.div(kOne, sf.parse("1157.50408145487200256").?), b[0]);
}

test "ensureComputed dct16 one-band fills every cell with the seed" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	const seed = sf.fromInt(100);
	var params = DctQuantWeightParams{ .num_distance_bands = 1 };
	params.distance_bands[0][0] = seed;
	params.distance_bands[1][0] = seed;
	params.distance_bands[2][0] = seed;
	matrices.encodings[4] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct16x16));
	const expected = sf.div(kOne, seed);
	try testing.expectEqual(@as(usize, 256), matrices.matrix(.dct16x16, 0).len);
	for (0..3) |c| {
		for (matrices.matrix(.dct16x16, c)) |w| {
			try testing.expectEqual(expected, w);
		}
	}
}

test "ensureComputed dct32 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct32x32));
	const x = matrices.matrix(.dct32x32, 0);
	try testing.expectEqual(@as(usize, 1024), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("15718.40830982518931456").?), x[0]);
	const y = matrices.matrix(.dct32x32, 1);
	try testing.expectEqual(sf.div(kOne, sf.parse("7305.7636810695983104").?), y[0]);
	const b = matrices.matrix(.dct32x32, 2);
	try testing.expectEqual(sf.div(kOne, sf.parse("3803.53173721215041536").?), b[0]);
}

test "ensureComputed dct32 one-band fills every cell with the seed" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	const seed = sf.fromInt(100);
	var params = DctQuantWeightParams{ .num_distance_bands = 1 };
	params.distance_bands[0][0] = seed;
	params.distance_bands[1][0] = seed;
	params.distance_bands[2][0] = seed;
	matrices.encodings[5] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct32x32));
	const expected = sf.div(kOne, seed);
	try testing.expectEqual(@as(usize, 1024), matrices.matrix(.dct32x32, 0).len);
	for (0..3) |c| {
		for (matrices.matrix(.dct32x32, c)) |w| {
			try testing.expectEqual(expected, w);
		}
	}
}

test "ensureComputed dct8x16 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct8x16));
	const x = matrices.matrix(.dct8x16, 0);
	try testing.expectEqual(@as(usize, 128), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("7240.7734393502").?), x[0]);
	const y = matrices.matrix(.dct8x16, 1);
	try testing.expectEqual(sf.div(kOne, sf.parse("1448.15468787004").?), y[0]);
	const b = matrices.matrix(.dct8x16, 2);
	try testing.expectEqual(sf.div(kOne, sf.parse("506.854140754517").?), b[0]);
}

test "ensureComputed dct8x32 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct8x32));
	const x = matrices.matrix(.dct8x32, 0);
	try testing.expectEqual(@as(usize, 256), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("16283.2494710648897").?), x[0]);
}

test "ensureComputed dct16x32 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct16x32));
	const x = matrices.matrix(.dct16x32, 0);
	try testing.expectEqual(@as(usize, 512), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("13844.97076442300573").?), x[0]);
}

test "ensureComputed dct8x16 two-band is anisotropic" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	var params = DctQuantWeightParams{ .num_distance_bands = 2 };
	for (0..3) |c| {
		params.distance_bands[c][0] = sf.fromInt(100);
		params.distance_bands[c][1] = sf.fromInt(1);
	}
	matrices.encodings[6] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct8x16));
	const x = matrices.matrix(.dct8x16, 0);
	try testing.expectEqual(@as(usize, 128), x.len);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(100)), x[0]);
	// 8 rows × 16 cols: (1,0) and (0,1) have different radial steps, so
	// a swapped rows/cols GetQuantWeights would invert this comparison.
	try testing.expect(sf.cmp(x[16], x[1]) < 0);
}

test "ensureComputed dct64 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct64x64));
	const x = matrices.matrix(.dct64x64, 0);
	try testing.expectEqual(@as(usize, 4096), x.len);
	const seed = sf.mul(sf.parse("0.9").?, sf.parse("26629.073922049845").?);
	try testing.expectEqual(sf.div(kOne, seed), x[0]);
	const y = matrices.matrix(.dct64x64, 1);
	try testing.expectEqual(sf.div(kOne, sf.mul(sf.parse("0.9").?, sf.parse("9311.3238710010046").?)), y[0]);
	const b = matrices.matrix(.dct64x64, 2);
	try testing.expectEqual(sf.div(kOne, sf.mul(sf.parse("0.9").?, sf.parse("4992.2486445538634").?)), b[0]);
}

test "ensureComputed dct64 one-band fills every cell with the seed" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	const seed = sf.fromInt(100);
	var params = DctQuantWeightParams{ .num_distance_bands = 1 };
	params.distance_bands[0][0] = seed;
	params.distance_bands[1][0] = seed;
	params.distance_bands[2][0] = seed;
	matrices.encodings[11] = .{ .mode = .dct, .dct_params = params };
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct64x64));
	const expected = sf.div(kOne, seed);
	try testing.expectEqual(@as(usize, 4096), matrices.matrix(.dct64x64, 0).len);
	for (0..3) |c| {
		for (matrices.matrix(.dct64x64, c)) |w| {
			try testing.expectEqual(expected, w);
		}
	}
}

test "ensureComputed dct32x64 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct32x64));
	const x = matrices.matrix(.dct32x64, 0);
	try testing.expectEqual(@as(usize, 2048), x.len);
	const seed = sf.mul(sf.parse("0.65").?, sf.parse("23629.073922049845").?);
	try testing.expectEqual(sf.div(kOne, seed), x[0]);
}

test "ensureComputed dct4 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct4x4));
	const x = matrices.matrix(.dct4x4, 0);
	try testing.expectEqual(@as(usize, 64), x.len);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(2200)), x[0]);
	const y = matrices.matrix(.dct4x4, 1);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(392)), y[0]);
	const b = matrices.matrix(.dct4x4, 2);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(112)), b[0]);
}

test "ensureComputed dct4 multipliers scale the (0,1)/(1,0)/(1,1) weights" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	const seed = sf.fromInt(100);
	var params = DctQuantWeightParams{ .num_distance_bands = 1 };
	params.distance_bands[0][0] = seed;
	params.distance_bands[1][0] = seed;
	params.distance_bands[2][0] = seed;
	var multipliers: [3][2]sf.Fixed = undefined;
	for (0..3) |c| {
		multipliers[c][0] = sf.fromInt(2);
		multipliers[c][1] = sf.fromInt(4);
	}
	matrices.encodings[3] = .{
		.mode = .dct4,
		.dct4multipliers = multipliers,
		.dct_params = params,
	};
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct4x4));
	const x = matrices.matrix(.dct4x4, 0);
	try testing.expectEqual(sf.div(kOne, seed), x[0]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(50)), x[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(50)), x[8]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(25)), x[9]);
	try testing.expectEqual(sf.div(kOne, seed), x[2]);
}

test "ensureComputed dct4x8 library table inverts the DC weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.dct4x8));
	const x = matrices.matrix(.dct4x8, 0);
	try testing.expectEqual(@as(usize, 64), x.len);
	try testing.expectEqual(sf.div(kOne, sf.parse("2198.050556016380522").?), x[0]);
}

test "ensureComputed afv library table inverts the special-position weights" {
	const allocator = testing.allocator;
	var data = [_]u8{0x01};
	var br = BitReader.init(&data);
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	try matrices.decode(&br);
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.afv0));
	const x = matrices.matrix(.afv0, 0);
	try testing.expectEqual(@as(usize, 64), x.len);
	try testing.expectEqual(kOne, x[0]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3072)), x[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(3072)), x[8]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(256)), x[2]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(256)), x[16]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(256)), x[18]);
}

test "ensureComputed afv places 4x8 weights on odd rows and 4x4 on even-odd" {
	const allocator = testing.allocator;
	var matrices = DequantMatrices{};
	defer matrices.deinit(allocator);
	var params48 = DctQuantWeightParams{ .num_distance_bands = 1 };
	var params44 = DctQuantWeightParams{ .num_distance_bands = 1 };
	var afv_weights: [3][9]sf.Fixed = @splat(@splat(sf.Fixed.zero));
	for (0..3) |c| {
		params48.distance_bands[c][0] = sf.fromInt(200);
		params44.distance_bands[c][0] = sf.fromInt(400);
		afv_weights[c][0] = sf.fromInt(10);
		afv_weights[c][1] = sf.fromInt(20);
		afv_weights[c][2] = sf.fromInt(30);
		afv_weights[c][3] = sf.fromInt(30);
		afv_weights[c][4] = sf.fromInt(30);
		afv_weights[c][5] = sf.fromInt(100);
	}
	matrices.encodings[10] = .{
		.mode = .afv,
		.afv_weights = afv_weights,
		.dct_params = params48,
		.dct_params_afv_4x4 = params44,
	};
	try matrices.ensureComputed(allocator, @as(u32, 1) << @intFromEnum(AcStrategyType.afv0));
	const x = matrices.matrix(.afv0, 0);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(20)), x[1]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(10)), x[8]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(200)), x[24]);
	try testing.expectEqual(sf.div(kOne, sf.fromInt(400)), x[3]);
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

	try testing.expectError(error.NotEnoughBytes, dec.processDCGlobalWithReaderStrategy(.specialized, &br));
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
	dec.dequant_matrices.dc_quant = .{ sf.div(kOne, sf.fromInt(4)), sf.div(kOne, sf.fromInt(2)), sf.fromInt(2) };
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

fn checkVarDctDCGlobal(allocator: std.mem.Allocator) !void {
	const BitWriter = @import("../base/bit_writer.zig").BitWriter;
	const fixture = @import("vardct_global_fixture.zig");
	var writer = BitWriter.init(allocator);
	defer writer.deinit();
	try writer.write(1, 1); // Default DC dequant weights.
	try writer.write(2, 0); // Global scale 2048, first selector endpoint.
	try writer.write(11, 2047);
	try writer.write(2, 0); // Quant DC 16.
	var source = BitReader.init(&fixture.block_context);
	for (0..fixture.block_context_bits) |_| try writer.write(1, source.readBits(1));
	try source.close();
	try writer.write(1, 1); // Default CfL.
	try writer.write(1, 0); // No modular global tree, no extra channels.
	const bits = writer.bitsWritten();
	try writer.write(8, 0xa5); // Next section's sentinel.
	try writer.zeroPadToByte();
	var metadata = CodecMetadata{};
	var dec = FrameDecoder.init(allocator, &metadata);
	defer dec.deinit();
	dec.frame_header.encoding = .var_dct;
	dec.frame_dim.set(8, 8, 1, 0, 0, false, 1);
	dec.modular_decoder.initFrame(dec.frame_dim);
	var br = BitReader.init(writer.bytes());
	try dec.processDCGlobal(&br);
	try testing.expectEqual(bits, br.totalBitsConsumed());
	try testing.expect(dec.decoded_dc_global);
	try testing.expectEqual(@as(u32, 2048), dec.vardct_global.?.quantizer.global_scale);
	try testing.expectEqual(@as(usize, 4), dec.vardct_global.?.block_context.num_ctxs);
	try testing.expectEqual(@as(usize, 0), dec.modular_decoder.full_image.channels.items.len);
	try testing.expectEqual(@as(u64, 0xa5), br.readBits(8));
	try br.close();
	// A truncated retry must clear the previous success flag and owned state.
	var empty = BitReader.init(&.{});
	try testing.expectError(error.NotEnoughBytes, dec.processDCGlobal(&empty));
	try testing.expect(!dec.decoded_dc_global);
	try testing.expect(dec.vardct_global == null);
}

test "VarDCT DC-global frame adapter consumes quantizer contexts CfL and modular info" {
	try checkVarDctDCGlobal(testing.allocator);
}

test "VarDCT DC-global frame adapter allocation cleanup" {
	try testing.checkAllAllocationFailures(testing.allocator, checkVarDctDCGlobal, .{});
}
