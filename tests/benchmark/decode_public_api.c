#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/decode.h>

typedef struct {
	const char* path;
	uint8_t* data;
	size_t size;
} InputBlob;

typedef struct {
	JxlDecoder* decoder;
	uint8_t* pixels;
	size_t pixels_capacity;
} DecodeContext;

static uint64_t hash_bytes(uint64_t hash, const void* data, size_t size) {
	const uint8_t* bytes = (const uint8_t*)data;
	for (size_t i = 0; i < size; ++i) {
		hash ^= bytes[i];
		hash *= UINT64_C(1099511628211);
	}
	return hash;
}

static uint64_t hash_u64(uint64_t hash, uint64_t value) {
	return hash_bytes(hash, &value, sizeof(value));
}

static int read_path(const char* path, uint8_t** data_out, size_t* size_out, char* err, size_t err_cap) {
	FILE* f = fopen(path, "rb");
	if (!f) {
		snprintf(err, err_cap, "failed to open %s: %s", path, strerror(errno));
		return 0;
	}

	if (fseek(f, 0, SEEK_END) != 0) {
		snprintf(err, err_cap, "failed to seek %s", path);
		fclose(f);
		return 0;
	}
	long end = ftell(f);
	if (end < 0) {
		snprintf(err, err_cap, "failed to tell %s", path);
		fclose(f);
		return 0;
	}
	if (fseek(f, 0, SEEK_SET) != 0) {
		snprintf(err, err_cap, "failed to rewind %s", path);
		fclose(f);
		return 0;
	}

	size_t size = (size_t)end;
	uint8_t* data = (uint8_t*)malloc(size == 0 ? 1 : size);
	if (!data) {
		snprintf(err, err_cap, "malloc failed for %s", path);
		fclose(f);
		return 0;
	}

	if (size != 0 && fread(data, 1, size, f) != size) {
		snprintf(err, err_cap, "failed to read %s", path);
		free(data);
		fclose(f);
		return 0;
	}

	fclose(f);
	*data_out = data;
	*size_out = size;
	return 1;
}

static int ensure_pixels_capacity(DecodeContext* ctx, size_t needed, char* err, size_t err_cap) {
	if (needed <= ctx->pixels_capacity) return 1;
	uint8_t* grown = (uint8_t*)realloc(ctx->pixels, needed == 0 ? 1 : needed);
	if (!grown) {
		snprintf(err, err_cap, "realloc failed");
		return 0;
	}
	ctx->pixels = grown;
	ctx->pixels_capacity = needed;
	return 1;
}

/// Decodes through the public JxlDecoder state machine only, reusing decoder
/// and output storage so benchmark noise stays outside the codec boundary.
static int decode_one(DecodeContext* ctx, const uint8_t* data, size_t size, uint64_t* hash_io, char* err, size_t err_cap) {
	JxlBasicInfo info;
	memset(&info, 0, sizeof(info));
	JxlPixelFormat format;
	format.num_channels = 3;
	format.data_type = JXL_TYPE_UINT8;
	format.endianness = JXL_NATIVE_ENDIAN;
	format.align = 0;

	JxlDecoderReset(ctx->decoder);
	if (JxlDecoderSubscribeEvents(ctx->decoder, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		snprintf(err, err_cap, "JxlDecoderSubscribeEvents failed");
		return 0;
	}
	if (JxlDecoderSetInput(ctx->decoder, data, size) != JXL_DEC_SUCCESS) {
		snprintf(err, err_cap, "JxlDecoderSetInput failed");
		return 0;
	}
	JxlDecoderCloseInput(ctx->decoder);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(ctx->decoder);
		switch (status) {
			case JXL_DEC_BASIC_INFO:
				if (JxlDecoderGetBasicInfo(ctx->decoder, &info) != JXL_DEC_SUCCESS) {
					snprintf(err, err_cap, "JxlDecoderGetBasicInfo failed");
					return 0;
				}
				break;
			case JXL_DEC_NEED_IMAGE_OUT_BUFFER: {
				size_t needed = 0;
				if (JxlDecoderImageOutBufferSize(ctx->decoder, &format, &needed) != JXL_DEC_SUCCESS) {
					snprintf(err, err_cap, "JxlDecoderImageOutBufferSize failed");
					return 0;
				}
				if (!ensure_pixels_capacity(ctx, needed, err, err_cap)) return 0;
				if (JxlDecoderSetImageOutBuffer(ctx->decoder, &format, ctx->pixels, needed) != JXL_DEC_SUCCESS) {
					snprintf(err, err_cap, "JxlDecoderSetImageOutBuffer failed");
					return 0;
				}
				break;
			}
			case JXL_DEC_FULL_IMAGE:
				break;
			case JXL_DEC_SUCCESS: {
				size_t used = (size_t)info.xsize * (size_t)info.ysize * format.num_channels;
				*hash_io = hash_u64(*hash_io, (uint64_t)info.xsize);
				*hash_io = hash_u64(*hash_io, (uint64_t)info.ysize);
				*hash_io = hash_u64(*hash_io, (uint64_t)used);
				*hash_io = hash_bytes(*hash_io, ctx->pixels, used);
				return 1;
			}
			case JXL_DEC_ERROR:
				snprintf(err, err_cap, "JxlDecoderProcessInput returned error");
				return 0;
			case JXL_DEC_NEED_MORE_INPUT:
				snprintf(err, err_cap, "unexpected JXL_DEC_NEED_MORE_INPUT");
				return 0;
			default:
				snprintf(err, err_cap, "unexpected decoder status %d", (int)status);
				return 0;
		}
	}
}

