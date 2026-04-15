// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

static int read_file(const char* path, uint8_t** data, size_t* size) {
	FILE* f = fopen(path, "rb");
	size_t file_size;
	uint8_t* buf;
	if (!f) return 0;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return 0;
	}
	file_size = (size_t)ftell(f);
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return 0;
	}
	buf = (uint8_t*)malloc(file_size == 0 ? 1 : file_size);
	if (!buf) {
		fclose(f);
		return 0;
	}
	if (file_size != 0 && fread(buf, 1, file_size, f) != file_size) {
		free(buf);
		fclose(f);
		return 0;
	}
	fclose(f);
	*data = buf;
	*size = file_size;
	return 1;
}

int main(int argc, char** argv) {
	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	JxlDecoder* dec = NULL;
	uint8_t box_buffer[1024];
	char current_type[5] = {0, 0, 0, 0, 0};
	int saw_basic = 0;
	int saw_exif = 0;
	int saw_xml = 0;

	if (argc != 2) {
		fprintf(stderr, "usage: %s INPUT_JXL\n", argv[0]);
		return 2;
	}
	if (!read_file(argv[1], &encoded, &encoded_size)) {
		fprintf(stderr, "failed to read input\n");
		return 1;
	}

	dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(encoded);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BOX | JXL_DEC_BOX_COMPLETE | JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "subscribe failed\n");
		goto fail;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "set input failed\n");
		goto fail;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus st = JxlDecoderProcessInput(dec);
		if (st == JXL_DEC_SUCCESS) break;
		if (st == JXL_DEC_BASIC_INFO) {
			saw_basic = 1;
			continue;
		}
		if (st == JXL_DEC_BOX) {
			uint64_t raw_size = 0;
			if (JxlDecoderGetBoxType(dec, current_type, JXL_FALSE) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxType failed\n");
				goto fail;
			}
			if (JxlDecoderGetBoxSizeRaw(dec, &raw_size) != JXL_DEC_SUCCESS || raw_size < 8) {
				fprintf(stderr, "GetBoxSizeRaw failed\n");
				goto fail;
			}
			if (JxlDecoderSetBoxBuffer(dec, box_buffer, sizeof(box_buffer)) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "SetBoxBuffer failed\n");
				goto fail;
			}
			continue;
		}
		if (st == JXL_DEC_BOX_NEED_MORE_OUTPUT) {
			fprintf(stderr, "reference metadata box larger than test buffer\n");
			goto fail;
		}
		if (st == JXL_DEC_BOX_COMPLETE) {
			(void)JxlDecoderReleaseBoxBuffer(dec);
			if (memcmp(current_type, "Exif", 4) == 0) saw_exif = 1;
			if (memcmp(current_type, "xml ", 4) == 0) saw_xml = 1;
			memset(current_type, 0, sizeof(current_type));
			continue;
		}
		fprintf(stderr, "unexpected decoder status: %d\n", (int)st);
		goto fail;
	}

	JxlDecoderDestroy(dec);
	free(encoded);
	if (!saw_basic || !saw_exif || !saw_xml) {
		fprintf(stderr, "missing expected reference metadata boxes\n");
		return 1;
	}
	return 0;

fail:
	JxlDecoderDestroy(dec);
	free(encoded);
	return 1;
}
