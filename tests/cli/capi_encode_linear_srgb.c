#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/color_encoding.h>
#include <jxl/decode.h>
#include <jxl/encode.h>

static int append_chunk(uint8_t** out, size_t* size, size_t* cap, const uint8_t* chunk, size_t chunk_size) {
	if (*size + chunk_size > *cap) {
		size_t new_cap = *cap ? *cap : 256;
		while (new_cap < *size + chunk_size) new_cap *= 2;
		uint8_t* grown = (uint8_t*)realloc(*out, new_cap);
		if (!grown) return 0;
		*out = grown;
		*cap = new_cap;
	}
	memcpy(*out + *size, chunk, chunk_size);
	*size += chunk_size;
	return 1;
}

int main(void) {
	const uint8_t pixels[12] = {
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 0;
	info.alpha_bits = 0;

	JxlColorEncoding color;
	JxlColorEncodingSetToLinearSRGB(&color, 0);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) {
		fprintf(stderr, "encoder create failed\n");
		return 1;
	}

	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
		fprintf(stderr, "frame settings create failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}

	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set basic info failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set color encoding failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderAddImageFrame(settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add image frame failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	JxlEncoderCloseInput(enc);

	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	size_t encoded_cap = 0;
	for (;;) {
		uint8_t chunk[17];
		uint8_t* next_out = chunk;
		size_t avail_out = sizeof(chunk);
		JxlEncoderStatus status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		size_t produced = sizeof(chunk) - avail_out;
		if (produced && !append_chunk(&encoded, &encoded_size, &encoded_cap, chunk, produced)) {
			fprintf(stderr, "append failed\n");
			free(encoded);
			JxlEncoderDestroy(enc);
			return 1;
		}
		if (status == JXL_ENC_SUCCESS) break;
		if (status != JXL_ENC_NEED_MORE_OUTPUT) {
			fprintf(stderr, "unexpected encoder status %d\n", (int)status);
			free(encoded);
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	JxlEncoderDestroy(enc);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		fprintf(stderr, "decoder create failed\n");
		free(encoded);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder subscribe failed\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder set input failed\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	uint8_t* decoded_pixels = NULL;
	size_t decoded_size = 0;
	int saw_color = 0;
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			continue;
		}
		if (status == JXL_DEC_COLOR_ENCODING) {
			JxlColorEncoding decoded_color;
			memset(&decoded_color, 0, sizeof(decoded_color));
			if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &decoded_color) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "decoder color encoding failed\n");
				free(decoded_pixels);
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			if (
				decoded_color.color_space != JXL_COLOR_SPACE_RGB ||
				decoded_color.primaries != JXL_PRIMARIES_SRGB ||
				decoded_color.transfer_function != JXL_TRANSFER_FUNCTION_LINEAR ||
				decoded_color.rendering_intent != JXL_RENDERING_INTENT_RELATIVE
			) {
				fprintf(stderr, "unexpected encoded color profile\n");
				free(decoded_pixels);
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			saw_color = 1;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JxlDecoderImageOutBufferSize(dec, &format, &decoded_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "decoder buffer size failed\n");
				free(decoded_pixels);
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			decoded_pixels = (uint8_t*)malloc(decoded_size);
			if (!decoded_pixels) {
				fprintf(stderr, "decoder malloc failed\n");
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			if (JxlDecoderSetImageOutBuffer(dec, &format, decoded_pixels, decoded_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "decoder set image buffer failed\n");
				free(decoded_pixels);
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) continue;
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected decoder status %d\n", (int)status);
		free(decoded_pixels);
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}

	if (!saw_color) {
		fprintf(stderr, "missing color encoding event\n");
		free(decoded_pixels);
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}
	if (decoded_size != sizeof(pixels) || memcmp(decoded_pixels, pixels, sizeof(pixels)) != 0) {
		fprintf(stderr, "pixel roundtrip mismatch\n");
		free(decoded_pixels);
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}

	free(decoded_pixels);
	JxlDecoderDestroy(dec);
	free(encoded);
	return 0;
}
