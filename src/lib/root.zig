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

test {
	@import("std").testing.refAllDecls(@This());
}
