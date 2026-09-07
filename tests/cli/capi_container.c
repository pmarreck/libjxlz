#include <jxl/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const uint8_t codestream[] = {
	0xff, 0x0a, 0x08, 0x00, 0x02, 0x80, 0x48, 0x08, 0x02, 0x01, 0x00, 0x68,
	0x00, 0x89, 0xa0, 0x56, 0x15, 0x40, 0x02, 0x00, 0xc2, 0x8d, 0x78, 0x1b,
	0xd7, 0x80, 0x0d, 0x05, 0xf0, 0x7f, 0x0f, 0x94, 0xc8, 0xff, 0xa0, 0xa9,
	0x14, 0xbc, 0x07,
};
static const uint8_t header[] = {
	0, 0, 0, 12, 'J', 'X', 'L', ' ', 13, 10, 135, 10,
	0, 0, 0, 20, 'f', 't', 'y', 'p', 'j', 'x', 'l', ' ', 0, 0, 0, 0, 'j', 'x', 'l', ' ',
};

static int check(const uint8_t *bytes, size_t size, int valid) {
	JxlDecoder *decoder = JxlDecoderCreate(NULL);
	if (!decoder) return 1;
	const JxlPixelFormat format = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
	uint8_t pixels[12];
	int failure = 1, frames = 0;
	if (JxlDecoderSubscribeEvents(decoder, JXL_DEC_FULL_IMAGE | JXL_DEC_BOX) != JXL_DEC_SUCCESS ||
		JxlDecoderSetInput(decoder, bytes, size) != JXL_DEC_SUCCESS) goto done;
	JxlDecoderCloseInput(decoder);
	for (unsigned step = 0; step < 16; ++step) {
		JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
		if (status == JXL_DEC_SUCCESS) { failure = !valid || frames != 1; break; }
		if (status == JXL_DEC_ERROR) { failure = valid; break; }
		if (status == JXL_DEC_FULL_IMAGE) { ++frames; continue; }
		if (status == JXL_DEC_BOX) continue;
		if (status != JXL_DEC_NEED_IMAGE_OUT_BUFFER ||
			JxlDecoderSetImageOutBuffer(decoder, &format, pixels, sizeof(pixels)) != JXL_DEC_SUCCESS) break;
	}
done:
	JxlDecoderDestroy(decoder);
	return failure;
}

int main(void) {
	uint8_t bytes[128];
	if (check(codestream, sizeof(codestream), 1)) return 1;
	memcpy(bytes, codestream, sizeof(codestream));
	bytes[9] = 0;
	if (check(bytes, sizeof(codestream), 0)) return 2;
	for (unsigned variant = 0; variant < 6; ++variant) {
		memcpy(bytes, header, sizeof(header));
		size_t offset = variant == 1 ? 12 : sizeof(header);
		const uint8_t box_header[] = { 0, 0, 0, 8 + sizeof(codestream), 'j', 'x', 'l', 'c' };
		memcpy(bytes + offset, box_header, sizeof(box_header));
		offset += sizeof(box_header);
		memcpy(bytes + offset, codestream, sizeof(codestream));
		offset += sizeof(codestream);
		if (variant == 2) bytes[20] = 'x';
		if (variant == 3) {
			const uint8_t partial[] = { 0, 0, 0, 13, 'j', 'x', 'l', 'p', 128, 0, 0, 0, 0 };
			memcpy(bytes + offset, partial, sizeof(partial));
			offset += sizeof(partial);
		}
		if (variant == 4) { bytes[35] = 8; offset = 40; }
		if (variant == 5) bytes[40] = 0;
		if (check(bytes, offset, variant == 0)) {
			fprintf(stderr, "container control failed: variant %u\n", variant);
			return 3;
		}
	}
	return 0;
}
