// Generate modular DC streams and dequantized expectations with upstream libjxl.
#include <cstdio>
#include "lib/jxl/compressed_dc.h"
#include "lib/jxl/dec_bit_reader.h"
#include "lib/jxl/enc_aux_out.h"
#include "lib/jxl/enc_bit_writer.h"
#include "lib/jxl/memory_manager_internal.h"
#include "lib/jxl/modular/encoding/enc_encoding.h"
#include "lib/jxl/modular/encoding/encoding.h"

jxl::Status Generate(JxlMemoryManager* memory) {
	printf("// Generated and checked by tests/unit/vardct_dc_oracle.cc.\n");
	for (size_t subsampled = 0; subsampled < 2; ++subsampled) {
		jxl::YCbCrChromaSubsampling chroma;
		const uint8_t sampling[] = {static_cast<uint8_t>(subsampled ? 2 : 1), 1, 1};
		JXL_RETURN_IF_ERROR(chroma.Set(sampling, sampling));
		for (size_t precision = 0; precision < 4; ++precision) {
			JXL_ASSIGN_OR_RETURN(jxl::Image image, jxl::Image::Create(memory, 4, 4, 8, 3));
			JXL_ASSIGN_OR_RETURN(jxl::Image decoded, jxl::Image::Create(memory, 4, 4, 8, 3));
			for (size_t c = 0; c < 3; ++c) {
				const size_t wire_c = c < 2 ? c ^ 1 : c;
				for (auto* img : {&image, &decoded}) {
					auto& channel = img->channel[wire_c];
					channel.w >>= chroma.HShift(c);
					channel.h >>= chroma.VShift(c);
					JXL_RETURN_IF_ERROR(channel.shrink());
				}
				auto& channel = image.channel[wire_c];
				for (size_t y = 0; y < channel.h; ++y)
					for (size_t x = 0; x < channel.w; ++x)
						channel.plane.Row(y)[x] = static_cast<int>((c * 31 + y * 7 + x * 3) % 41) - 20;
			}
			jxl::BitWriter writer(memory);
			JXL_RETURN_IF_ERROR(writer.WithMaxBits(2, jxl::LayerType::Dc, nullptr, [&]() -> jxl::Status {
				writer.Write(2, precision); return true;
			}));
			jxl::ModularOptions options;
			options.tree_kind = jxl::ModularOptions::TreeKind::kTrivialTreeNoPredictor;
			JXL_RETURN_IF_ERROR(jxl::ModularGenericCompress(image, options, writer, nullptr, jxl::LayerType::Dc, 23));
			const size_t bits = writer.BitsWritten();
			writer.ZeroPadToByte();
			jxl::BitReader reader(writer.GetSpan());
			if (reader.ReadFixedBits<2>() != precision) return false;
			const bool decoded_ok = jxl::ModularGenericDecompress(&reader, decoded, nullptr, 23, &options);
			const size_t consumed = reader.TotalBitsConsumed();
			if (!reader.Close() || !decoded_ok || consumed != bits) return false;
			for (size_t c = 0; c < 3; ++c)
				for (size_t y = 0; y < image.channel[c].h; ++y)
					for (size_t x = 0; x < image.channel[c].w; ++x)
						if (decoded.channel[c].plane.Row(y)[x] != image.channel[c].plane.Row(y)[x]) return false;
			JXL_ASSIGN_OR_RETURN(jxl::Image3F output, jxl::Image3F::Create(memory, 4, 4));
			JXL_ASSIGN_OR_RETURN(jxl::ImageB buckets, jxl::ImageB::Create(memory, 4, 4));
			jxl::BlockCtxMap context;
			context.dc_thresholds[0] = {-10};
			context.dc_thresholds[1] = {-5, 6};
			context.dc_thresholds[2] = {0};
			context.num_dc_ctxs = 12;
			const float scales[] = {0.25f, 0.5f, 1.0f};
			const float cfl[] = {-0.5f, 0.0f, 1.25f};
			jxl::DequantDC(jxl::Rect(0, 0, 4, 4), &output, &buckets, decoded, scales,
				1.0f / (1 << precision), cfl, chroma, context);
			const size_t id = subsampled * 4 + precision;
			printf("pub const bits_%zu: usize = %zu;\npub const stream_%zu = [_]u8{", id, bits, id);
			for (auto byte : writer.GetSpan()) printf("0x%02x,", byte);
			printf("};\npub const samples_%zu = [_]i32{", id);
			for (size_t c = 0; c < 3; ++c)
				for (size_t y = 0; y < (4u >> chroma.VShift(c)); ++y)
					for (size_t x = 0; x < (4u >> chroma.HShift(c)); ++x)
						printf("%d,", static_cast<int>(output.PlaneRow(c, y)[x] * 64));
			printf("};\npub const buckets_%zu = [_]u8{", id);
			for (size_t y = 0; y < 4; ++y)
				for (size_t x = 0; x < 4; ++x) printf("%u,", buckets.Row(y)[x]);
			printf("};\n");
		}
	}
	return true;
}

int main() {
	JxlMemoryManager memory;
	if (!jxl::MemoryManagerInit(&memory, nullptr)) return 1;
	return Generate(&memory) ? 0 : 2;
}
