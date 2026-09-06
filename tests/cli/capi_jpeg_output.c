// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause
#include <jxl/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *size) {
	FILE *file = fopen(path, "rb");
	if (!file)
		return NULL;
	if (fseek(file, 0, SEEK_END)) {
		fclose(file);
		return NULL;
	}
	long length = ftell(file);
	if (length < 0 || fseek(file, 0, SEEK_SET)) {
		fclose(file);
		return NULL;
	}
	uint8_t *bytes = malloc(length ? (size_t)length : 1);
	if (!bytes) {
		fclose(file);
		return NULL;
	}
	if (fread(bytes, 1, (size_t)length, file) != (size_t)length) {
		free(bytes);
		fclose(file);
		return NULL;
	}
	fclose(file);
	*size = (size_t)length;
	return bytes;
}

static int reconstruct(JxlDecoder *dec, const uint8_t *input, size_t input_size,
					   const uint8_t *expected, size_t expected_size) {
	uint8_t output[4093];
	size_t position = 0;
	int saw_reconstruction = 0, saw_frame = 0;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_JPEG_RECONSTRUCTION |
										   JXL_DEC_FULL_IMAGE) !=
			JXL_DEC_SUCCESS ||
		JxlDecoderSetInput(dec, input, input_size) != JXL_DEC_SUCCESS)
		return 1;
	JxlDecoderCloseInput(dec);
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
			if (saw_reconstruction++)
				return 2;
			if (JxlDecoderSetJPEGBuffer(dec, output, sizeof(output)) !=
				JXL_DEC_SUCCESS)
				return 3;
		} else if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT ||
				   status == JXL_DEC_FULL_IMAGE) {
			if (!saw_reconstruction || saw_frame)
				return 4;
			size_t remaining = JxlDecoderReleaseJPEGBuffer(dec);
			if (remaining > sizeof(output))
				return 5;
			size_t count = sizeof(output) - remaining;
			if (!count || count > expected_size - position ||
				memcmp(output, expected + position, count))
				return 6;
			position += count;
			if (status == JXL_DEC_FULL_IMAGE) {
				if (position != expected_size)
					return 7;
				saw_frame = 1;
			} else if (JxlDecoderSetJPEGBuffer(dec, output, sizeof(output)) !=
					   JXL_DEC_SUCCESS)
				return 8;
		} else if (status == JXL_DEC_SUCCESS) {
			return saw_frame && saw_reconstruction && position == expected_size
					   ? 0
					   : 9;
		} else
			return 10 + (int)status;
	}
}

int main(int argc, char **argv) {
	if (argc != 3)
		return 64;
	size_t input_size = 0, expected_size = 0;
	uint8_t *input = read_file(argv[1], &input_size);
	uint8_t *expected = read_file(argv[2], &expected_size);
	JxlDecoder *dec = JxlDecoderCreate(NULL);
	int result = 1;
	if (input && expected && dec) {
		result = reconstruct(dec, input, input_size, expected, expected_size);
		if (!result) {
			JxlDecoderRewind(dec);
			result =
				reconstruct(dec, input, input_size, expected, expected_size);
		}
		if (!result) {
			JxlDecoderReset(dec);
			result =
				reconstruct(dec, input, input_size, expected, expected_size);
		}
	}
	if (result)
		fprintf(stderr, "JPEG reconstruction failed at control %d for %s\n",
				result, argv[1]);
	JxlDecoderDestroy(dec);
	free(input);
	free(expected);
	return result;
}
