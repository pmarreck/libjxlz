#include <jxl/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "encoded preview decoder control failed at line %d\n", __LINE__); return 1; } } while (0)
int main(int argc, char** argv) {
	CHECK(argc == 2 || argc == 3);
	const int expected_frames = argc == 3 ? atoi(argv[2]) : 1;
	FILE* file = fopen(argv[1], "rb");
	CHECK(file);
	CHECK(fseek(file, 0, SEEK_END) == 0);
	const long length = ftell(file);
	CHECK(length > 0 && length < 65536);
	CHECK(fseek(file, 0, SEEK_SET) == 0);
	uint8_t* bytes = malloc((size_t)length);
	CHECK(bytes);
	CHECK(fread(bytes, 1, (size_t)length, file) == (size_t)length);
	CHECK(fclose(file) == 0);
	const uint8_t expected[] = {0,10,20,30,40,50,60,70,80,90,100,110};
	uint8_t preview[3], pixels[12];
	const JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	JxlDecoder* decoder = JxlDecoderCreate(NULL);
	CHECK(decoder);
	CHECK(JxlDecoderSubscribeEvents(decoder, JXL_DEC_PREVIEW_IMAGE | JXL_DEC_FULL_IMAGE) == JXL_DEC_SUCCESS);
	CHECK(JxlDecoderSetInput(decoder, bytes, (size_t)length) == JXL_DEC_SUCCESS);
	JxlDecoderCloseInput(decoder);
	int previews = 0, frames = 0;
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
		if (status == JXL_DEC_NEED_PREVIEW_OUT_BUFFER) {
			size_t size = 0;
			CHECK(JxlDecoderPreviewOutBufferSize(decoder, &format, &size) == JXL_DEC_SUCCESS && size == sizeof(preview));
			CHECK(JxlDecoderSetPreviewOutBuffer(decoder, &format, preview, sizeof(preview)) == JXL_DEC_SUCCESS);
		} else if (status == JXL_DEC_PREVIEW_IMAGE) {
			CHECK(memcmp(preview, expected, sizeof(preview)) == 0);
			++previews;
		} else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			size_t size = 0;
			CHECK(JxlDecoderImageOutBufferSize(decoder, &format, &size) == JXL_DEC_SUCCESS && size == sizeof(pixels));
			CHECK(JxlDecoderSetImageOutBuffer(decoder, &format, pixels, sizeof(pixels)) == JXL_DEC_SUCCESS);
		} else if (status == JXL_DEC_FULL_IMAGE) {
			CHECK(memcmp(pixels, expected, sizeof(pixels)) == 0);
			++frames;
		} else if (status == JXL_DEC_SUCCESS) break;
		else CHECK(0);
	}
	CHECK(previews == 1 && frames == expected_frames);
	JxlDecoderDestroy(decoder);
	free(bytes);
	return 0;
}
