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

	JxlSignature sig = JxlSignatureCheck(data, size);
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(data);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
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
		if (status == JXL_DEC_BASIC_INFO) {
			JxlBasicInfo info;
			memset(&info, 0, sizeof(info));
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				JxlDecoderDestroy(dec);
				free(data);
				return 1;
			}
			printf("%d %u\n", (int)sig, (unsigned)info.have_container);
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
