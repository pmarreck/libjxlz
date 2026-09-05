pub const base = struct {
	pub const status = @import("base/status.zig");
	pub const bits = @import("base/bits.zig");
	pub const common = @import("base/common.zig");
	pub const bit_reader = @import("base/bit_reader.zig");
	pub const bit_writer = @import("base/bit_writer.zig");
	pub const byte_order = @import("base/byte_order.zig");
	pub const fixed_point = @import("base/fixed_point.zig");
	pub const soft_float = @import("base/soft_float.zig");
	pub const random = @import("base/random.zig");
	pub const rect = @import("base/rect.zig");
	pub const float16 = @import("base/float.zig");
	pub const pack_signed = @import("base/pack_signed.zig");
};

pub const entropy = struct {
	pub const ans_params = @import("entropy/ans_params.zig");
	pub const ans_common = @import("entropy/ans_common.zig");
	pub const huffman = @import("entropy/huffman.zig");
	pub const hybrid_uint = @import("entropy/hybrid_uint.zig");
	pub const inverse_mtf = @import("entropy/inverse_mtf.zig");
	pub const dec_ans = @import("entropy/dec_ans.zig");
	pub const enc_ans = @import("entropy/enc_ans.zig");
	pub const enc_context_map = @import("entropy/enc_context_map.zig");
	pub const dec_context_map = @import("entropy/dec_context_map.zig");
};

pub const codec = struct {
	pub const field_coders = @import("codec/field_coders.zig");
	pub const frame_dimensions = @import("codec/frame_dimensions.zig");
	pub const headers = @import("codec/headers.zig");
	pub const loop_filter = @import("codec/loop_filter.zig");
	pub const image_metadata = @import("codec/image_metadata.zig");
	pub const color_encoding = @import("codec/color_encoding.zig");
	pub const splines = @import("codec/splines.zig");
	pub const render = @import("codec/render.zig");
	pub const xyb = @import("codec/xyb.zig");
	pub const icc_codec_common = @import("codec/icc_codec_common.zig");
	pub const icc_codec = @import("codec/icc_codec.zig");
	pub const icc_profiles = @import("codec/icc_profiles.zig");
	pub const container = @import("codec/container.zig");
	pub const frame_header = @import("codec/frame_header.zig");
	pub const toc = @import("codec/toc.zig");
	pub const enc_toc = @import("codec/enc_toc.zig");
	pub const enc_frame = @import("codec/enc_frame.zig");
	pub const enc_codestream = @import("codec/enc_codestream.zig");
	pub const enc_api = @import("codec/enc_api.zig");
	pub const dec_frame = @import("codec/dec_frame.zig");
	pub const ac_metadata = @import("codec/ac_metadata.zig");
	pub const ac_strategy = @import("codec/ac_strategy.zig");
	pub const coeff_order = @import("codec/coeff_order.zig");
	pub const vardct_global = @import("codec/vardct_global.zig");
	pub const dc_group = @import("codec/dc_group.zig");
	pub const inverse_transform = @import("codec/inverse_transform.zig");
	pub const ac_group = @import("codec/ac_group.zig");
	pub const ac_global = @import("codec/ac_global.zig");
	pub const vardct_filters = @import("codec/vardct_filters.zig");
	pub const dc_smoothing = @import("codec/dc_smoothing.zig");
	pub const quantizer = @import("codec/quantizer.zig");
	pub const codestream_test = @import("codec/codestream_test.zig");
	pub const decode_test = @import("codec/decode_test.zig");
};

pub const modular = struct {
	pub const ma_common = @import("modular/ma_common.zig");
	pub const options = @import("modular/options.zig");
	pub const weighted = @import("modular/weighted.zig");
	pub const dec_ma = @import("modular/dec_ma.zig");
	pub const enc_ma = @import("modular/enc_ma.zig");
	pub const context_predict = @import("modular/context_predict.zig");
	pub const transform = @import("modular/transform.zig");
	pub const modular_image = @import("modular/modular_image.zig");
	pub const enc_encoding = @import("modular/enc_encoding.zig");
	pub const encoding = @import("modular/encoding.zig");
};

test {
	// Use refAllDecls to verify all declarations compile.
	// Explicit test imports below ensure tests from all modules are discovered.
	@import("std").testing.refAllDecls(@This());

	// Base
	_ = @import("base/status.zig");
	_ = @import("base/bits.zig");
	_ = @import("base/common.zig");
	_ = @import("base/bit_reader.zig");
	_ = @import("base/bit_writer.zig");
	_ = @import("base/byte_order.zig");
	_ = @import("base/fixed_point.zig");
	_ = @import("base/soft_float.zig");
	_ = @import("base/random.zig");
	_ = @import("base/rect.zig");
	_ = @import("base/float.zig");
	_ = @import("base/pack_signed.zig");

	// Entropy
	_ = @import("entropy/ans_params.zig");
	_ = @import("entropy/ans_common.zig");
	_ = @import("entropy/huffman.zig");
	_ = @import("entropy/hybrid_uint.zig");
	_ = @import("entropy/inverse_mtf.zig");
	_ = @import("entropy/dec_ans.zig");
	_ = @import("entropy/enc_ans.zig");
	_ = @import("entropy/enc_context_map.zig");
	_ = @import("entropy/dec_context_map.zig");

	// Codec
	_ = @import("codec/field_coders.zig");
	_ = @import("codec/frame_dimensions.zig");
	_ = @import("codec/headers.zig");
	_ = @import("codec/loop_filter.zig");
	_ = @import("codec/image_metadata.zig");
	_ = @import("codec/color_encoding.zig");
	_ = @import("codec/splines.zig");
	_ = @import("codec/render.zig");
	_ = @import("codec/xyb.zig");
	_ = @import("codec/icc_codec_common.zig");
	_ = @import("codec/icc_codec.zig");
	_ = @import("codec/icc_profiles.zig");
	_ = @import("codec/container.zig");
	_ = @import("codec/frame_header.zig");
	_ = @import("codec/toc.zig");
	_ = @import("codec/enc_toc.zig");
	_ = @import("codec/enc_frame.zig");
	_ = @import("codec/enc_codestream.zig");
	_ = @import("codec/enc_api.zig");
	_ = @import("codec/dec_frame.zig");
	_ = @import("codec/ac_metadata.zig");
	_ = @import("codec/ac_strategy.zig");
	_ = @import("codec/coeff_order_test.zig");
	_ = @import("codec/vardct_global_test.zig");
	_ = @import("codec/chroma_test.zig");
	_ = @import("codec/dc_group_test.zig");
    _ = @import("codec/inverse_transform_test.zig");
	_ = @import("codec/ac_group_test.zig");
	_ = @import("codec/ac_global_test.zig");
	_ = @import("codec/vardct_frame_test.zig");
	_ = @import("codec/vardct_filters_test.zig");
	_ = @import("codec/large_quant_test.zig");
	_ = @import("codec/dc_smoothing_test.zig");
	_ = @import("codec/quantizer.zig");
	_ = @import("codec/codestream_test.zig");
	_ = @import("codec/decode_test.zig");

	// Modular
	_ = @import("modular/ma_common.zig");
	_ = @import("modular/options.zig");
	_ = @import("modular/weighted.zig");
	_ = @import("modular/dec_ma.zig");
	_ = @import("modular/enc_ma.zig");
	_ = @import("modular/context_predict.zig");
	_ = @import("modular/transform.zig");
	_ = @import("modular/modular_image.zig");
	_ = @import("modular/enc_encoding.zig");
	_ = @import("modular/encoding.zig");

}
