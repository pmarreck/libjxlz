// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/color_encoding.h>
#include <jxl/decode.h>
#include <jxl/encode.h>

int main(void) {
	const uint8_t pixels[] = {
		0x00, 0x10, 0x20,
		0x30, 0x40, 0x50,
		0x60, 0x70, 0x80,
		0x90, 0xA0, 0xB0,
	};
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	JxlBasicInfo info;
	JxlColorEncoding color;
	uint8_t encoded[4096];
	uint8_t* next_out = encoded;
	size_t avail_out = sizeof(encoded);

	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	JxlColorEncodingSetToLinearSRGB(&color, JXL_FALSE);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) return 1;
	JxlEncoderFrameSettings* frame_settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!frame_settings) return 1;
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) return 1;
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) return 1;
	if (JxlEncoderAddImageFrame(frame_settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) return 1;
	JxlEncoderCloseInput(enc);
	for (;;) {
		JxlEncoderStatus st = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		if (st == JXL_ENC_SUCCESS) break;
		if (st != JXL_ENC_NEED_MORE_OUTPUT) return 1;
	}
	JxlEncoderDestroy(enc);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) return 1;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) return 1;
	if (JxlDecoderSetInput(dec, encoded, sizeof(encoded) - avail_out) != JXL_DEC_SUCCESS) return 1;
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) continue;
		if (status == JXL_DEC_COLOR_ENCODING) {
			size_t icc_size = 0;
			uint8_t* icc = NULL;
			if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &icc_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc profile size failed\n");
				return 1;
			}
			if (icc_size != 600) {
				fprintf(stderr, "unexpected icc size %zu\n", icc_size);
				return 1;
			}
			icc = (uint8_t*)malloc(icc_size);
			if (!icc) return 1;
			if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, icc, icc_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc profile failed\n");
				free(icc);
				return 1;
			}
			if (
				memcmp(icc + 16, "RGB XYZ ", 8) != 0 ||
				memcmp(icc + 36, "acsp", 4) != 0 ||
				memcmp(icc + 264, "mluc", 4) != 0
			) {
				fprintf(stderr, "unexpected linear icc contents\n");
				free(icc);
				return 1;
			}
			free(icc);
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR) return 1;
	}
}
