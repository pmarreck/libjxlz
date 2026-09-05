//! VarDCT global quantization parameters and integer-only coefficient scales.
//! Wire layout and bounds follow lib/jxl/quantizer.{h,cc}.

const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const sf = @import("../base/soft_float.zig");
const fc = @import("field_coders.zig");

pub const Quantizer = struct {
	pub const kQuantMax = 256;
	const kGlobalScaleDenom = sf.fromInt(1 << 16);

	global_scale: u32,
	quant_dc: u32,

	pub fn init(global_scale: u32, quant_dc: u32) JxlError!Quantizer {
		if (global_scale == 0 or global_scale > 73728 or quant_dc == 0 or quant_dc > 65536)
			return error.GenericError;
		return .{ .global_scale = global_scale, .quant_dc = quant_dc };
	}

	/// Read both U32 selectors without treating zero-filled overread as a
	/// valid positive scale. The reader stays open for the following fields.
	pub fn decode(br: *BitReader) JxlError!Quantizer {
		const global_scale = fc.U32Coder.read(fc.U32Enc.init(
			fc.bitsOffset(11, 1), fc.bitsOffset(11, 2049),
			fc.bitsOffset(12, 4097), fc.bitsOffset(16, 8193),
		), br);
		const quant_dc = fc.U32Coder.read(fc.U32Enc.init(
			fc.val(16), fc.bitsOffset(5, 1), fc.bitsOffset(8, 1), fc.bitsOffset(16, 1),
		), br);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		return init(global_scale, quant_dc);
	}

	pub fn scale(self: Quantizer) sf.Fixed {
		return sf.div(sf.fromInt(self.global_scale), kGlobalScaleDenom);
	}

	pub fn invGlobalScale(self: Quantizer) sf.Fixed {
		return sf.div(kGlobalScaleDenom, sf.fromInt(self.global_scale));
	}

	pub fn invQuantDC(self: Quantizer) sf.Fixed {
		return sf.div(self.invGlobalScale(), sf.fromInt(self.quant_dc));
	}

	/// Scale a transform's AC coefficients before applying its dequant matrix.
	pub fn invQuantAC(self: Quantizer, quant: u32) JxlError!sf.Fixed {
		if (quant == 0 or quant > kQuantMax) return error.GenericError;
		return sf.div(self.invGlobalScale(), sf.fromInt(quant));
	}

	pub fn dcSteps(self: Quantizer, dc_quant: [3]sf.Fixed) [3]sf.Fixed {
		const inv_quant_dc = self.invQuantDC();
		var steps: [3]sf.Fixed = undefined;
		for (dc_quant, &steps) |weight, *step| step.* = sf.mul(inv_quant_dc, weight);
		return steps;
	}
};
