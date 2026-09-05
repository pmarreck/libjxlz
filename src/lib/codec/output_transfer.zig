const std = @import("std");
const color = @import("color_encoding.zig");
const JxlError = @import("../base/status.zig").JxlError;

/// Convert linear display samples at the existing floating output boundary.
pub fn fromLinear(input: [3]f32, tf: color.CustomTransferFunction, intensity: f32, luminances: [3]f32) JxlError![3]f32 {
	var rgb = input;
	if (tf.have_gamma or tf.transfer_function == .dci) {
		const exponent = if (tf.have_gamma) @as(f32, @floatFromInt(tf.gamma)) * 1e-7 else 1.0 / 2.6;
		for (&rgb) |*v| v.* = if (v.* <= 1e-5) 0 else std.math.pow(f32, v.*, exponent);
		return rgb;
	}
	if (tf.transfer_function == .hlg) {
		const exponent = (1.0 / 1.2) * std.math.pow(f32, 1.111, -@log2(intensity / 1000)) - 1;
		if (@abs(exponent) > 0.01) {
			const luminance = @mulAdd(f32, luminances[0], rgb[0], @mulAdd(f32, luminances[1], rgb[1], luminances[2] * rgb[2]));
			const ratio = @min(hlgPower(luminance, exponent), 1e9);
			for (&rgb) |*v| v.* *= ratio;
		}
	}
	for (&rgb) |*v| switch (tf.transfer_function) {
		.linear => {},
		.srgb => {
			const magnitude = @abs(v.*);
			const encoded = if (magnitude <= 0.0031308) magnitude * 12.92 else 1.055 * std.math.pow(f32, magnitude, 1.0 / 2.4) - 0.055;
			v.* = std.math.copysign(encoded, v.*);
		},
		.bt709 => v.* = if (v.* <= 0.018) v.* * 4.5 else 1.099 * std.math.pow(f32, v.*, 0.45) - 0.099,
		.pq => {
			if (v.* == 0) {
				v.* = 0;
				continue;
			}
			const magnitude: f64 = @abs(v.*);
			const xp = std.math.pow(f64, magnitude * (@as(f64, intensity) / 10000), 2610.0 / 16384.0);
			const encoded: f32 = @floatCast(std.math.pow(f64, (3424.0 / 4096.0 + xp * (2413.0 / 128.0)) / (1 + xp * (2392.0 / 128.0)), 2523.0 / 32.0));
			v.* = std.math.copysign(encoded, v.*);
		},
		.hlg => {
			const magnitude = @abs(v.*);
			const encoded = if (magnitude <= 1.0 / 12.0) @sqrt(3 * magnitude) else 0.17883277 * @log(12 * magnitude - (1 - 4 * 0.17883277)) + 0.5599107295;
			v.* = std.math.copysign(encoded, v.*);
		},
		else => return @import("../base/unsupported.zig").unsupported(.color_encoding),
	};
	return rgb;
}

// Preserve the upstream HLG stage's FastPowf operation sequence, including
// signed reconstructed luminance. lib/jxl/base/fast_math-inl.h supplies the
// range reduction and rational coefficients used here.
fn hlgPower(base: f32, exponent: f32) f32 {
	const bits: i32 = @bitCast(base);
	const shifted = (bits -% 0x3f2aaaab) >> 23;
	const mantissa: f32 = @bitCast(bits -% (shifted << 23));
	const x = mantissa - 1;
	const p = @mulAdd(f32, @mulAdd(f32, 0.74245873327820566, x, 1.4287160470083755), x, -0.000001850383340051831);
	const q = @mulAdd(f32, @mulAdd(f32, 0.17409343003366853, x, 1.0096718572241148), x, 0.9903281427759072);
	const log2 = p / q + @as(f32, @floatFromInt(shifted));
	const power = log2 * exponent;
	const floor = @floor(power);
	if (!std.math.isFinite(floor) or floor >= 2147483648.0 or floor < -2147483648.0) return std.math.pow(f32, base, exponent);
	const whole: i32 = @intFromFloat(floor);
	const scale: f32 = @bitCast((whole +% 127) << 23);
	const fraction = power - floor;
	var num = fraction + 10.1749063;
	num = @mulAdd(f32, num, fraction, 48.8687798);
	num = @mulAdd(f32, num, fraction, 98.5506591);
	num *= scale;
	var den = @mulAdd(f32, fraction, 0.210242958, -0.0222328856);
	den = @mulAdd(f32, den, fraction, -19.4414990);
	den = @mulAdd(f32, den, fraction, 98.5506633);
	return num / den;
}
