// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <jxl/encode.h>

static int has_box(const uint8_t* data, size_t size, const char type[4], const uint8_t* contents, size_t contents_size) {
	size_t pos = 12;
	while (pos + 8 <= size) {
		uint32_t box_size = ((uint32_t)data[pos] << 24) | ((uint32_t)data[pos + 1] << 16) |
			((uint32_t)data[pos + 2] << 8) | (uint32_t)data[pos + 3];
		if (box_size < 8 || pos + box_size > size) return 0;
		if (memcmp(data + pos + 4, type, 4) == 0) {
			const size_t payload_size = box_size - 8;
			return payload_size == contents_size && memcmp(data + pos + 8, contents, contents_size) == 0;
		}
		pos += box_size;
	}
	return 0;
}

int main(void) {
	const uint8_t pixels[] = {
		0x00, 0x10, 0x20,
		0x30, 0x40, 0x50,
		0x60, 0x70, 0x80,
		0x90, 0xA0, 0xB0,
	};
	const uint8_t xmp[] = "<x:xmpmeta>libjxlz</x:xmpmeta>";
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 2;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, JXL_FALSE);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) return 1;
	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set basic info failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set color encoding failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderUseBoxes(enc) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "use boxes failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderAddBox(enc, "xml ", xmp, sizeof(xmp) - 1, JXL_FALSE) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add box failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	JxlEncoderCloseBoxes(enc);
	if (JxlEncoderAddImageFrame(settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add image frame failed\n");
		JxlEncoderDestroy(enc);
		return 1;
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

	if (JxlSignatureCheck(encoded, encoded_size) != JXL_SIG_CONTAINER) {
		fprintf(stderr, "expected container output\n");
		return 1;
	}
	if (!has_box(encoded, encoded_size, "xml ", xmp, sizeof(xmp) - 1)) {
		fprintf(stderr, "xml box not found\n");
		return 1;
	}

	return 0;
}
