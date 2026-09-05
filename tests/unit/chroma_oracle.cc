#include <cstdio>
#include "lib/jxl/frame_header.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/fields.h"
int main() {
	printf("// Retained upstream libjxl: every six-bit chroma sampling form.\n");
	printf("pub const cases = [64][9]u8{\n");
	for (uint8_t bits = 0; bits < 64; ++bits) {
		jxl::BitReader reader(jxl::Span<const uint8_t>(&bits, 1));
		jxl::YCbCrChromaSubsampling chroma;
		const bool ok = jxl::Bundle::Read(&reader, &chroma);
		if (!reader.Close() || !ok) return 1;
		printf("\t.{");
		for (size_t c = 0; c < 3; ++c) printf("%zu,%zu,", chroma.HShift(c), chroma.VShift(c));
		printf("%u,%u,%u},\n", chroma.MaxHShift(), chroma.MaxVShift(), chroma.Is444());
	}
	printf("};\n");
}
