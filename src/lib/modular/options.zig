// Modular coding options: predictor enum, property types.
// Transliterated from lib/jxl/modular/options.h

pub const pixel_type = i32;
pub const pixel_type_w = i64;

pub const PropertyVal = i32;

pub const Predictor = enum(u32) {
    zero = 0,
    left = 1,
    top = 2,
    average0 = 3,
    select = 4,
    gradient = 5,
    weighted = 6,
    top_right = 7,
    top_left = 8,
    left_left = 9,
    average1 = 10,
    average2 = 11,
    average3 = 12,
    average4 = 13,
    // Encoder-only:
    best = 14,
    variable = 15,
};

pub const kNumModularPredictors: usize = @intFromEnum(Predictor.average4) + 1;
pub const kNumModularEncoderPredictors: usize = @intFromEnum(Predictor.variable) + 1;

pub const kNumStaticProperties: usize = 2; // channel, group_id

pub const TreeMode = enum(u2) {
	gradient_only,
	wp_only,
	no_wp,
	default,
};

pub const TreeKind = enum(u3) {
	trivial_tree_no_predictor,
	learn,
	jpeg_transcode_ac_meta,
	falcon_ac_meta,
	ac_meta,
	wp_fixed_dc,
	gradient_fixed_dc,
};

pub const ModularOptions = struct {
	max_chan_size: usize = 0xFFFFFF,
	group_dim: usize = 0x1FFFFFFF,
	predictor: Predictor = .zero,
	wp_mode: i32 = 0,
	wp_tree_mode: TreeMode = .default,
	skip_encoder_fast_path: bool = false,
	tree_kind: TreeKind = .learn,
	zero_tokens: bool = false,
};
