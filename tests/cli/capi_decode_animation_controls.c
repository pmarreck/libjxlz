#include <jxl/decode.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int read_file(const char* path, uint8_t** data_out, size_t* size_out) {
	FILE* f = fopen(path, "rb");
	if (!f) return 0;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return 0;
	}
	long size = ftell(f);
	if (size < 0) {
		fclose(f);
		return 0;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return 0;
	}
	uint8_t* data = (uint8_t*)malloc((size_t)size);
	if (!data) {
		fclose(f);
		return 0;
	}
	if (fread(data, 1, (size_t)size, f) != (size_t)size) {
		free(data);
		fclose(f);
		return 0;
	}
	fclose(f);
	*data_out = data;
	*size_out = (size_t)size;
	return 1;
}

static int set_output(JxlDecoder* dec, uint8_t** out, size_t* out_size) {
	JxlPixelFormat format;
	memset(&format, 0, sizeof(format));
	format.num_channels = 4;
	format.data_type = JXL_TYPE_UINT8;
	format.endianness = JXL_NATIVE_ENDIAN;
	if (JXL_DEC_SUCCESS != JxlDecoderImageOutBufferSize(dec, &format, out_size)) return 0;
	if (!*out) {
		*out = (uint8_t*)malloc(*out_size);
		if (!*out) return 0;
	}
	return JXL_DEC_SUCCESS == JxlDecoderSetImageOutBuffer(dec, &format, *out, *out_size);
}

int main(int argc, char** argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s FILE\n", argv[0]);
		return 2;
	}

	uint8_t* bytes = NULL;
	size_t size = 0;
	uint8_t* out = NULL;
	size_t out_size = 0;
	if (!read_file(argv[1], &bytes, &size)) {
		fprintf(stderr, "read failed\n");
		return 1;
	}

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		free(bytes);
		fprintf(stderr, "create failed\n");
		return 1;
	}

	if (JXL_DEC_SUCCESS != JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE)) {
		fprintf(stderr, "subscribe failed\n");
		goto fail;
	}
	if (JXL_DEC_SUCCESS != JxlDecoderSetInput(dec, bytes, size)) {
		fprintf(stderr, "set input failed\n");
		goto fail;
	}
	JxlDecoderCloseInput(dec);

	uint32_t skip_durations[3] = { 0, 0, 0 };
	size_t skip_count = 0;
	int skip_full_count = 0;
	int saw_basic = 0;

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			saw_basic = 1;
			JxlDecoderSkipFrames(dec, 1);
			continue;
		}
		if (status == JXL_DEC_FRAME) {
			JxlFrameHeader header;
			memset(&header, 0, sizeof(header));
			if (JXL_DEC_SUCCESS != JxlDecoderGetFrameHeader(dec, &header)) {
				fprintf(stderr, "get frame header failed\n");
				goto fail;
			}
			if (skip_count >= 3) {
				fprintf(stderr, "too many skipped-path frames\n");
				goto fail;
			}
			skip_durations[skip_count++] = header.duration;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (!set_output(dec, &out, &out_size)) {
				fprintf(stderr, "set out buffer failed\n");
				goto fail;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			skip_full_count += 1;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected status in skip path: %d\n", (int)status);
		goto fail;
	}

	if (!saw_basic || skip_count != 3 || skip_full_count != 3 ||
		skip_durations[0] != 100 || skip_durations[1] != 300 || skip_durations[2] != 100) {
		fprintf(stderr, "skip path mismatch\n");
		goto fail;
	}

	JxlDecoderRewind(dec);
	if (JXL_DEC_SUCCESS != JxlDecoderSetInput(dec, bytes, size)) {
		fprintf(stderr, "rewind set input failed\n");
		goto fail;
	}
	JxlDecoderCloseInput(dec);

	uint32_t rewind_durations[4] = { 0, 0, 0, 0 };
	size_t rewind_count = 0;
	int rewind_full_count = 0;
	int skip_current_done = 0;

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			continue;
		}
		if (status == JXL_DEC_FRAME) {
			JxlFrameHeader header;
			memset(&header, 0, sizeof(header));
			if (JXL_DEC_SUCCESS != JxlDecoderGetFrameHeader(dec, &header)) {
				fprintf(stderr, "rewind get frame header failed\n");
				goto fail;
			}
			if (!skip_current_done) {
				skip_current_done = 1;
				if (JXL_DEC_SUCCESS != JxlDecoderSkipCurrentFrame(dec)) {
					fprintf(stderr, "skip current frame failed\n");
					goto fail;
				}
				continue;
			}
			if (rewind_count >= 4) {
				fprintf(stderr, "too many rewind-path frames\n");
				goto fail;
			}
			rewind_durations[rewind_count++] = header.duration;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (!set_output(dec, &out, &out_size)) {
				fprintf(stderr, "rewind set out buffer failed\n");
				goto fail;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			rewind_full_count += 1;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected status in rewind path: %d\n", (int)status);
		goto fail;
	}

	if (!skip_current_done || rewind_count != 3 || rewind_full_count != 3 ||
		rewind_durations[0] != 100 || rewind_durations[1] != 300 || rewind_durations[2] != 100) {
		fprintf(stderr, "rewind path mismatch\n");
		goto fail;
	}

	printf(
		"%u %u %u %u %u %u\n",
		skip_durations[0],
		skip_durations[1],
		skip_durations[2],
		rewind_durations[0],
		rewind_durations[1],
		rewind_durations[2]
	);
	free(out);
	JxlDecoderDestroy(dec);
	free(bytes);
	return 0;

fail:
	free(out);
	JxlDecoderDestroy(dec);
	free(bytes);
	return 1;
}
