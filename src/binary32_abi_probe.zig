const sf = @import("lib/base/binary32.zig");
export fn binary32_add(a: u32, b: u32) u32 {
	return sf.add(a, b);
}
export fn binary32_sub(a: u32, b: u32) u32 {
	return sf.sub(a, b);
}
export fn binary32_mul(a: u32, b: u32) u32 {
	return sf.mul(a, b);
}
export fn binary32_div(a: u32, b: u32) u32 {
	return sf.div(a, b);
}
