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

static int append_bytes(uint8_t** dst, size_t* used, size_t* cap, const uint8_t* src, size_t count) {
	uint8_t* grown;
	size_t new_cap = *cap == 0 ? 32 : *cap;
	while (*used + count > new_cap) new_cap *= 2;
	if (new_cap != *cap) {
		grown = (uint8_t*)realloc(*dst, new_cap);
		if (!grown) return 0;
		*dst = grown;
		*cap = new_cap;
	}
	memcpy(*dst + *used, src, count);
	*used += count;
	return 1;
}

static int decode_once(
	const uint8_t* jxl,
	size_t jxl_size,
	int decompress,
	const uint8_t* expected_raw,
	size_t expected_raw_size,
	const uint8_t* expected_decoded,
	size_t expected_decoded_size
) {
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	char type_raw[5] = {0, 0, 0, 0, 0};
	char type_dec[5] = {0, 0, 0, 0, 0};
	uint8_t box_buffer[7];
	uint8_t* collected = NULL;
	size_t collected_used = 0;
	size_t collected_cap = 0;
	uint64_t raw_size = 0;
	uint64_t contents_size = 0;
	int saw_box = 0;
	int saw_complete = 0;
	int saw_basic = 0;

	if (!dec) return 0;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BOX | JXL_DEC_BOX_COMPLETE | JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "subscribe failed\n");
		goto fail;
	}
	if (decompress) {
		if (JxlDecoderSetDecompressBoxes(dec, JXL_TRUE) != JXL_DEC_SUCCESS) {
			fprintf(stderr, "SetDecompressBoxes failed\n");
			goto fail;
		}
	}
	if (JxlDecoderSetInput(dec, jxl, jxl_size) != JXL_DEC_SUCCESS) {
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
			saw_box = 1;
			if (JxlDecoderGetBoxType(dec, type_raw, JXL_FALSE) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxType raw failed\n");
				goto fail;
			}
			if (JxlDecoderGetBoxType(dec, type_dec, JXL_TRUE) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxType decompressed failed\n");
				goto fail;
			}
			if (JxlDecoderGetBoxSizeRaw(dec, &raw_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxSizeRaw failed\n");
				goto fail;
			}
			if (JxlDecoderGetBoxSizeContents(dec, &contents_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxSizeContents failed\n");
				goto fail;
			}
			if (memcmp(type_raw, "brob", 4) != 0) {
				fprintf(stderr, "unexpected raw box type: %.4s\n", type_raw);
				goto fail;
			}
			if (memcmp(type_dec, "xml ", 4) != 0) {
				fprintf(stderr, "unexpected decompressed box type: %.4s\n", type_dec);
				goto fail;
			}
			if (raw_size < 8 || contents_size != expected_raw_size) {
				fprintf(stderr, "unexpected box size metadata\n");
				goto fail;
			}
			if (JxlDecoderSetBoxBuffer(dec, box_buffer, sizeof(box_buffer)) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "SetBoxBuffer failed\n");
				goto fail;
			}
			continue;
		}
		if (st == JXL_DEC_BOX_NEED_MORE_OUTPUT || st == JXL_DEC_BOX_COMPLETE) {
			size_t unused = JxlDecoderReleaseBoxBuffer(dec);
			size_t produced = sizeof(box_buffer) - unused;
			if (!append_bytes(&collected, &collected_used, &collected_cap, box_buffer, produced)) {
				fprintf(stderr, "append failed\n");
				goto fail;
			}
			if (st == JXL_DEC_BOX_COMPLETE) {
				saw_complete = 1;
				continue;
			}
			if (JxlDecoderSetBoxBuffer(dec, box_buffer, sizeof(box_buffer)) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "SetBoxBuffer repeat failed\n");
				goto fail;
			}
			continue;
		}
		fprintf(stderr, "unexpected decoder status %d\n", (int)st);
		goto fail;
	}

	if (!saw_box || !saw_complete || !saw_basic) {
		fprintf(stderr, "missing expected decoder events\n");
		goto fail;
	}
	if (decompress) {
		if (collected_used != expected_decoded_size || memcmp(collected, expected_decoded, expected_decoded_size) != 0) {
			fprintf(stderr, "decompressed payload mismatch\n");
			goto fail;
		}
	} else {
		if (collected_used != expected_raw_size || memcmp(collected, expected_raw, expected_raw_size) != 0) {
			fprintf(stderr, "raw payload mismatch\n");
			goto fail;
		}
	}

	free(collected);
	JxlDecoderDestroy(dec);
	return 1;

fail:
	free(collected);
	JxlDecoderDestroy(dec);
	return 0;
}

int main(int argc, char** argv) {
	uint8_t* jxl = NULL;
	uint8_t* compressed = NULL;
	uint8_t* decoded = NULL;
	uint8_t* raw = NULL;
	size_t jxl_size = 0;
	size_t compressed_size = 0;
	size_t decoded_size = 0;
	int ok = 0;

	if (argc != 4) {
		fprintf(stderr, "usage: %s INPUT_JXL EXPECTED_XML COMPRESSED_PAYLOAD\n", argv[0]);
		return 2;
	}
	if (!read_file(argv[1], &jxl, &jxl_size) || !read_file(argv[2], &decoded, &decoded_size) ||
		!read_file(argv[3], &compressed, &compressed_size)) {
		fprintf(stderr, "failed to read input files\n");
		goto cleanup;
	}
	raw = (uint8_t*)malloc(compressed_size + 4u);
	if (!raw) {
		fprintf(stderr, "failed to allocate raw payload\n");
		goto cleanup;
	}
	memcpy(raw, "xml ", 4);
	memcpy(raw + 4, compressed, compressed_size);

	if (!decode_once(jxl, jxl_size, 0, raw, compressed_size + 4u, decoded, decoded_size)) goto cleanup;
	if (!decode_once(jxl, jxl_size, 1, raw, compressed_size + 4u, decoded, decoded_size)) goto cleanup;

	ok = 1;
cleanup:
	free(jxl);
	free(compressed);
	free(decoded);
	free(raw);
	return ok ? 0 : 1;
}
