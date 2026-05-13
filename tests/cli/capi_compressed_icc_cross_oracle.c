// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/color_encoding.h>
#include <jxl/compressed_icc.h>
#include <jxl/decode.h>
#include <jxl/encode.h>

static uint8_t* read_stdin(size_t* size_out) {
	size_t capacity = 4096;
	size_t size = 0;
	uint8_t* data = (uint8_t*)malloc(capacity);
	if (!data) return NULL;

	for (;;) {
		if (size == capacity) {
			size_t next_capacity = capacity * 2;
			uint8_t* grown = (uint8_t*)realloc(data, next_capacity);
			if (!grown) {
				free(data);
				return NULL;
			}
			data = grown;
			capacity = next_capacity;
		}
		size_t got = fread(data + size, 1, capacity - size, stdin);
		size += got;
		if (got == 0) break;
	}

	if (ferror(stdin)) {
		free(data);
		return NULL;
	}

	if (size == 0) {
		free(data);
		data = (uint8_t*)malloc(1);
		if (!data) return NULL;
	}

	*size_out = size;
	return data;
}

static int write_all_stdout(const uint8_t* data, size_t size) {
	if (size == 0) return 1;
	return fwrite(data, 1, size, stdout) == size;
}

static uint8_t* encode_tiny_srgb_jxl(size_t* size_out) {
	const uint8_t pixels[3] = { 12, 34, 56 };
	const JxlPixelFormat format = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };

	JxlBasicInfo info;
	JxlColorEncoding color;
	JxlEncoder* enc = NULL;
	JxlEncoderFrameSettings* settings = NULL;
	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	size_t encoded_capacity = 4096;

	JxlEncoderInitBasicInfo(&info);
	info.xsize = 1;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;

	JxlColorEncodingSetToSRGB(&color, JXL_FALSE);

	enc = JxlEncoderCreate(NULL);
	if (!enc) return NULL;
	settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) goto fail;
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) goto fail;
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) goto fail;
	if (JxlEncoderAddImageFrame(settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) goto fail;
	JxlEncoderCloseInput(enc);

	encoded = (uint8_t*)malloc(encoded_capacity);
	if (!encoded) goto fail;

	for (;;) {
		uint8_t* next_out = encoded + encoded_size;
		size_t avail_out = encoded_capacity - encoded_size;
		JxlEncoderStatus status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		encoded_size = encoded_capacity - avail_out;
		if (status == JXL_ENC_SUCCESS) break;
		if (status != JXL_ENC_NEED_MORE_OUTPUT) goto fail;

		encoded_capacity *= 2;
		uint8_t* grown = (uint8_t*)realloc(encoded, encoded_capacity);
		if (!grown) goto fail;
		encoded = grown;
	}

	JxlEncoderDestroy(enc);
	*size_out = encoded_size;
	return encoded;

fail:
	free(encoded);
	JxlEncoderDestroy(enc);
	return NULL;
}

static uint8_t* extract_srgb_icc(size_t* size_out) {
	uint8_t* codestream = NULL;
	size_t codestream_size = 0;
	JxlDecoder* dec = NULL;
	uint8_t* icc = NULL;

	codestream = encode_tiny_srgb_jxl(&codestream_size);
	if (!codestream) return NULL;

	dec = JxlDecoderCreate(NULL);
	if (!dec) goto fail;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) goto fail;
	if (JxlDecoderSetInput(dec, codestream, codestream_size) != JXL_DEC_SUCCESS) goto fail;
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) continue;
		if (status == JXL_DEC_COLOR_ENCODING) {
			size_t icc_size = 0;
			if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &icc_size) != JXL_DEC_SUCCESS) goto fail;
			icc = (uint8_t*)malloc(icc_size == 0 ? 1 : icc_size);
			if (!icc) goto fail;
			if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, icc, icc_size) != JXL_DEC_SUCCESS) goto fail;
			*size_out = icc_size;
			JxlDecoderDestroy(dec);
			free(codestream);
			return icc;
		}
		if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_SUCCESS) goto fail;
	}

fail:
	free(icc);
	JxlDecoderDestroy(dec);
	free(codestream);
	return NULL;
}

int main(int argc, char** argv) {
	uint8_t* bytes = NULL;
	size_t size = 0;

	if (argc != 2) {
		fprintf(stderr, "usage: %s profile|compress|decompress\n", argv[0]);
		return 1;
	}

	if (strcmp(argv[1], "profile") == 0) {
		bytes = extract_srgb_icc(&size);
		if (!bytes) {
			fprintf(stderr, "extract profile failed\n");
			return 1;
		}
		if (!write_all_stdout(bytes, size)) {
			fprintf(stderr, "write profile failed\n");
			free(bytes);
			return 1;
		}
		free(bytes);
		return 0;
	}

	if (strcmp(argv[1], "compress") == 0) {
		uint8_t* compressed = NULL;
		size_t compressed_size = 0;

		bytes = extract_srgb_icc(&size);
		if (!bytes) {
			fprintf(stderr, "extract profile failed\n");
			return 1;
		}
		if (!JxlICCProfileEncode(NULL, bytes, size, &compressed, &compressed_size)) {
			fprintf(stderr, "compress profile failed\n");
			free(bytes);
			return 1;
		}
		free(bytes);

		if (!write_all_stdout(compressed, compressed_size)) {
			fprintf(stderr, "write compressed profile failed\n");
			free(compressed);
			return 1;
		}
		free(compressed);
		return 0;
	}

	if (strcmp(argv[1], "decompress") == 0) {
		uint8_t* decompressed = NULL;
		size_t decompressed_size = 0;

		bytes = read_stdin(&size);
		if (!bytes) {
			fprintf(stderr, "read compressed profile failed\n");
			return 1;
		}
		if (!JxlICCProfileDecode(NULL, bytes, size, &decompressed, &decompressed_size)) {
			fprintf(stderr, "decompress profile failed\n");
			free(bytes);
			return 1;
		}
		free(bytes);

		if (!write_all_stdout(decompressed, decompressed_size)) {
			fprintf(stderr, "write decompressed profile failed\n");
			free(decompressed);
			return 1;
		}
		free(decompressed);
		return 0;
	}

	fprintf(stderr, "unknown mode: %s\n", argv[1]);
	return 1;
}
