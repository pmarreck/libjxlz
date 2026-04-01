// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

int main(int argc, char** argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s FILE.jxl\n", argv[0]);
		return 2;
	}

	FILE* f = fopen(argv[1], "rb");
	if (!f) {
		fprintf(stderr, "open failed\n");
		return 1;
	}
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		fprintf(stderr, "seek failed\n");
		return 1;
	}
	long end = ftell(f);
	if (end < 0 || fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		fprintf(stderr, "tell/rewind failed\n");
		return 1;
	}
	size_t size = (size_t)end;
	uint8_t* data = (uint8_t*)malloc(size);
	if (!data) {
		fclose(f);
		fprintf(stderr, "malloc failed\n");
		return 1;
	}
	if (fread(data, 1, size, f) != size) {
		fclose(f);
		free(data);
		fprintf(stderr, "read failed\n");
		return 1;
	}
	fclose(f);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(data);
		fprintf(stderr, "decoder create failed\n");
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		free(data);
		fprintf(stderr, "decoder subscribe failed\n");
		return 1;
	}
	if (JxlDecoderSetInput(dec, data, size) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		free(data);
		fprintf(stderr, "decoder set input failed\n");
		return 1;
	}
	JxlDecoderCloseInput(dec);

	JxlBasicInfo info;
	memset(&info, 0, sizeof(info));
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				JxlDecoderDestroy(dec);
				free(data);
				fprintf(stderr, "basic info failed\n");
				return 1;
			}
			break;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR) {
			JxlDecoderDestroy(dec);
			free(data);
			fprintf(stderr, "decoder failed before basic info\n");
			return 1;
		}
	}

	JxlExtraChannelInfo extra;
	memset(&extra, 0, sizeof(extra));
	if (info.num_extra_channels == 0) {
		fprintf(stderr, "no extra channels\n");
		JxlDecoderDestroy(dec);
		free(data);
		return 1;
	}
	if (JxlDecoderGetExtraChannelInfo(dec, 0, &extra) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		free(data);
		fprintf(stderr, "extra channel info failed\n");
		return 1;
	}

	printf(
		"%u %u %u %u %u %u %d %u %u\n",
		info.xsize,
		info.ysize,
		info.num_color_channels,
		info.num_extra_channels,
		info.alpha_bits,
		info.alpha_premultiplied,
		(int)extra.type,
		extra.dim_shift,
		extra.cfa_channel
	);

	JxlDecoderDestroy(dec);
	free(data);
	return 0;
}
