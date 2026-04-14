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

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) {
		fprintf(stderr, "encoder create failed\n");
		return 1;
	}
	JxlEncoderFrameSettings* frame_settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!frame_settings) {
		fprintf(stderr, "frame settings failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set basic info failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
	color.primaries = JXL_PRIMARIES_P3;
	color.transfer_function = JXL_TRANSFER_FUNCTION_HLG;
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set color encoding failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}

	JxlPixelFormat format;
	memset(&format, 0, sizeof(format));
	format.num_channels = 3;
	format.data_type = JXL_TYPE_UINT8;
	format.endianness = JXL_NATIVE_ENDIAN;
	if (JxlEncoderAddImageFrame(frame_settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add frame failed\n");
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
			fprintf(stderr, "process output failed\n");
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	size_t encoded_size = sizeof(encoded) - avail_out;
	JxlEncoderDestroy(enc);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		fprintf(stderr, "decoder create failed\n");
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder subscribe failed\n");
		JxlDecoderDestroy(dec);
		return 1;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder set input failed\n");
		JxlDecoderDestroy(dec);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) continue;
		if (status == JXL_DEC_COLOR_ENCODING) {
			JxlColorEncoding decoded;
			memset(&decoded, 0, sizeof(decoded));
			if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &decoded) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get encoded profile failed\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			printf("%d %d %d %.6f %d\n",
				(int)decoded.color_space,
				(int)decoded.primaries,
				(int)decoded.transfer_function,
				decoded.gamma,
				(int)decoded.rendering_intent);
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR) {
			fprintf(stderr, "decoder failed before color encoding\n");
			JxlDecoderDestroy(dec);
			return 1;
		}
	}
}
