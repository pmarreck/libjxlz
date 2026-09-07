#include <jxl/decode.h>
#include <jxl/encode.h>
#include <jxl/color_encoding.h>
#include <cstdio>
#include <vector>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "gray quantization control failed at line %d\n", __LINE__); return 1; } } while (0)
int main() {
	auto* encoder = JxlEncoderCreate(nullptr);
	CHECK(encoder);
	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 3; info.ysize = 1; info.bits_per_sample = 10;
	info.num_color_channels = 1; info.uses_original_profile = JXL_TRUE;
	CHECK(JxlEncoderSetBasicInfo(encoder, &info) == JXL_ENC_SUCCESS);
	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, JXL_TRUE);
	CHECK(JxlEncoderSetColorEncoding(encoder, &color) == JXL_ENC_SUCCESS);
	auto* settings = JxlEncoderFrameSettingsCreate(encoder, nullptr);
	CHECK(JxlEncoderSetFrameLossless(settings, JXL_TRUE) == JXL_ENC_SUCCESS);
	JxlBitDepth depth = {};
	depth.type = JXL_BIT_DEPTH_FROM_CODESTREAM;
	CHECK(JxlEncoderSetFrameBitDepth(settings, &depth) == JXL_ENC_SUCCESS);
	const uint16_t samples[] = {0, 512, 1023};
	const JxlPixelFormat input = {1, JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0};
	CHECK(JxlEncoderAddImageFrame(settings, &input, samples, sizeof(samples)) == JXL_ENC_SUCCESS);
	JxlEncoderCloseInput(encoder);
	std::vector<unsigned char> bytes(4096);
	auto* next = bytes.data(); size_t available = bytes.size();
	CHECK(JxlEncoderProcessOutput(encoder, &next, &available) == JXL_ENC_SUCCESS);
	bytes.resize(bytes.size() - available);
	JxlEncoderDestroy(encoder);
	auto* decoder = JxlDecoderCreate(nullptr);
	CHECK(decoder);
	CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_FULL_IMAGE) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderSetInput(decoder, bytes.data(), bytes.size()) == JXL_DEC_SUCCESS);
	JxlDecoderCloseInput(decoder);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_NEED_IMAGE_OUT_BUFFER);
	const JxlPixelFormat output = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	unsigned char pixels[9];
	CHECK(JxlDecoderSetImageOutBuffer(decoder, &output, pixels, sizeof(pixels)) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_FULL_IMAGE);
	for (auto pixel : pixels) printf("%u,", pixel);
	puts("");
	JxlDecoderDestroy(decoder);
}
