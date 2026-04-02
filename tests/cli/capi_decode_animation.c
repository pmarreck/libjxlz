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

int main(int argc, char** argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: %s FILE\n", argv[0]);
		return 2;
	}

	uint8_t* bytes = NULL;
	size_t size = 0;
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

	if (JXL_DEC_SUCCESS != JxlDecoderSubscribeEvents(
			dec,
			JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE)) {
		fprintf(stderr, "subscribe failed\n");
		JxlDecoderDestroy(dec);
		free(bytes);
		return 1;
	}

	if (JXL_DEC_SUCCESS != JxlDecoderSetInput(dec, bytes, size)) {
		fprintf(stderr, "set input failed\n");
		JxlDecoderDestroy(dec);
		free(bytes);
		return 1;
	}
	JxlDecoderCloseInput(dec);

	JxlPixelFormat format;
	memset(&format, 0, sizeof(format));
	format.num_channels = 4;
	format.data_type = JXL_TYPE_UINT8;
	format.endianness = JXL_NATIVE_ENDIAN;

	JxlBasicInfo info;
	memset(&info, 0, sizeof(info));
	uint8_t* out = NULL;
	size_t out_size = 0;
	uint32_t durations[16];
	uint32_t timecodes[16];
	int last_flags[16];
	size_t frame_count = 0;
	size_t full_count = 0;
	int saw_basic = 0;

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			if (JXL_DEC_SUCCESS != JxlDecoderGetBasicInfo(dec, &info)) {
				fprintf(stderr, "get basic info failed\n");
				goto fail;
			}
			saw_basic = 1;
			continue;
		}
		if (status == JXL_DEC_FRAME) {
			JxlFrameHeader header;
			memset(&header, 0, sizeof(header));
			if (JXL_DEC_SUCCESS != JxlDecoderGetFrameHeader(dec, &header)) {
				fprintf(stderr, "get frame header failed\n");
				goto fail;
			}
			if (frame_count >= sizeof(durations) / sizeof(durations[0])) {
				fprintf(stderr, "too many frames\n");
				goto fail;
			}
			durations[frame_count] = header.duration;
			timecodes[frame_count] = header.timecode;
			last_flags[frame_count] = header.is_last != 0;
			frame_count += 1;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JXL_DEC_SUCCESS != JxlDecoderImageOutBufferSize(dec, &format, &out_size)) {
				fprintf(stderr, "out size failed\n");
				goto fail;
			}
			if (!out) {
				out = (uint8_t*)malloc(out_size);
				if (!out) {
					fprintf(stderr, "malloc failed\n");
					goto fail;
				}
			}
			if (JXL_DEC_SUCCESS != JxlDecoderSetImageOutBuffer(dec, &format, out, out_size)) {
				fprintf(stderr, "set out buffer failed\n");
				goto fail;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			full_count += 1;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) break;
		fprintf(stderr, "unexpected status %d\n", (int)status);
		goto fail;
	}

	if (!saw_basic) {
		fprintf(stderr, "missing basic info event\n");
		goto fail;
	}
	if (!info.have_animation) {
		fprintf(stderr, "expected animation metadata\n");
		goto fail;
	}
	if (frame_count != 4 || full_count != 4) {
		fprintf(stderr, "unexpected frame/full counts: %zu %zu\n", frame_count, full_count);
		goto fail;
	}
	if (info.animation.tps_numerator != 100 || info.animation.tps_denominator != 1 ||
		info.animation.num_loops != 0 || info.animation.have_timecodes != 0) {
		fprintf(stderr, "unexpected animation header\n");
		goto fail;
	}
	if (durations[0] != 300 || durations[1] != 100 || durations[2] != 300 || durations[3] != 100) {
		fprintf(stderr, "unexpected durations\n");
		goto fail;
	}
	if (timecodes[0] != 0 || timecodes[1] != 0 || timecodes[2] != 0 || timecodes[3] != 0) {
		fprintf(stderr, "unexpected timecodes\n");
		goto fail;
	}
	if (last_flags[0] || last_flags[1] || last_flags[2] || !last_flags[3]) {
		fprintf(stderr, "unexpected is_last flags\n");
		goto fail;
	}

	printf(
		"%u %u %u %u %zu %zu %u %u %u %u\n",
		info.animation.tps_numerator,
		info.animation.tps_denominator,
		info.animation.num_loops,
		info.animation.have_timecodes != 0,
		frame_count,
		full_count,
		durations[0],
		durations[1],
		durations[2],
		durations[3]);

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