static void free_inputs(InputBlob* inputs, size_t count) {
	for (size_t i = 0; i < count; ++i) {
		free(inputs[i].data);
	}
	free(inputs);
}

static void print_help(FILE* out) {
	fprintf(out,
		"Usage: decode_public_api [--repeat N] [--print-checksum] [--expect-checksum HEX] FILE...\n"
		"Decode JPEG XL files through JxlDecoder only and hash the decoded RGB output.\n");
}

int main(int argc, char** argv) {
	int repeat = 1;
	int print_checksum = 0;
	uint64_t expected_checksum = 0;
	int have_expected_checksum = 0;
	int first_path = 1;

	for (; first_path < argc; ++first_path) {
		if (strcmp(argv[first_path], "--help") == 0) {
			print_help(stdout);
			return 0;
		}
		if (strcmp(argv[first_path], "--print-checksum") == 0) {
			print_checksum = 1;
			continue;
		}
		if (strcmp(argv[first_path], "--repeat") == 0) {
			if (first_path + 1 >= argc) {
				fprintf(stderr, "missing value for --repeat\n");
				return 2;
			}
			repeat = atoi(argv[++first_path]);
			if (repeat <= 0) {
				fprintf(stderr, "invalid --repeat value\n");
				return 2;
			}
			continue;
		}
		if (strcmp(argv[first_path], "--expect-checksum") == 0) {
			if (first_path + 1 >= argc) {
				fprintf(stderr, "missing value for --expect-checksum\n");
				return 2;
			}
			expected_checksum = strtoull(argv[++first_path], NULL, 16);
			have_expected_checksum = 1;
			continue;
		}
		break;
	}

	if (first_path >= argc) {
		print_help(stderr);
		return 2;
	}

	size_t input_count = (size_t)(argc - first_path);
	InputBlob* inputs = (InputBlob*)calloc(input_count, sizeof(*inputs));
	if (!inputs) {
		fprintf(stderr, "calloc failed\n");
		return 1;
	}

	char err[256];
	for (size_t i = 0; i < input_count; ++i) {
		inputs[i].path = argv[first_path + (int)i];
		if (!read_path(inputs[i].path, &inputs[i].data, &inputs[i].size, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err);
			free_inputs(inputs, input_count);
			return 1;
		}
	}

	DecodeContext ctx;
	memset(&ctx, 0, sizeof(ctx));
	ctx.decoder = JxlDecoderCreate(NULL);
	if (!ctx.decoder) {
		fprintf(stderr, "JxlDecoderCreate failed\n");
		free_inputs(inputs, input_count);
		return 1;
	}

	uint64_t checksum = UINT64_C(1469598103934665603);
	for (int i = 0; i < repeat; ++i) {
		for (size_t j = 0; j < input_count; ++j) {
			if (!decode_one(&ctx, inputs[j].data, inputs[j].size, &checksum, err, sizeof(err))) {
				fprintf(stderr, "%s: %s\n", inputs[j].path, err);
				free(ctx.pixels);
				JxlDecoderDestroy(ctx.decoder);
				free_inputs(inputs, input_count);
				return 1;
			}
		}
	}

	if (print_checksum) {
		printf("%016" PRIx64 "\n", checksum);
	}
	if (have_expected_checksum && checksum != expected_checksum) {
		fprintf(stderr, "checksum mismatch: expected %016" PRIx64 ", got %016" PRIx64 "\n", expected_checksum, checksum);
		free(ctx.pixels);
		JxlDecoderDestroy(ctx.decoder);
		free_inputs(inputs, input_count);
		return 1;
	}

	free(ctx.pixels);
	JxlDecoderDestroy(ctx.decoder);
	free_inputs(inputs, input_count);
	return 0;
}
