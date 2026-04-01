// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
	const uint8_t rgb_pixels[24] = {
		4, 8, 12, 6, 10, 14, 8, 12, 16, 10, 14, 18,
		3, 6, 9, 5, 8, 11, 7, 10, 13, 9, 12, 15,
	};
	const uint8_t alpha_pixels[2] = { 200, 50 };
	JxlPixelFormat rgb_format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	JxlPixelFormat alpha_format = {1, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 4;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = 1;
	info.alpha_bits = 8;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, 0);

	JxlExtraChannelInfo alpha;
	JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha);
	alpha.dim_shift = 1;

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
	if (JxlEncoderSetExtraChannelInfo(enc, 0, &alpha) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set alpha info failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderAddImageFrame(settings, &rgb_format, rgb_pixels, sizeof(rgb_pixels)) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add image frame failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, alpha_pixels, sizeof(alpha_pixels), 0) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set alpha buffer failed\n");
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
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
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

	JxlBasicInfo decoded_info;
	memset(&decoded_info, 0, sizeof(decoded_info));
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &decoded_info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "decoder basic info failed\n");
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			break;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR) {
			fprintf(stderr, "decoder failed before basic info\n");
			JxlDecoderDestroy(dec);
			free(encoded);
			return 1;
		}
	}

	JxlExtraChannelInfo decoded_alpha;
	memset(&decoded_alpha, 0, sizeof(decoded_alpha));
	if (JxlDecoderGetExtraChannelInfo(dec, 0, &decoded_alpha) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder extra info failed\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}

	if (
		decoded_info.xsize != 4 ||
		decoded_info.ysize != 2 ||
		decoded_info.num_extra_channels != 1 ||
		decoded_info.alpha_bits != 8 ||
		decoded_alpha.type != JXL_CHANNEL_ALPHA ||
		decoded_alpha.dim_shift != 1
	) {
		fprintf(stderr, "unexpected decoded alpha info\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}

	JxlDecoderDestroy(dec);
	free(encoded);
	return 0;
}
