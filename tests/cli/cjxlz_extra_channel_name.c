// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

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

static uint8_t* read_file(const char* path, size_t* size_out) {
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;

	size_t size = 0;
	size_t cap = 0;
	uint8_t* data = NULL;
	for (;;) {
		uint8_t chunk[4096];
		size_t n = fread(chunk, 1, sizeof(chunk), f);
		if (n != 0 && !append_chunk(&data, &size, &cap, chunk, n)) {
			fclose(f);
			free(data);
			return NULL;
		}
		if (n != sizeof(chunk)) {
			if (ferror(f)) {
				fclose(f);
				free(data);
				return NULL;
			}
			break;
		}
	}

	fclose(f);
	*size_out = size;
	return data;
}

int main(int argc, char** argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s FILE.jxl\n", argv[0]);
		return 2;
	}

	size_t encoded_size = 0;
	uint8_t* encoded = read_file(argv[1], &encoded_size);
	if (!encoded) {
		fprintf(stderr, "read failed\n");
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		fprintf(stderr, "decoder create failed\n");
		free(encoded);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "subscribe failed\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "set input failed\n");
		JxlDecoderDestroy(dec);
		free(encoded);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			JxlExtraChannelInfo info;
			memset(&info, 0, sizeof(info));
			if (JxlDecoderGetExtraChannelInfo(dec, 0, &info) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get extra info failed\n");
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			char* name = (char*)calloc(info.name_length + 1, 1);
			if (!name) {
				fprintf(stderr, "calloc failed\n");
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			if (JxlDecoderGetExtraChannelName(dec, 0, name, info.name_length + 1) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "get extra name failed\n");
				free(name);
				JxlDecoderDestroy(dec);
				free(encoded);
				return 1;
			}
			printf("%s\n", name);
			free(name);
			break;
		}
		if (status != JXL_DEC_NEED_IMAGE_OUT_BUFFER && status != JXL_DEC_SUCCESS && status != JXL_DEC_FULL_IMAGE) {
			fprintf(stderr, "unexpected decoder status %d\n", (int)status);
			JxlDecoderDestroy(dec);
			free(encoded);
			return 1;
		}
		if (status == JXL_DEC_SUCCESS) {
			fprintf(stderr, "missing basic info event\n");
			JxlDecoderDestroy(dec);
			free(encoded);
			return 1;
		}
	}

	JxlDecoderDestroy(dec);
	free(encoded);
	return 0;
}
