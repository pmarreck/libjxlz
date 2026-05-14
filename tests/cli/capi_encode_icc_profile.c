// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/color_encoding.h>
#include <jxl/decode.h>
#include <jxl/encode.h>

static const uint8_t kSyntheticRgbIcc[128] = {
	0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'm', 'n', 't', 'r',
	'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ',
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'a', 'c', 's', 'p',
};

static const uint8_t kSyntheticCmykIcc[128] = {
	0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'm', 'n', 't', 'r',
	'C', 'M', 'Y', 'K', 'X', 'Y', 'Z', ' ',
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'a', 'c', 's', 'p',
};

static int run_roundtrip(
	const uint8_t* icc,
	size_t icc_size,
	int expect_black_extra
) {
	const uint8_t pixels[12] = {
		0, 10, 20, 30, 40, 50,
		60, 70, 80, 90, 100, 110,
	};
	const uint8_t black_pixels[4] = {
		5, 55,
		105, 155,
	};
	JxlPixelFormat rgb_format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	JxlPixelFormat extra_format = {1, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;
	info.num_extra_channels = expect_black_extra ? 1 : 0;
	info.uses_original_profile = JXL_TRUE;

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
	if (expect_black_extra) {
		JxlExtraChannelInfo black_info;
		JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_BLACK, &black_info);
		if (JxlEncoderSetExtraChannelInfo(enc, 0, &black_info) != JXL_ENC_SUCCESS) {
			fprintf(stderr, "set black extra info failed\n");
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	if (JxlEncoderSetICCProfile(enc, icc, icc_size) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set icc profile failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderAddImageFrame(settings, &rgb_format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add image frame failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (expect_black_extra) {
		if (JxlEncoderSetExtraChannelBuffer(settings, &extra_format, black_pixels, sizeof(black_pixels), 0) != JXL_ENC_SUCCESS) {
			fprintf(stderr, "set black extra buffer failed\n");
			JxlEncoderDestroy(enc);
			return 1;
		}
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
		if (status == JXL_DEC_BASIC_INFO) {
			JxlBasicInfo decoded_info;
			memset(&decoded_info, 0, sizeof(decoded_info));
			if (JxlDecoderGetBasicInfo(dec, &decoded_info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get basic info failed\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (decoded_info.num_extra_channels != (expect_black_extra ? 1u : 0u)) {
				fprintf(stderr, "unexpected extra channel count %u\n", decoded_info.num_extra_channels);
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (expect_black_extra) {
				JxlExtraChannelInfo extra_info;
				memset(&extra_info, 0, sizeof(extra_info));
				if (JxlDecoderGetExtraChannelInfo(dec, 0, &extra_info) != JXL_DEC_SUCCESS) {
					fprintf(stderr, "get extra channel info failed\n");
					JxlDecoderDestroy(dec);
					return 1;
				}
				if (extra_info.type != JXL_CHANNEL_BLACK) {
					fprintf(stderr, "unexpected extra channel type %d\n", (int)extra_info.type);
					JxlDecoderDestroy(dec);
					return 1;
				}
			}
			continue;
		}
		if (status == JXL_DEC_COLOR_ENCODING) {
			size_t decoded_icc_size = 0;
			uint8_t decoded_icc[256];
			if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, NULL) != JXL_DEC_ERROR) {
				fprintf(stderr, "encoded profile unexpectedly available\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &decoded_icc_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc size failed\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (decoded_icc_size != icc_size) {
				fprintf(stderr, "unexpected icc size %zu\n", decoded_icc_size);
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (decoded_icc_size > sizeof(decoded_icc)) {
				fprintf(stderr, "icc buffer too small\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, decoded_icc, sizeof(decoded_icc)) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc profile failed\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
			if (memcmp(decoded_icc, icc, icc_size) != 0) {
				fprintf(stderr, "icc payload mismatch\n");
				JxlDecoderDestroy(dec);
				return 1;
			}
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

int main(void) {
	if (run_roundtrip(kSyntheticRgbIcc, sizeof(kSyntheticRgbIcc), 0) != 0) {
		return 1;
	}
	if (run_roundtrip(kSyntheticCmykIcc, sizeof(kSyntheticCmykIcc), 1) != 0) {
		return 1;
	}
	return 0;
}
