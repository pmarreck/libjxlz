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

static uint64_t fnv1a64(const uint8_t* data, size_t size) {
	uint64_t hash = 1469598103934665603ULL;
	for (size_t i = 0; i < size; ++i) {
		hash ^= data[i];
		hash *= 1099511628211ULL;
	}
	return hash;
}

static int ensure_output(JxlDecoder* dec, uint8_t** out, size_t* out_size) {
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

static int collect_hashes(
	JxlDecoder* dec,
	const uint8_t* data,
	size_t size,
	int use_skip_frames,
	int use_skip_current,
	uint64_t* hashes,
	size_t* hash_count
) {
	uint8_t* out = NULL;
	size_t out_size = 0;
	int saw_basic = 0;
	int skip_current_done = 0;
	*hash_count = 0;

	if (JXL_DEC_SUCCESS != JxlDecoderSetInput(dec, data, size)) goto fail;
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			saw_basic = 1;
			if (use_skip_frames) JxlDecoderSkipFrames(dec, 1);
			continue;
		}
		if (status == JXL_DEC_FRAME) {
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (use_skip_current && !skip_current_done) {
				skip_current_done = 1;
				if (JXL_DEC_SUCCESS != JxlDecoderSkipCurrentFrame(dec)) goto fail;
				continue;
			}
			if (!ensure_output(dec, &out, &out_size)) goto fail;
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			if (*hash_count >= 8) goto fail;
			hashes[*hash_count] = fnv1a64(out, out_size);
			*hash_count += 1;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) break;
		goto fail;
	}

	if (!saw_basic) goto fail;
	free(out);
	return 1;

fail:
	free(out);
	return 0;
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
	JxlDecoder* skip_dec = JxlDecoderCreate(NULL);
	if (!dec || !skip_dec) {
		free(bytes);
		fprintf(stderr, "create failed\n");
		return 1;
	}

	if (JXL_DEC_SUCCESS != JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE) ||
		JXL_DEC_SUCCESS != JxlDecoderSubscribeEvents(skip_dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE)) {
		fprintf(stderr, "subscribe failed\n");
		goto fail;
	}

	uint64_t full_hashes[8] = { 0 };
	uint64_t rewind_hashes[8] = { 0 };
	uint64_t skip_hashes[8] = { 0 };
	size_t full_count = 0;
	size_t rewind_count = 0;
	size_t skip_count = 0;

	if (!collect_hashes(dec, bytes, size, 0, 0, full_hashes, &full_count)) {
		fprintf(stderr, "full decode failed\n");
		goto fail;
	}
	if (full_count != 4) {
		fprintf(stderr, "unexpected full frame count\n");
		goto fail;
	}

	JxlDecoderRewind(dec);
	if (!collect_hashes(dec, bytes, size, 0, 1, rewind_hashes, &rewind_count)) {
		fprintf(stderr, "rewind decode failed\n");
		goto fail;
	}
	if (rewind_count != 3) {
		fprintf(stderr, "unexpected rewind frame count\n");
		goto fail;
	}

	if (!collect_hashes(skip_dec, bytes, size, 1, 0, skip_hashes, &skip_count)) {
		fprintf(stderr, "skip decode failed\n");
		goto fail;
	}
	if (skip_count != 3) {
		fprintf(stderr, "unexpected skip frame count\n");
		goto fail;
	}

	for (size_t i = 0; i < 3; ++i) {
		if (full_hashes[i + 1] != rewind_hashes[i] || rewind_hashes[i] != skip_hashes[i]) {
			fprintf(stderr, "frame hash mismatch\n");
			goto fail;
		}
	}

	printf(
		"%016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx %016llx\n",
		(unsigned long long)full_hashes[0],
		(unsigned long long)full_hashes[1],
		(unsigned long long)full_hashes[2],
		(unsigned long long)full_hashes[3],
		(unsigned long long)rewind_hashes[0],
		(unsigned long long)rewind_hashes[1],
		(unsigned long long)rewind_hashes[2],
		(unsigned long long)skip_hashes[0],
		(unsigned long long)skip_hashes[1],
		(unsigned long long)skip_hashes[2]
	);

	JxlDecoderDestroy(skip_dec);
	JxlDecoderDestroy(dec);
	free(bytes);
	return 0;

fail:
	JxlDecoderDestroy(skip_dec);
	JxlDecoderDestroy(dec);
	free(bytes);
	return 1;
}
