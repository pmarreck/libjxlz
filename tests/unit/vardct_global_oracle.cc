// Generate block-context and CfL wire fixtures with retained upstream libjxl.
#include <cstdio>
#include <vector>
#include "lib/jxl/ac_context.h"
#include "lib/jxl/chroma_from_luma.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_bit_writer.h"
#include "lib/jxl/enc_context_map.h"
#include "lib/jxl/entropy_coder.h"
#include "lib/jxl/fields.h"
#include "lib/jxl/memory_manager_internal.h"

void PrintBytes(const char* name, jxl::BitWriter& writer) {
	printf("pub const %s_bits: usize = %zu;\n", name, writer.BitsWritten());
	writer.ZeroPadToByte();
	printf("pub const %s = [_]u8{", name);
	size_t index = 0;
	for (auto byte : writer.GetSpan()) {
		printf(index++ % 12 == 0 ? "\n\t0x%02x," : " 0x%02x,", byte);
	}
	printf("\n};\n");
}

int main() {
	JxlMemoryManager memory;
	if (!jxl::MemoryManagerInit(&memory, nullptr)) return 1;
	jxl::BlockCtxMap model;
	model.dc_thresholds[0] = {-10};
	model.dc_thresholds[1] = {-5, 6};
	model.dc_thresholds[2] = {0};
	model.qf_thresholds = {7};
	model.num_dc_ctxs = 12;
	model.num_ctxs = 4;
	model.ctx_map.resize(3 * 13 * 12 * 2);
	for (size_t i = 0; i < model.ctx_map.size(); ++i) model.ctx_map[i] = ((i / 7) + (i % 5)) % 4;
	jxl::BitWriter writer(&memory);
	if (!jxl::EncodeBlockCtxMap(model, &writer, nullptr)) return 2;
	printf("// Generated and cross-checked by tests/unit/vardct_global_oracle.cc.\n");
	PrintBytes("block_context", writer);
	jxl::BitReader reader(writer.GetSpan());
	jxl::BlockCtxMap decoded;
	const bool ok = jxl::DecodeBlockCtxMap(&memory, &reader, &decoded);
	if (!reader.Close() || !ok || decoded.ctx_map != model.ctx_map) return 3;
	uint64_t hash = 14695981039346656037ull;
	for (size_t dc = 0; dc < 12; ++dc)
		for (uint32_t qf : {0u, 7u, 8u, 255u})
			for (size_t order = 0; order < 13; ++order)
				for (size_t c = 0; c < 3; ++c)
					hash = (hash ^ decoded.Context(dc, qf, order, c)) * 1099511628211ull;
	printf("pub const block_context_lookup_hash: u64 = 0x%016llx;\n", (unsigned long long)hash);
	jxl::BitWriter cfl(&memory);
	if (!cfl.WithMaxBits(100, jxl::LayerType::Header, nullptr, [&]() -> jxl::Status {
		cfl.Write(1, 0);
		if (!jxl::U32Coder::Write(jxl::kColorFactorDist, 256, &cfl)) return false;
		if (!jxl::F16Coder::Write(-1.5f, &cfl) || !jxl::F16Coder::Write(0.75f, &cfl)) return false;
		cfl.Write(8, 0);
		cfl.Write(8, 255);
		return true;
	})) return 4;
	PrintBytes("cfl", cfl);
	jxl::BitReader cfl_reader(cfl.GetSpan());
	jxl::ColorCorrelation correlation;
	const bool cfl_ok = correlation.DecodeDC(&cfl_reader);
	if (!cfl_reader.Close() || !cfl_ok || correlation.DCFactors()[0] != -2.0f ||
		correlation.DCFactors()[2] != 319.0f / 256.0f) return 5;
}
