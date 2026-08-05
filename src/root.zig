const lib = @import("lib/root.zig");
const ffi_decode = @import("capi_root.zig");
pub const validation = @import("validation.zig");

pub const base = lib.base;
pub const entropy = lib.entropy;
pub const codec = lib.codec;
pub const modular = lib.modular;

pub const ffi = struct {
	pub const decode = ffi_decode;
};

test {
	_ = @import("lib/root.zig");
	_ = ffi_decode;
	_ = validation;
}
