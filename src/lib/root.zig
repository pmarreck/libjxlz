pub const base = struct {
	pub const status = @import("base/status.zig");
	pub const bits = @import("base/bits.zig");
	pub const common = @import("base/common.zig");
	pub const bit_reader = @import("base/bit_reader.zig");
	pub const byte_order = @import("base/byte_order.zig");
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
	pub const dec_context_map = @import("entropy/dec_context_map.zig");
};

pub const codec = struct {
	pub const field_coders = @import("codec/field_coders.zig");
	pub const frame_dimensions = @import("codec/frame_dimensions.zig");
	pub const headers = @import("codec/headers.zig");
	pub const loop_filter = @import("codec/loop_filter.zig");
	pub const image_metadata = @import("codec/image_metadata.zig");
	pub const color_encoding = @import("codec/color_encoding.zig");
	pub const frame_header = @import("codec/frame_header.zig");
	pub const toc = @import("codec/toc.zig");
	pub const dec_frame = @import("codec/dec_frame.zig");
	pub const codestream_test = @import("codec/codestream_test.zig");
	pub const decode_test = @import("codec/decode_test.zig");
};

pub const modular = struct {
	pub const ma_common = @import("modular/ma_common.zig");
	pub const options = @import("modular/options.zig");
	pub const weighted = @import("modular/weighted.zig");
	pub const dec_ma = @import("modular/dec_ma.zig");
	pub const context_predict = @import("modular/context_predict.zig");
	pub const transform = @import("modular/transform.zig");
	pub const modular_image = @import("modular/modular_image.zig");
	pub const encoding = @import("modular/encoding.zig");
};

test {
	@import("std").testing.refAllDecls(@This());
}
