// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
	JxlEncoderInitBasicInfo(&info);
	info.have_container = JXL_TRUE;
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

	uint8_t encoded[4096];
	uint8_t* next_out = encoded;
	size_t avail_out = sizeof(encoded);
	for (;;) {
		JxlEncoderStatus st = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		if (st == JXL_ENC_SUCCESS) break;
		if (st != JXL_ENC_NEED_MORE_OUTPUT) {
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	size_t encoded_size = sizeof(encoded) - avail_out;
	JxlEncoderDestroy(enc);

	if (JxlSignatureCheck(encoded, encoded_size) != JXL_SIG_CONTAINER) {
		fprintf(stderr, "container signature mismatch\n");
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) return 1;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		return 1;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
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
				JxlDecoderDestroy(dec);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JxlDecoderSetImageOutBuffer(dec, &format, decoded_pixels, sizeof(decoded_pixels)) != JXL_DEC_SUCCESS) {
				JxlDecoderDestroy(dec);
				return 1;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) continue;
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected decoder status %d\n", (int)status);
		JxlDecoderDestroy(dec);
		return 1;
	}

	if (decoded_info.have_container != JXL_TRUE) {
		fprintf(stderr, "basic info did not report container\n");
		JxlDecoderDestroy(dec);
		return 1;
	}
	if (memcmp(decoded_pixels, pixels, sizeof(pixels)) != 0) {
		fprintf(stderr, "pixel roundtrip mismatch\n");
		JxlDecoderDestroy(dec);
		return 1;
	}

	JxlDecoderDestroy(dec);
	return 0;
}
