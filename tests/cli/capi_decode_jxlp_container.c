// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <jxl/encode.h>

static void write_u32_be(uint8_t* dst, uint32_t value) {
	dst[0] = (uint8_t)(value >> 24);
	dst[1] = (uint8_t)(value >> 16);
	dst[2] = (uint8_t)(value >> 8);
	dst[3] = (uint8_t)value;
}

int main(void) {
	const uint8_t pixels[] = {
		0x00, 0x10, 0x20,
		0x30, 0x40, 0x50,
		0x60, 0x70, 0x80,
		0x90, 0xA0, 0xB0,
	};
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, JXL_FALSE);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) return 1;
	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
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

	uint8_t codestream[4096];
	uint8_t* next_out = codestream;
	size_t avail_out = sizeof(codestream);
	for (;;) {
		JxlEncoderStatus st = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		if (st == JXL_ENC_SUCCESS) break;
		if (st != JXL_ENC_NEED_MORE_OUTPUT) {
			fprintf(stderr, "encode failed\n");
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	size_t codestream_size = sizeof(codestream) - avail_out;
	JxlEncoderDestroy(enc);

	const size_t split = codestream_size / 2;
	const size_t first_payload = 4 + split;
	const size_t second_payload = 4 + (codestream_size - split);
	const size_t container_size = 12 + 20 + (8 + first_payload) + (8 + second_payload);
	uint8_t* container = malloc(container_size);
	if (!container) return 1;

	size_t offset = 0;
	memcpy(container + offset, "\x00\x00\x00\x0cJXL \x0d\x0a\x87\x0a", 12);
	offset += 12;
	write_u32_be(container + offset, 20);
	memcpy(container + offset + 4, "ftypjxl \x00\x00\x00\x00jxl ", 16);
	offset += 20;

	write_u32_be(container + offset, (uint32_t)(8 + first_payload));
	memcpy(container + offset + 4, "jxlp", 4);
	write_u32_be(container + offset + 8, 0);
	memcpy(container + offset + 12, codestream, split);
	offset += 8 + first_payload;

	write_u32_be(container + offset, (uint32_t)(8 + second_payload));
	memcpy(container + offset + 4, "jxlp", 4);
	write_u32_be(container + offset + 8, 0x80000001u);
	memcpy(container + offset + 12, codestream + split, codestream_size - split);
	offset += 8 + second_payload;

	if (offset != container_size) {
		fprintf(stderr, "container assembly mismatch\n");
		free(container);
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(container);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		free(container);
		JxlDecoderDestroy(dec);
		return 1;
	}
	if (JxlDecoderSetInput(dec, container, container_size) != JXL_DEC_SUCCESS) {
		free(container);
		JxlDecoderDestroy(dec);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	JxlBasicInfo decoded_info;
	memset(&decoded_info, 0, sizeof(decoded_info));
	uint8_t decoded_pixels[sizeof(pixels)];
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &decoded_info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get basic info failed\n");
				free(container);
				JxlDecoderDestroy(dec);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JxlDecoderSetImageOutBuffer(dec, &format, decoded_pixels, sizeof(decoded_pixels)) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "set image out buffer failed\n");
				free(container);
				JxlDecoderDestroy(dec);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) continue;
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected decoder status %d\n", (int)status);
		free(container);
		JxlDecoderDestroy(dec);
		return 1;
	}

	if (decoded_info.have_container != JXL_TRUE) {
		fprintf(stderr, "basic info did not report container\n");
		free(container);
		JxlDecoderDestroy(dec);
		return 1;
	}
	if (memcmp(decoded_pixels, pixels, sizeof(pixels)) != 0) {
		fprintf(stderr, "decoded pixels mismatch\n");
		free(container);
		JxlDecoderDestroy(dec);
		return 1;
	}

	free(container);
	JxlDecoderDestroy(dec);
	return 0;
}
