// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/color_encoding.h>
#include <jxl/decode.h>

static uint8_t* read_path(const char* path, size_t* size_out) {
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return NULL;
	}
	long end = ftell(f);
	if (end < 0) {
		fclose(f);
		return NULL;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return NULL;
	}
	size_t size = (size_t)end;
	uint8_t* data = (uint8_t*)malloc(size == 0 ? 1 : size);
	if (!data) {
		fclose(f);
		return NULL;
	}
	if (size != 0 && fread(data, 1, size, f) != size) {
		free(data);
		fclose(f);
		return NULL;
	}
	fclose(f);
	*size_out = size;
	return data;
}

int main(int argc, char** argv) {
	if (argc != 3 && argc != 4) {
		fprintf(stderr, "usage: %s FILE.jxl FILE.icc [expect-black-extra]\n", argv[0]);
		return 1;
	}

	const int expect_black_extra = argc == 4 && strcmp(argv[3], "expect-black-extra") == 0;
	size_t jxl_size = 0;
	size_t icc_size = 0;
	uint8_t* jxl = read_path(argv[1], &jxl_size);
	uint8_t* expected_icc = read_path(argv[2], &icc_size);
	JxlDecoder* dec = NULL;
	uint8_t* decoded_icc = NULL;

	if (!jxl || !expected_icc) {
		fprintf(stderr, "read failed\n");
		free(jxl);
		free(expected_icc);
		return 1;
	}

	dec = JxlDecoderCreate(NULL);
	if (!dec) {
		fprintf(stderr, "decoder create failed\n");
		goto fail;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder subscribe failed\n");
		goto fail;
	}
	if (JxlDecoderSetInput(dec, jxl, jxl_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "decoder set input failed\n");
		goto fail;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			JxlBasicInfo info;
			memset(&info, 0, sizeof(info));
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get basic info failed\n");
				goto fail;
			}
			if (info.num_extra_channels != (expect_black_extra ? 1u : 0u)) {
				fprintf(stderr, "unexpected extra channel count %u\n", info.num_extra_channels);
				goto fail;
			}
			if (expect_black_extra) {
				JxlExtraChannelInfo extra_info;
				memset(&extra_info, 0, sizeof(extra_info));
				if (JxlDecoderGetExtraChannelInfo(dec, 0, &extra_info) != JXL_DEC_SUCCESS) {
					fprintf(stderr, "get extra channel info failed\n");
					goto fail;
				}
				if (extra_info.type != JXL_CHANNEL_BLACK) {
					fprintf(stderr, "unexpected extra channel type %d\n", (int)extra_info.type);
					goto fail;
				}
			}
			continue;
		}
		if (status == JXL_DEC_COLOR_ENCODING) {
			size_t decoded_icc_size = 0;
			if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, NULL) != JXL_DEC_ERROR) {
				fprintf(stderr, "encoded profile unexpectedly available\n");
				goto fail;
			}
			if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &decoded_icc_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc size failed\n");
				goto fail;
			}
			if (decoded_icc_size != icc_size) {
				fprintf(stderr, "unexpected icc size %zu\n", decoded_icc_size);
				goto fail;
			}
			decoded_icc = (uint8_t*)malloc(decoded_icc_size == 0 ? 1 : decoded_icc_size);
			if (!decoded_icc) {
				fprintf(stderr, "alloc decoded icc failed\n");
				goto fail;
			}
			if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, decoded_icc, decoded_icc_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get icc profile failed\n");
				goto fail;
			}
			if (memcmp(decoded_icc, expected_icc, icc_size) != 0) {
				fprintf(stderr, "icc payload mismatch\n");
				goto fail;
			}
			free(decoded_icc);
			free(expected_icc);
			free(jxl);
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR || status == JXL_DEC_SUCCESS) {
			fprintf(stderr, "decoder failed before color encoding\n");
			goto fail;
		}
	}

fail:
	free(decoded_icc);
	free(expected_icc);
	free(jxl);
	JxlDecoderDestroy(dec);
	return 1;
}
