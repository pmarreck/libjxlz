//! JPEG XL patch/frame blending in Fixed, including alpha channel overrides.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
pub const Mode = enum(u3) { none, replace, add, mul, blend_above, blend_below, alpha_add_above, alpha_add_below };
pub const Info = struct { mode: Mode = .none, alpha_channel: usize = 0, clamp: bool = false };
pub const Extra = struct { is_alpha: bool = false, associated: bool = false, blend: Info = .{} };
fn usesAlpha(mode: Mode) bool {
	return @intFromEnum(mode) >= 4;
}
fn below(mode: Mode) bool {
	return mode == .blend_below or mode == .alpha_add_below;
}
fn clamp(value: sf.Fixed) sf.Fixed {
	return if (value.m < 0) sf.Fixed.zero else if (sf.cmp(value, sf.fromInt(1)) > 0) sf.fromInt(1) else value;
}
fn newAlpha(bottom: sf.Fixed, top: sf.Fixed) sf.Fixed {
	return sf.sub(sf.fromInt(1), sf.mul(sf.sub(sf.fromInt(1), top), sf.sub(sf.fromInt(1), bottom)));
}
fn compute(bottom: sf.Fixed, top: sf.Fixed, bga: sf.Fixed, fga: sf.Fixed, info: Info, associated: bool, is_alpha: bool) sf.Fixed {
	switch (info.mode) {
		.none => return bottom,
		.replace => return top,
		.add => return sf.add(bottom, top),
		.mul => return sf.mul(bottom, if (info.clamp) clamp(top) else top),
		else => {},
	}
	const fa = if (info.clamp) clamp(fga) else fga;
	if (info.mode == .alpha_add_above or info.mode == .alpha_add_below)
		return if (is_alpha) bottom else sf.add(bottom, sf.mul(top, fa));
	const alpha = newAlpha(bga, fa);
	if (is_alpha) return alpha;
	const remainder = sf.sub(sf.fromInt(1), fa);
	if (associated) return sf.add(top, sf.mul(bottom, remainder));
	if (alpha.m <= 0) return sf.Fixed.zero;
	return sf.div(sf.add(sf.mul(top, fa), sf.mul(sf.mul(bottom, bga), remainder)), alpha);
}
fn overlap(a: []const sf.Fixed, b: []const sf.Fixed) bool {
	if (a.len == 0 or b.len == 0) return false;
	const x = @intFromPtr(a.ptr);
	const y = @intFromPtr(b.ptr);
	return if (x <= y) y - x < a.len * @sizeOf(sf.Fixed) else x - y < b.len * @sizeOf(sf.Fixed);
}
pub fn pixel(bg: []const sf.Fixed, fg: []const sf.Fixed, output: []sf.Fixed, color: Info, extras: []const Extra) jxl.base.status.JxlError!void {
	if (extras.len > 256 or bg.len != extras.len + 3 or fg.len != bg.len or output.len != bg.len or overlap(bg, output) or overlap(fg, output)) return error.GenericError;
	var has_alpha = false;
	for (extras) |extra| {
		has_alpha = has_alpha or extra.is_alpha;
		if (usesAlpha(extra.blend.mode) and extra.blend.alpha_channel >= extras.len) return error.GenericError;
	}
	if (has_alpha and usesAlpha(color.mode) and color.alpha_channel >= extras.len) return error.GenericError;
	for (extras, 0..) |extra, index| {
		const info = extra.blend;
		const bottom = if (below(info.mode)) fg else bg;
		const top = if (below(info.mode)) bg else fg;
		const alpha = if (usesAlpha(info.mode)) info.alpha_channel else 0;
		output[3 + index] = compute(bottom[3 + index], top[3 + index], bottom[3 + alpha], top[3 + alpha], info, extras[alpha].associated, index == alpha);
	}
	var info = color;
	if (!has_alpha) info.mode = switch (info.mode) {
		.blend_above, .blend_below => .replace,
		.alpha_add_above, .alpha_add_below => .add,
		else => info.mode,
	};
	const bottom = if (below(info.mode)) fg else bg;
	const top = if (below(info.mode)) bg else fg;
	const alpha = if (usesAlpha(info.mode)) info.alpha_channel else 0;
	const bga = if (usesAlpha(info.mode)) bottom[3 + alpha] else sf.Fixed.zero;
	const fga = if (usesAlpha(info.mode)) top[3 + alpha] else sf.Fixed.zero;
	for (0..3) |c| output[c] = compute(bottom[c], top[c], bga, fga, info, if (usesAlpha(info.mode)) extras[alpha].associated else false, false);
	// Color alpha blending owns its selected alpha, overriding its extra blend.
	if (has_alpha and (info.mode == .blend_above or info.mode == .blend_below)) output[3 + alpha] = newAlpha(bga, if (info.clamp) clamp(fga) else fga);
}
