#include <jxl/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "preview check failed at line %d\n", __LINE__); return 1; } } while (0)

static const uint8_t input[] = {
	0xff, 0x0a, 0x08, 0x00, 0x02, 0x08, 0x01, 0x00, 0x00, 0x62, 0x02, 0x08,
	0x02, 0x01, 0x00, 0x4c, 0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00,
	0xc2, 0x8d, 0x4c, 0xc2, 0x1d, 0x94, 0x9f, 0x0d, 0x00, 0x0e, 0xf0, 0x3e,
	0x08, 0x02, 0x01, 0x00, 0x68, 0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02,
	0x00, 0xc2, 0x8d, 0x78, 0x1b, 0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f,
	0x94, 0xc8, 0xff, 0xa0, 0xa9, 0x14, 0xbc, 0x07,
};

static int check(JxlDecoder *decoder) {
	const JxlPixelFormat format = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
	const uint8_t expected_preview[] = { 255, 0, 0, 0xa5 };
	const uint8_t expected_main[] = { 0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110 };
	size_t size = 123;
	uint8_t preview[4], main_image[12];
	CHECK(JxlDecoderPreviewOutBufferSize(decoder, &format, &size) == JXL_DEC_NEED_MORE_INPUT);
	CHECK(size == 123);
	for (int pass = 0; pass < 3; ++pass) {
		if (pass == 1) JxlDecoderRewind(decoder);
		if (pass == 2) JxlDecoderReset(decoder);
		if (pass != 1) CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_PREVIEW_IMAGE | JXL_DEC_FULL_IMAGE) == JXL_DEC_SUCCESS);
		CHECK(JxlDecoderSetInput(decoder, input, sizeof(input)) == JXL_DEC_SUCCESS);
		JxlDecoderCloseInput(decoder);
		memset(preview, 0xa5, sizeof(preview));
		CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_NEED_PREVIEW_OUT_BUFFER);
		const uint32_t channels[] = { 0, 1, 2, 3, 4, 5, UINT32_MAX };
		const JxlDecoderStatus statuses[] = { JXL_DEC_ERROR, JXL_DEC_ERROR, JXL_DEC_ERROR, JXL_DEC_SUCCESS, JXL_DEC_SUCCESS, JXL_DEC_ERROR, JXL_DEC_ERROR };
		for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); ++i) {
			JxlPixelFormat candidate = format;
			candidate.num_channels = channels[i];
			CHECK(JxlDecoderPreviewOutBufferSize(decoder, &candidate, &size) == statuses[i]);
			CHECK(JxlDecoderImageOutBufferSize(decoder, &candidate, &size) == statuses[i]);
		}
		CHECK(JxlDecoderPreviewOutBufferSize(decoder, &format, &size) == JXL_DEC_SUCCESS);
		CHECK(size == 3);
		CHECK(JxlDecoderSetPreviewOutBuffer(decoder, &format, preview, 2) == JXL_DEC_ERROR);
		CHECK(JxlDecoderSetPreviewOutBuffer(decoder, &format, preview, sizeof(preview)) == JXL_DEC_SUCCESS);
		CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_PREVIEW_IMAGE);
		CHECK(memcmp(preview, expected_preview, sizeof(preview)) == 0);
		CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_NEED_IMAGE_OUT_BUFFER);
		CHECK(JxlDecoderSetImageOutBuffer(decoder, &format, main_image, sizeof(main_image)) == JXL_DEC_SUCCESS);
		CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_FULL_IMAGE);
		CHECK(memcmp(main_image, expected_main, sizeof(main_image)) == 0);
		CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_SUCCESS);
	}
	return 0;
}

static int check_padding(JxlDecoder *decoder) {
	JxlDecoderReset(decoder);
	const JxlPixelFormat format = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 8 };
	const uint8_t expected_preview[] = { 255, 0, 0, 0xa5 };
	const uint8_t expected_main[] = { 0, 10, 20, 30, 40, 50, 0xa5, 0xa5, 60, 70, 80, 90, 100, 110, 0xa5, 0xa5 };
	uint8_t preview[4], main_image[16];
	memset(preview, 0xa5, sizeof(preview));
	memset(main_image, 0xa5, sizeof(main_image));
	size_t size = 0;
	CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_PREVIEW_IMAGE | JXL_DEC_FULL_IMAGE) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderSetInput(decoder, input, sizeof(input)) == JXL_DEC_SUCCESS);
	JxlDecoderCloseInput(decoder);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_NEED_PREVIEW_OUT_BUFFER);
	CHECK(JxlDecoderPreviewOutBufferSize(decoder, &format, &size) == JXL_DEC_SUCCESS);
	CHECK(size == 3);
	CHECK(JxlDecoderSetPreviewOutBuffer(decoder, &format, preview, 3) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_PREVIEW_IMAGE);
	CHECK(memcmp(preview, expected_preview, sizeof(preview)) == 0);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_NEED_IMAGE_OUT_BUFFER);
	CHECK(JxlDecoderImageOutBufferSize(decoder, &format, &size) == JXL_DEC_SUCCESS);
	CHECK(size == 14);
	CHECK(JxlDecoderSetImageOutBuffer(decoder, &format, main_image, 14) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_FULL_IMAGE);
	CHECK(memcmp(main_image, expected_main, sizeof(main_image)) == 0);
	return 0;
}

static int check_subscription(JxlDecoder *decoder) {
	JxlDecoderReset(decoder);
	const JxlPixelFormat format = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
	uint8_t preview[3];
	CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderSetInput(decoder, input, sizeof(input)) == JXL_DEC_SUCCESS);
	JxlDecoderCloseInput(decoder);
	CHECK(JxlDecoderProcessInput(decoder) == JXL_DEC_BASIC_INFO);
	CHECK(JxlDecoderSetPreviewOutBuffer(decoder, &format, preview, sizeof(preview)) == JXL_DEC_ERROR);
	return 0;
}

int main(void) {
	JxlDecoder *decoder = JxlDecoderCreate(NULL);
	if (!decoder) return 1;
	int result = check(decoder);
	if (!result) result = check_padding(decoder);
	if (!result) result = check_subscription(decoder);
	JxlDecoderDestroy(decoder);
	return result;
}
