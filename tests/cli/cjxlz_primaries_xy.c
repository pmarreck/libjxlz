// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

int main(int argc, char** argv) {
	if (argc != 2) return 2;

	FILE* f = fopen(argv[1], "rb");
	if (!f) return 1;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return 1;
	}
	long end = ftell(f);
	if (end < 0 || fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return 1;
	}
	size_t size = (size_t)end;
	uint8_t* data = (uint8_t*)malloc(size);
	if (!data) {
		fclose(f);
		return 1;
	}
	if (fread(data, 1, size, f) != size) {
		fclose(f);
		free(data);
		return 1;
	}
	fclose(f);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(data);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		free(data);
		return 1;
	}
	if (JxlDecoderSetInput(dec, data, size) != JXL_DEC_SUCCESS) {
		JxlDecoderDestroy(dec);
		free(data);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) continue;
		if (status == JXL_DEC_COLOR_ENCODING) {
			JxlColorEncoding color;
			memset(&color, 0, sizeof(color));
			if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &color) != JXL_DEC_SUCCESS) {
				JxlDecoderDestroy(dec);
				free(data);
				return 1;
			}
			printf("%d %.6f %.6f %.6f %.6f %.6f %.6f\n",
				(int)color.primaries,
				color.primaries_red_xy[0], color.primaries_red_xy[1],
				color.primaries_green_xy[0], color.primaries_green_xy[1],
				color.primaries_blue_xy[0], color.primaries_blue_xy[1]);
			JxlDecoderDestroy(dec);
			free(data);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_ERROR) {
			JxlDecoderDestroy(dec);
			free(data);
			return 1;
		}
	}
}
