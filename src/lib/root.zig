pub const base = struct {
	pub const status = @import("base/status.zig");
	pub const bits = @import("base/bits.zig");
	pub const common = @import("base/common.zig");
	pub const bit_reader = @import("base/bit_reader.zig");
	pub const byte_order = @import("base/byte_order.zig");
	pub const random = @import("base/random.zig");
	pub const rect = @import("base/rect.zig");
	pub const float16 = @import("base/float.zig");
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

test {
	@import("std").testing.refAllDecls(@This());
}
