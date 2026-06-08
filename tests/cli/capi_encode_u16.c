#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>
#include <jxl/encode.h>

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

static int roundtrip_u16(
	const uint8_t* pixels,
	uint32_t num_channels,
	uint32_t output_channels,
	uint32_t num_color_channels,
	uint32_t alpha_bits,
	JxlEndianness input_endianness,
	const uint8_t* staged_alpha,
	JxlEndianness staged_alpha_endianness,
	const uint8_t* expected_big_endian
) {
	JxlPixelFormat input_format = {num_channels, JXL_TYPE_UINT16, input_endianness, 0};
	JxlPixelFormat output_format = {output_channels, JXL_TYPE_UINT16, JXL_BIG_ENDIAN, 0};
	size_t pixel_bytes = (size_t)2 * 1 * num_channels * 2;
	size_t output_bytes = (size_t)2 * 1 * output_channels * 2;
	size_t staged_alpha_bytes = (size_t)2 * 1 * 2;
	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = 2;
	info.ysize = 1;
	info.bits_per_sample = 16;
	info.num_color_channels = num_color_channels;
	info.num_extra_channels = alpha_bits ? 1 : 0;
	info.alpha_bits = alpha_bits;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, num_color_channels == 1 ? 1 : 0);

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) return 1;
	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set 16-bit basic info failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "set color encoding failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (JxlEncoderAddImageFrame(settings, &input_format, pixels, pixel_bytes) != JXL_ENC_SUCCESS) {
		fprintf(stderr, "add 16-bit image frame failed\n");
		JxlEncoderDestroy(enc);
		return 1;
	}
	if (staged_alpha) {
		JxlPixelFormat alpha_format = {1, JXL_TYPE_UINT16, staged_alpha_endianness, 0};
		if (JxlEncoderSetExtraChannelBuffer(settings, &alpha_format, staged_alpha, staged_alpha_bytes, 0) != JXL_ENC_SUCCESS) {
			fprintf(stderr, "add 16-bit staged alpha failed\n");
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	JxlEncoderCloseInput(enc);

	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	size_t encoded_cap = 0;
	for (;;) {
		uint8_t chunk[17];
		uint8_t* next_out = chunk;
		size_t avail_out = sizeof(chunk);
		JxlEncoderStatus status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		size_t produced = sizeof(chunk) - avail_out;
		if (produced && !append_chunk(&encoded, &encoded_size, &encoded_cap, chunk, produced)) return 1;
		if (status == JXL_ENC_SUCCESS) break;
		if (status != JXL_ENC_NEED_MORE_OUTPUT) {
			fprintf(stderr, "unexpected encoder status %d\n", (int)status);
			free(encoded);
			JxlEncoderDestroy(enc);
			return 1;
		}
	}
	JxlEncoderDestroy(enc);

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(encoded);
		return 1;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) return 1;
	if (JxlDecoderSetInput(dec, encoded, encoded_size) != JXL_DEC_SUCCESS) return 1;
	JxlDecoderCloseInput(dec);

	JxlBasicInfo decoded_info;
	memset(&decoded_info, 0, sizeof(decoded_info));
	uint8_t decoded_pixels[16];
	memset(decoded_pixels, 0, sizeof(decoded_pixels));
	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &decoded_info) != JXL_DEC_SUCCESS) return 1;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			size_t decoded_size = 0;
			if (JxlDecoderImageOutBufferSize(dec, &output_format, &decoded_size) != JXL_DEC_SUCCESS) return 1;
			if (decoded_size != output_bytes) {
				fprintf(stderr, "unexpected 16-bit buffer size %zu\n", decoded_size);
				return 1;
			}
			if (JxlDecoderSetImageOutBuffer(dec, &output_format, decoded_pixels, output_bytes) != JXL_DEC_SUCCESS) return 1;
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) continue;
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected decoder status %d\n", (int)status);
		return 1;
	}

	if (decoded_info.bits_per_sample != 16) {
		fprintf(stderr, "unexpected decoded bit depth %u\n", decoded_info.bits_per_sample);
		return 1;
	}
	if (decoded_info.num_color_channels != num_color_channels) {
		fprintf(stderr, "unexpected decoded color channel count %u\n", decoded_info.num_color_channels);
		return 1;
	}
	if (decoded_info.alpha_bits != alpha_bits) {
		fprintf(stderr, "unexpected decoded alpha bit depth %u\n", decoded_info.alpha_bits);
		return 1;
	}
	if (memcmp(decoded_pixels, expected_big_endian, output_bytes) != 0) {
		fprintf(stderr, "16-bit pixel roundtrip mismatch\n");
		return 1;
	}

	JxlDecoderDestroy(dec);
	free(encoded);
	return 0;
}

int main(void) {
	const uint8_t big_endian_pixels[12] = {
		0x00, 0x00, 0x12, 0x34, 0xff, 0xff,
		0x01, 0x00, 0x80, 0x00, 0xab, 0xcd,
	};
	const uint8_t little_endian_pixels[12] = {
		0x00, 0x00, 0x34, 0x12, 0xff, 0xff,
		0x00, 0x01, 0x00, 0x80, 0xcd, 0xab,
	};
	const uint8_t big_endian_rgba_pixels[16] = {
		0x00, 0x00, 0x12, 0x34, 0xff, 0xff, 0x80, 0x00,
		0x01, 0x00, 0x80, 0x00, 0xab, 0xcd, 0x40, 0x00,
	};
	const uint8_t little_endian_rgba_pixels[16] = {
		0x00, 0x00, 0x34, 0x12, 0xff, 0xff, 0x00, 0x80,
		0x00, 0x01, 0x00, 0x80, 0xcd, 0xab, 0x00, 0x40,
	};
	const uint8_t little_endian_alpha_pixels[4] = { 0x00, 0x80, 0x00, 0x40 };

	if (roundtrip_u16(big_endian_pixels, 3, 3, 3, 0, JXL_BIG_ENDIAN, NULL, JXL_BIG_ENDIAN, big_endian_pixels) != 0) return 1;
	if (roundtrip_u16(little_endian_pixels, 3, 3, 3, 0, JXL_LITTLE_ENDIAN, NULL, JXL_BIG_ENDIAN, big_endian_pixels) != 0) return 1;
	if (roundtrip_u16(big_endian_rgba_pixels, 4, 4, 3, 16, JXL_BIG_ENDIAN, NULL, JXL_BIG_ENDIAN, big_endian_rgba_pixels) != 0) return 1;
	if (roundtrip_u16(little_endian_rgba_pixels, 4, 4, 3, 16, JXL_LITTLE_ENDIAN, NULL, JXL_BIG_ENDIAN, big_endian_rgba_pixels) != 0) return 1;
	if (roundtrip_u16(big_endian_pixels, 3, 4, 3, 16, JXL_BIG_ENDIAN, little_endian_alpha_pixels, JXL_LITTLE_ENDIAN, big_endian_rgba_pixels) != 0) return 1;
	return 0;
}
