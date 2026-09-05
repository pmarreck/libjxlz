// AC streams from upstream TokenizeCoefficients and entropy encoding.
#include <algorithm>
#include <cstdio>
#include <vector>
#include "lib/jxl/ac_strategy.h"
#include "lib/jxl/coeff_order.h"
#include "lib/jxl/dec_ans.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/enc_ans.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_entropy_coder.h"
#include "lib/jxl/image_ops.h"
#include "lib/jxl/memory_manager_internal.h"

uint64_t Fold(uint64_t hash, uint32_t value) { return (hash ^ value) * 1099511628211ull; }

jxl::Status GenerateCase(JxlMemoryManager* memory, size_t id) {
	const uint32_t raw = id < 27 ? id : 0;
	const auto first_strategy = jxl::AcStrategy::FromRawStrategy(raw);
	const size_t width = id == 27 || id == 28 ? 4 : first_strategy.covered_blocks_x();
	const size_t height = id == 27 ? 3 : id == 28 ? 4 : first_strategy.covered_blocks_y();
	const bool custom = id % 2 != 0;
	jxl::YCbCrChromaSubsampling chroma;
	const uint8_t sampling[] = {static_cast<uint8_t>(id == 28 ? 2 : 1), 1, 1};
	JXL_RETURN_IF_ERROR(chroma.Set(sampling, sampling));
	JXL_ASSIGN_OR_RETURN(jxl::AcStrategyImage strategies, jxl::AcStrategyImage::Create(memory, width, height));
	strategies.FillDCT8();
	JXL_RETURN_IF_ERROR(strategies.Set(0, 0, static_cast<jxl::AcStrategyType>(id == 27 ? 4 : raw)));
	JXL_ASSIGN_OR_RETURN(jxl::Image3I ac, jxl::Image3I::Create(memory, 64 * width * height, 1));
	jxl::ZeroFillImage(&ac);
	JXL_ASSIGN_OR_RETURN(jxl::Image3I nonzeros, jxl::Image3I::Create(memory, width, height));
	jxl::ZeroFillImage(&nonzeros);
	JXL_ASSIGN_OR_RETURN(jxl::ImageB qdc, jxl::ImageB::Create(memory, width, height));
	JXL_ASSIGN_OR_RETURN(jxl::ImageI qf, jxl::ImageI::Create(memory, width, height));
	jxl::BlockCtxMap context;
	if (custom) {
		context.dc_thresholds[0] = {-10}; context.dc_thresholds[1] = {-5, 6}; context.dc_thresholds[2] = {0};
		context.qf_thresholds = {7}; context.num_dc_ctxs = 12; context.num_ctxs = 4;
		context.ctx_map.resize(3 * 13 * 12 * 2);
		for (size_t i = 0; i < context.ctx_map.size(); ++i) context.ctx_map[i] = ((i / 7) + (i % 5)) % 4;
	}
	for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
		qdc.Row(y)[x] = custom ? (x + y * 3 + id) % 12 : 0;
		qf.Row(y)[x] = 7 + (x + y + id) % 2;
	}
	std::vector<jxl::coeff_order_t> orders(jxl::kCoeffOrderMaxSize);
	for (uint32_t s = 0; s < 27; ++s) {
		const auto strategy = jxl::AcStrategy::FromRawStrategy(s);
		for (size_t c = 0; c < 3; ++c)
			strategy.ComputeNaturalCoeffOrder(&orders[jxl::kCoeffOrderOffset[3 * jxl::kStrategyOrder[s] + c] * 64]);
	}
	size_t offsets[3] = {};
	size_t block_id = 0;
	for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
		const auto strategy = strategies.ConstRow(y)[x];
		if (!strategy.IsFirstBlock()) continue;
		const size_t llf = strategy.covered_blocks_x() * strategy.covered_blocks_y();
		const size_t size = 64 * llf;
		for (size_t c = 0; c < 3; ++c) {
			if ((x >> chroma.HShift(c)) << chroma.HShift(c) != x ||
				(y >> chroma.VShift(c)) << chroma.VShift(c) != y) continue;
			const auto* order = &orders[jxl::kCoeffOrderOffset[3 * jxl::kStrategyOrder[strategy.RawStrategy()] + c] * 64];
			int32_t* block = ac.PlaneRow(c, 0) + offsets[c];
			const size_t end = id == 29 ? size : std::min(size, llf + 80);
			if (c != 1 || block_id % 3 == 1 || id == 29) {
				for (size_t k = llf; k < end; ++k) {
					if (id == 29 || (k - llf + c + block_id) % 7 == 0 || k + 1 == end) {
						int32_t value = static_cast<int32_t>((k * 17 + c * 13 + block_id) % 61) - 30;
						if (value == 0) value = 1;
						block[order[k]] = value;
					}
				}
				block[order[llf]] = c == 0 ? -32768 : 70000;
			}
			offsets[c] += size;
		}
		++block_id;
	}
	const int32_t* rows[] = {ac.ConstPlaneRow(0, 0), ac.ConstPlaneRow(1, 0), ac.ConstPlaneRow(2, 0)};
	std::vector<std::vector<jxl::Token>> tokens(1);
	JXL_RETURN_IF_ERROR(jxl::TokenizeCoefficients(orders.data(), jxl::Rect(0, 0, width, height), rows,
		strategies, chroma, &nonzeros, &tokens[0], qdc, qf, context));
	const auto original = tokens[0];
	uint64_t token_hash = 14695981039346656037ull;
	for (const auto& token : original) token_hash = Fold(Fold(token_hash, token.context), token.value);
	jxl::HistogramParams params;
	params.lz77_method = id == 29 ? jxl::HistogramParams::LZ77Method::kRLE : jxl::HistogramParams::LZ77Method::kNone;
	params.force_huffman = id == 28;
	jxl::EntropyEncodingData code;
	jxl::BitWriter writer(memory);
	JXL_ASSIGN_OR_RETURN(size_t cost, jxl::BuildAndEncodeHistograms(memory, params, context.NumACContexts(), tokens,
		&code, &writer, jxl::LayerType::Ac, nullptr));
	(void)cost;
	const size_t header_bits = writer.BitsWritten();
	JXL_RETURN_IF_ERROR(jxl::WriteTokens(tokens[0], code, 0, &writer, jxl::LayerType::Ac, nullptr));
	const size_t total_bits = writer.BitsWritten();
	writer.ZeroPadToByte();
	jxl::BitReader reader(writer.GetSpan());
	jxl::ANSCode decoded_code;
	std::vector<uint8_t> decoded_context;
	JXL_RETURN_IF_ERROR(jxl::DecodeHistograms(memory, &reader, context.NumACContexts(), &decoded_code, &decoded_context));
	JXL_ASSIGN_OR_RETURN(jxl::ANSSymbolReader symbols, jxl::ANSSymbolReader::Create(&decoded_code, &reader));
	for (const auto& token : original) if (symbols.ReadHybridUint(token.context, &reader, decoded_context) != token.value) return false;
	const bool final_ok = symbols.CheckANSFinalState() && reader.TotalBitsConsumed() == total_bits;
	if (!reader.Close() || !final_ok) return false;
	printf("\t.{ .width=%zu, .height=%zu, .custom=%s, .chroma=%u, .header_bits=%zu, .total_bits=%zu, .token_count=%zu, .token_hash=0x%016llx, .hashes=.{",
		width, height, custom ? "true" : "false", id == 28 ? 4 : 0, header_bits, total_bits,
		original.size(), static_cast<unsigned long long>(token_hash));
	for (size_t c = 0; c < 3; ++c) {
		uint64_t hash = 14695981039346656037ull;
		for (size_t i = 0; i < offsets[c]; ++i) hash = Fold(hash, static_cast<uint32_t>(rows[c][i]));
		printf("0x%016llx,", static_cast<unsigned long long>(hash));
	}
	printf("}, .bytes=&.{");
	for (auto byte : writer.GetSpan()) printf("0x%02x,", byte);
	printf("} },\n");
	return true;
}

int main() {
	JxlMemoryManager memory;
	if (!jxl::MemoryManagerInit(&memory, nullptr)) return 1;
	printf("// Upstream tokenization plus entropy encode/decode, tests/unit/ac_group_oracle.cc.\n");
	printf("pub const Case = struct { width: usize, height: usize, custom: bool, chroma: u8, header_bits: usize, total_bits: usize, token_count: usize, token_hash: u64, hashes: [3]u64, bytes: []const u8 };\npub const cases = [_]Case{\n");
	for (size_t id = 0; id < 30; ++id) if (!GenerateCase(&memory, id)) return 2;
	printf("};\n");
}
