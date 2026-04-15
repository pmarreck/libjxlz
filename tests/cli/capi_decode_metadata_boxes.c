// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <jxl/encode.h>

static int encode_with_boxes(uint8_t* encoded, size_t encoded_cap, size_t* encoded_size) {
	const uint8_t pixels[] = {
		0x00, 0x10, 0x20,
		0x30, 0x40, 0x50,
	};
	const uint8_t xmp[] = "<x:xmpmeta>decoder box smoke</x:xmpmeta>";
	const uint8_t exif[] = "Exif payload";
	JxlPixelFormat format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 1;
	info.bits_per_sample = 8;
	info.num_color_channels = 3;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, JXL_FALSE);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) return 0;
	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
		JxlEncoderDestroy(enc);
		return 0;
	}
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) return 0;
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) return 0;
	if (JxlEncoderUseBoxes(enc) != JXL_ENC_SUCCESS) return 0;
	if (JxlEncoderAddBox(enc, "xml ", xmp, sizeof(xmp) - 1, JXL_FALSE) != JXL_ENC_SUCCESS) return 0;
	if (JxlEncoderAddBox(enc, "Exif", exif, sizeof(exif) - 1, JXL_FALSE) != JXL_ENC_SUCCESS) return 0;
	JxlEncoderCloseBoxes(enc);
	if (JxlEncoderAddImageFrame(settings, &format, pixels, sizeof(pixels)) != JXL_ENC_SUCCESS) return 0;
	JxlEncoderCloseInput(enc);

	uint8_t* next_out = encoded;
	size_t avail_out = encoded_cap;
	for (;;) {
		JxlEncoderStatus st = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		if (st == JXL_ENC_SUCCESS) break;
		if (st != JXL_ENC_NEED_MORE_OUTPUT) {
			JxlEncoderDestroy(enc);
			return 0;
		}
	}
	JxlEncoderDestroy(enc);
	*encoded_size = encoded_cap - avail_out;
	return 1;
}

int main(void) {
	uint8_t encoded[4096];
	size_t encoded_size = 0;
	if (!encode_with_boxes(encoded, sizeof(encoded), &encoded_size)) {
		fprintf(stderr, "encode_with_boxes failed\n");
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) return 1;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BOX | JXL_DEC_BOX_COMPLETE | JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "subscribe failed\n");
		return 1;
	}
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) {
		fprintf(stderr, "set input failed\n");
		return 1;
	}
	JxlDecoderCloseInput(dec);

	int saw_basic = 0;
	int saw_xml = 0;
	int saw_exif = 0;
	char current_type[5] = {0, 0, 0, 0, 0};
	uint8_t box_buffer[256];
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
				return 1;
			}
			if (JxlDecoderGetBoxSizeRaw(dec, &raw_size) != JXL_DEC_SUCCESS) {
				fprintf(stderr, "GetBoxSizeRaw failed\n");
				return 1;
			}
			if (raw_size < 8) {
				fprintf(stderr, "raw size too small\n");
				return 1;
			}
			if (memcmp(current_type, "xml ", 4) == 0 || memcmp(current_type, "Exif", 4) == 0) {
				if (JxlDecoderSetBoxBuffer(dec, box_buffer, sizeof(box_buffer)) != JXL_DEC_SUCCESS) {
					fprintf(stderr, "SetBoxBuffer failed\n");
					return 1;
				}
			}
			continue;
		}
		if (st == JXL_DEC_BOX_COMPLETE) {
			size_t unused = JxlDecoderReleaseBoxBuffer(dec);
			size_t used = sizeof(box_buffer) - unused;
			if (memcmp(current_type, "xml ", 4) == 0) {
				if (used != sizeof("<x:xmpmeta>decoder box smoke</x:xmpmeta>") - 1 || memcmp(box_buffer, "<x:xmpmeta>decoder box smoke</x:xmpmeta>", used) != 0) {
					fprintf(stderr, "xml payload mismatch\n");
					return 1;
				}
				saw_xml = 1;
			} else if (memcmp(current_type, "Exif", 4) == 0) {
				if (used != sizeof("Exif payload") - 1 || memcmp(box_buffer, "Exif payload", used) != 0) {
					fprintf(stderr, "Exif payload mismatch\n");
					return 1;
				}
				saw_exif = 1;
			}
			memset(current_type, 0, sizeof(current_type));
			continue;
		}
		fprintf(stderr, "unexpected decoder status: %d\n", (int)st);
		return 1;
	}

	JxlDecoderDestroy(dec);
	if (!saw_xml || !saw_exif || !saw_basic) {
		fprintf(stderr, "missing expected decoder events\n");
		return 1;
	}
	return 0;
}
