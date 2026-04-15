// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <jxl/encode.h>

static const uint8_t* find_box(const uint8_t* data, size_t size, const char type[4], size_t* contents_size) {
	size_t pos = 12;
	while (pos + 8 <= size) {
		uint32_t box_size = ((uint32_t)data[pos] << 24) | ((uint32_t)data[pos + 1] << 16) |
			((uint32_t)data[pos + 2] << 8) | (uint32_t)data[pos + 3];
		if (box_size < 8 || pos + box_size > size) return NULL;
		if (memcmp(data + pos + 4, type, 4) == 0) {
			*contents_size = box_size - 8u;
			return data + pos + 8;
		}
		pos += box_size;
	}
	return NULL;
}

static int decode_decompressed_xml(const uint8_t* encoded, size_t encoded_size, const uint8_t* xmp, size_t xmp_size) {
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	char type_raw[5] = {0, 0, 0, 0, 0};
	char type_dec[5] = {0, 0, 0, 0, 0};
	uint8_t box_buffer[256];
	int saw_xml = 0;

	if (!dec) return 0;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BOX | JXL_DEC_BOX_COMPLETE) != JXL_DEC_SUCCESS) return 0;
	if (JxlDecoderSetDecompressBoxes(dec, JXL_TRUE) != JXL_DEC_SUCCESS) return 0;
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) return 0;
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus st = JxlDecoderProcessInput(dec);
		if (st == JXL_DEC_SUCCESS) break;
		if (st == JXL_DEC_BOX) {
			if (JxlDecoderGetBoxType(dec, type_raw, JXL_FALSE) != JXL_DEC_SUCCESS) return 0;
			if (JxlDecoderGetBoxType(dec, type_dec, JXL_TRUE) != JXL_DEC_SUCCESS) return 0;
			if (memcmp(type_raw, "brob", 4) == 0 && memcmp(type_dec, "xml ", 4) == 0) {
				if (JxlDecoderSetBoxBuffer(dec, box_buffer, sizeof(box_buffer)) != JXL_DEC_SUCCESS) return 0;
			}
			continue;
		}
		if (st == JXL_DEC_BOX_COMPLETE) {
			size_t used = sizeof(box_buffer) - JxlDecoderReleaseBoxBuffer(dec);
			if (used != xmp_size || memcmp(box_buffer, xmp, used) != 0) return 0;
			saw_xml = 1;
			continue;
		}
		if (st == JXL_DEC_BOX_NEED_MORE_OUTPUT) return 0;
		return 0;
	}

	JxlDecoderDestroy(dec);
	return saw_xml;
}

int main(void) {
	const uint8_t pixels[] = {
		0x00, 0x10, 0x20,
		0x30, 0x40, 0x50,
		0x60, 0x70, 0x80,
		0x90, 0xA0, 0xB0,
	};
	const uint8_t xmp[] = "<x:xmpmeta>libjxlz brob</x:xmpmeta>";
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
	uint8_t encoded[4096];
	uint8_t* next_out = encoded;
	size_t avail_out = sizeof(encoded);
	size_t brob_size = 0;
	const uint8_t* brob_contents;

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
	if (!settings) return 1;
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) return 1;
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) return 1;
	if (JxlEncoderUseBoxes(enc) != JXL_ENC_SUCCESS) return 1;
	if (JxlEncoderAddBox(enc, "xml ", xmp, sizeof(xmp) - 1, JXL_TRUE) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add brob box failed\n");
		return 1;
	}
	JxlEncoderCloseBoxes(enc);
	if (JxlEncoderAddImageFrame(settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) return 1;
	JxlEncoderCloseInput(enc);

	for (;;) {
		JxlEncoderStatus st = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		if (st == JXL_ENC_SUCCESS) break;
		if (st != JXL_ENC_NEED_MORE_OUTPUT) return 1;
	}
	JxlEncoderDestroy(enc);

	brob_contents = find_box(encoded, sizeof(encoded) - avail_out, "brob", &brob_size);
	if (!brob_contents || brob_size < 5) {
		fprintf(stderr, "brob box not found\n");
		return 1;
	}
	if (memcmp(brob_contents, "xml ", 4) != 0) {
		fprintf(stderr, "brob underlying type missing\n");
		return 1;
	}
	if (memmem(brob_contents + 4, brob_size - 4, xmp, sizeof(xmp) - 1) != NULL) {
		fprintf(stderr, "brob payload appears uncompressed\n");
		return 1;
	}
	if (!decode_decompressed_xml(encoded, sizeof(encoded) - avail_out, xmp, sizeof(xmp) - 1)) {
		fprintf(stderr, "decompressed xml roundtrip failed\n");
		return 1;
	}
	return 0;
}
