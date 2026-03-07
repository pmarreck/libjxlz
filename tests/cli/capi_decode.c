#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

static uint8_t* read_file(const char* path, size_t* size_out) {
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return NULL;
	}
	long size = ftell(f);
	if (size < 0) {
		fclose(f);
		return NULL;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return NULL;
	}
	uint8_t* data = (uint8_t*)malloc((size_t)size);
	if (!data) {
		fclose(f);
		return NULL;
	}
	if (fread(data, 1, (size_t)size, f) != (size_t)size) {
		fclose(f);
		free(data);
		return NULL;
	}
	fclose(f);
	*size_out = (size_t)size;
	return data;
}

int main(void) {
	size_t input_size = 0;
	uint8_t* input = read_file("src/lib/testdata/lossless_4x4.jxl", &input_size);
	if (!input) {
		fprintf(stderr, "failed to read fixture\n");
		return 1;
	}

	if (JxlSignatureCheck(input, input_size) != JXL_SIG_CODESTREAM) {
		fprintf(stderr, "signature mismatch\n");
		free(input);
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		fprintf(stderr, "decoder create failed\n");
		free(input);
		return 1;
	}

	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "subscribe failed\n");
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}

	if (JxlDecoderSetInput(dec, input, input_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "set input failed\n");
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	JxlBasicInfo info;
	memset(&info, 0, sizeof(info));
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	uint8_t* pixels = NULL;
	size_t pixels_size = 0;
	int saw_basic = 0;
	int saw_full = 0;

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT) {
			fprintf(stderr, "unexpected decoder status %d\n", (int)status);
			free(pixels);
			JxlDecoderDestroy(dec);
			free(input);
			return 1;
		}
		if (status == JXL_DEC_BASIC_INFO) {
			saw_basic = 1;
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "basic info fetch failed\n");
				free(pixels);
				JxlDecoderDestroy(dec);
				free(input);
				return 1;
			}
			if (info.xsize != 4 || info.ysize != 4 || info.num_color_channels != 3) {
				fprintf(stderr, "unexpected basic info %u x %u channels=%u\n",
					info.xsize, info.ysize, info.num_color_channels);
				free(pixels);
				JxlDecoderDestroy(dec);
				free(input);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JxlDecoderImageOutBufferSize(dec, &format, &pixels_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "buffer size failed\n");
				free(pixels);
				JxlDecoderDestroy(dec);
				free(input);
				return 1;
			}
			pixels = (uint8_t*)malloc(pixels_size);
			if (!pixels) {
				fprintf(stderr, "pixel malloc failed\n");
				JxlDecoderDestroy(dec);
				free(input);
				return 1;
			}
			if (JxlDecoderSetImageOutBuffer(dec, &format, pixels, pixels_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "set image buffer failed\n");
				free(pixels);
				JxlDecoderDestroy(dec);
				free(input);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			saw_full = 1;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) break;

		fprintf(stderr, "unexpected informative status %d\n", (int)status);
		free(pixels);
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}

	if (!saw_basic || !saw_full || !pixels) {
		fprintf(stderr, "missing decode milestones\n");
		free(pixels);
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}

	if (pixels[0] != 0 || pixels[1] != 0 || pixels[2] != 128) {
		fprintf(stderr, "unexpected first pixel %u %u %u\n", pixels[0], pixels[1], pixels[2]);
		free(pixels);
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}

	size_t last = pixels_size - 3;
	if (pixels[last + 0] != 255 || pixels[last + 1] != 255 || pixels[last + 2] != 128) {
		fprintf(stderr, "unexpected last pixel %u %u %u\n", pixels[last + 0], pixels[last + 1], pixels[last + 2]);
		free(pixels);
		JxlDecoderDestroy(dec);
		free(input);
		return 1;
	}

	free(pixels);
	JxlDecoderDestroy(dec);
	free(input);
	return 0;
}
