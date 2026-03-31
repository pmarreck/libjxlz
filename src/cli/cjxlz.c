#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/encode.h>

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t channels;
	uint32_t num_color_channels;
	uint32_t num_extra_channels;
	const uint8_t* pixels;
	size_t pixels_size;
} ParsedImage;

#define MAX_EXTRA_INPUTS 16

typedef struct {
	JxlExtraChannelType type;
	const char* type_name;
	const char* path;
	uint8_t* file_data;
	size_t file_size;
	ParsedImage image;
} ParsedExtraInput;

static const char* platform_name(void) {
#if defined(__APPLE__)
	return "macos";
#elif defined(__linux__)
	return "linux";
#elif defined(_WIN32)
	return "windows";
#else
	return "unknown";
#endif
}

static const char* arch_name(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
	return "aarch64";
#elif defined(__x86_64__) || defined(_M_X64)
	return "x86_64";
#else
	return "unknown";
#endif
}

static void print_help(FILE* out) {
	fprintf(out,
		"Usage: cjxlz [options] INPUT OUTPUT\n"
		"Encode raw binary PNM/PAM into JPEG XL using the public C FFI only.\n\n"
		"Options:\n"
		"  -h, --help                Show this help\n"
		"  --about                   Show version, platform, and architecture\n"
		"  --extra TYPE PATH         Add a full-size grayscale sidecar extra channel\n"
		"                            (TYPE: selection_mask, depth, black, thermal, optional)\n\n"
		"Formats:\n"
		"  INPUT must be raw binary P5/P6 with MAXVAL 255, or narrow P7 PAM with\n"
		"  TUPLTYPE GRAYSCALE, RGB, GRAYSCALE_ALPHA, or RGB_ALPHA and MAXVAL 255\n"
		"  --extra PATH must be a raw binary P5 grayscale image with matching dimensions\n\n"
		"Paths:\n"
		"  INPUT accepts '-' or '@stdin'\n"
		"  OUTPUT accepts '-' or '@stdout' or '@stderr'\n");
}

static uint8_t* read_stream(FILE* f, size_t* size_out) {
	size_t cap = 4096;
	size_t len = 0;
	uint8_t* data = (uint8_t*)malloc(cap);
	if (!data) return NULL;

	for (;;) {
		if (len == cap) {
			cap *= 2;
			uint8_t* grown = (uint8_t*)realloc(data, cap);
			if (!grown) {
				free(data);
				return NULL;
			}
			data = grown;
		}
		size_t n = fread(data + len, 1, cap - len, f);
		len += n;
		if (n == 0) {
			if (ferror(f)) {
				free(data);
				return NULL;
			}
			break;
		}
	}

	*size_out = len;
	return data;
}

static uint8_t* read_path(const char* path, size_t* size_out) {
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
		return read_stream(stdin, size_out);
	}
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;
	uint8_t* data = read_stream(f, size_out);
	fclose(f);
	return data;
}

static FILE* open_output(const char* path) {
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0) return stdout;
	if (strcmp(path, "@stderr") == 0) return stderr;
	return fopen(path, "wb");
}

static void close_output(const char* path, FILE* out) {
	if (!out) return;
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0 || strcmp(path, "@stderr") == 0) return;
	fclose(out);
}

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

static void skip_space_and_comments(const uint8_t* data, size_t size, size_t* pos) {
	for (;;) {
		while (*pos < size && isspace((unsigned char)data[*pos])) {
			++*pos;
		}
		if (*pos < size && data[*pos] == '#') {
			while (*pos < size && data[*pos] != '\n') {
				++*pos;
			}
			continue;
		}
		break;
	}
}

static int read_token(const uint8_t* data, size_t size, size_t* pos, char* token, size_t token_cap) {
	skip_space_and_comments(data, size, pos);
	if (*pos >= size) return 0;
	size_t start = *pos;
	while (*pos < size && !isspace((unsigned char)data[*pos]) && data[*pos] != '#') {
		++*pos;
	}
	size_t len = *pos - start;
	if (len == 0 || len + 1 > token_cap) return 0;
	memcpy(token, data + start, len);
	token[len] = '\0';
	return 1;
}

static int parse_u32_token(const char* token, uint32_t* value) {
	char* end = NULL;
	unsigned long parsed = strtoul(token, &end, 10);
	if (!end || *end != '\0' || parsed > 0xffffffffUL) return 0;
	*value = (uint32_t)parsed;
	return 1;
}

static int parse_extra_type(const char* text, JxlExtraChannelType* type_out, const char** canonical_name_out) {
	if (strcmp(text, "selection_mask") == 0 || strcmp(text, "selection-mask") == 0) {
		*type_out = JXL_CHANNEL_SELECTION_MASK;
		*canonical_name_out = "selection_mask";
		return 1;
	}
	if (strcmp(text, "depth") == 0) {
		*type_out = JXL_CHANNEL_DEPTH;
		*canonical_name_out = "depth";
		return 1;
	}
	if (strcmp(text, "black") == 0) {
		*type_out = JXL_CHANNEL_BLACK;
		*canonical_name_out = "black";
		return 1;
	}
	if (strcmp(text, "thermal") == 0) {
		*type_out = JXL_CHANNEL_THERMAL;
		*canonical_name_out = "thermal";
		return 1;
	}
	if (strcmp(text, "optional") == 0) {
		*type_out = JXL_CHANNEL_OPTIONAL;
		*canonical_name_out = "optional";
		return 1;
	}
	return 0;
}

static int parse_pnm(const uint8_t* data, size_t size, ParsedImage* image, char* err, size_t err_cap) {
	char token[64];
	size_t pos = 0;
	memset(image, 0, sizeof(*image));

	if (!read_token(data, size, &pos, token, sizeof(token))) {
		snprintf(err, err_cap, "missing PNM magic");
		return 0;
	}
	if (strcmp(token, "P5") == 0) {
		image->channels = 1;
		image->num_color_channels = 1;
	} else if (strcmp(token, "P6") == 0) {
		image->channels = 3;
		image->num_color_channels = 3;
	} else if (strcmp(token, "P7") == 0) {
		uint32_t width = 0;
		uint32_t height = 0;
		uint32_t depth = 0;
		uint32_t maxval = 0;
		char tupletype[64];
		int have_width = 0;
		int have_height = 0;
		int have_depth = 0;
		int have_maxval = 0;
		int have_tupletype = 0;

		for (;;) {
			if (!read_token(data, size, &pos, token, sizeof(token))) {
				snprintf(err, err_cap, "truncated PAM header");
				return 0;
			}
			if (strcmp(token, "ENDHDR") == 0) break;
			if (strcmp(token, "WIDTH") == 0) {
				if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &width) || width == 0) {
					snprintf(err, err_cap, "invalid PAM width");
					return 0;
				}
				have_width = 1;
				continue;
			}
			if (strcmp(token, "HEIGHT") == 0) {
				if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &height) || height == 0) {
					snprintf(err, err_cap, "invalid PAM height");
					return 0;
				}
				have_height = 1;
				continue;
			}
			if (strcmp(token, "DEPTH") == 0) {
				if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &depth) || depth == 0) {
					snprintf(err, err_cap, "invalid PAM depth");
					return 0;
				}
				have_depth = 1;
				continue;
			}
			if (strcmp(token, "MAXVAL") == 0) {
				if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &maxval) || maxval != 255) {
					snprintf(err, err_cap, "only PAM MAXVAL 255 is supported");
					return 0;
				}
				have_maxval = 1;
				continue;
			}
			if (strcmp(token, "TUPLTYPE") == 0) {
				if (!read_token(data, size, &pos, tupletype, sizeof(tupletype))) {
					snprintf(err, err_cap, "invalid PAM tupletype");
					return 0;
				}
				have_tupletype = 1;
				continue;
			}
			snprintf(err, err_cap, "unsupported PAM header key: %s", token);
			return 0;
		}

		if (!(have_width && have_height && have_depth && have_maxval && have_tupletype)) {
			snprintf(err, err_cap, "incomplete PAM header");
			return 0;
		}

		image->width = width;
		image->height = height;
		image->channels = depth;
		if (strcmp(tupletype, "GRAYSCALE") == 0) {
			image->num_color_channels = 1;
			image->num_extra_channels = 0;
		} else if (strcmp(tupletype, "RGB") == 0) {
			image->num_color_channels = 3;
			image->num_extra_channels = 0;
		} else if (strcmp(tupletype, "GRAYSCALE_ALPHA") == 0) {
			image->num_color_channels = 1;
			image->num_extra_channels = 1;
		} else if (strcmp(tupletype, "RGB_ALPHA") == 0) {
			image->num_color_channels = 3;
			image->num_extra_channels = 1;
		} else {
			snprintf(err, err_cap, "unsupported PAM tupletype: %s", tupletype);
			return 0;
		}

		if (image->channels != image->num_color_channels + image->num_extra_channels) {
			snprintf(err, err_cap, "unexpected PAM depth for tuple type");
			return 0;
		}

		skip_space_and_comments(data, size, &pos);
		image->pixels = data + pos;
		image->pixels_size = size - pos;
		if (image->pixels_size != (size_t)image->width * image->height * image->channels) {
			snprintf(err, err_cap, "unexpected PAM pixel payload size");
			return 0;
		}
		return 1;
	} else {
		snprintf(err, err_cap, "unsupported input magic: %s", token);
		return 0;
	}

	if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &image->width) || image->width == 0) {
		snprintf(err, err_cap, "invalid width");
		return 0;
	}
	if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &image->height) || image->height == 0) {
		snprintf(err, err_cap, "invalid height");
		return 0;
	}
	uint32_t maxval = 0;
	if (!read_token(data, size, &pos, token, sizeof(token)) || !parse_u32_token(token, &maxval) || maxval != 255) {
		snprintf(err, err_cap, "only MAXVAL 255 is supported");
		return 0;
	}

	skip_space_and_comments(data, size, &pos);
	image->pixels = data + pos;
	image->pixels_size = size - pos;
	if (image->pixels_size != (size_t)image->width * image->height * image->channels) {
		snprintf(err, err_cap, "unexpected pixel payload size");
		return 0;
	}
	return 1;
}

static int parse_extra_input(ParsedExtraInput* extra, uint32_t width, uint32_t height, char* err, size_t err_cap) {
	if (strcmp(extra->path, "-") == 0 || strcmp(extra->path, "@stdin") == 0) {
		snprintf(err, err_cap, "--extra paths cannot use stdin");
		return 0;
	}
	extra->file_data = read_path(extra->path, &extra->file_size);
	if (!extra->file_data) {
		snprintf(err, err_cap, "failed to read extra input: %s", extra->path);
		return 0;
	}
	if (!parse_pnm(extra->file_data, extra->file_size, &extra->image, err, err_cap)) {
		return 0;
	}
	if (
		extra->image.width != width ||
		extra->image.height != height ||
		extra->image.channels != 1 ||
		extra->image.num_color_channels != 1 ||
		extra->image.num_extra_channels != 0
	) {
		snprintf(err, err_cap, "--extra input must be a matching full-size P5 image");
		return 0;
	}
	return 1;
}

static int encode_image(
	const ParsedImage* image,
	const ParsedExtraInput* extras,
	size_t extra_count,
	uint8_t** encoded_out,
	size_t* encoded_size_out,
	char* err,
	size_t err_cap
) {
	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = image->width;
	info.ysize = image->height;
	info.bits_per_sample = 8;
	info.num_color_channels = image->num_color_channels;
	info.num_extra_channels = image->num_extra_channels + (uint32_t)extra_count;
	info.alpha_bits = image->num_extra_channels ? 8 : 0;
	info.alpha_premultiplied = 0;

	JxlColorEncoding color;
	JxlColorEncodingSetToSRGB(&color, image->num_color_channels == 1 ? 1 : 0);

	JxlPixelFormat format = {
		image->channels,
		JXL_TYPE_UINT8,
		JXL_NATIVE_ENDIAN,
		0,
	};

	JxlEncoder* enc = JxlEncoderCreate(NULL);
	if (!enc) {
		snprintf(err, err_cap, "JxlEncoderCreate failed");
		return 0;
	}

	JxlEncoderFrameSettings* settings = JxlEncoderFrameSettingsCreate(enc, NULL);
	if (!settings) {
		snprintf(err, err_cap, "JxlEncoderFrameSettingsCreate failed");
		JxlEncoderDestroy(enc);
		return 0;
	}
	if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) {
		snprintf(err, err_cap, "JxlEncoderSetBasicInfo failed");
		JxlEncoderDestroy(enc);
		return 0;
	}
	if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) {
		snprintf(err, err_cap, "JxlEncoderSetColorEncoding failed");
		JxlEncoderDestroy(enc);
		return 0;
	}
	for (size_t i = 0; i < extra_count; ++i) {
		JxlExtraChannelInfo extra_info;
		JxlEncoderInitExtraChannelInfo(extras[i].type, &extra_info);
		if (JxlEncoderSetExtraChannelInfo(enc, image->num_extra_channels + i, &extra_info) != JXL_ENC_SUCCESS) {
			snprintf(err, err_cap, "JxlEncoderSetExtraChannelInfo failed");
			JxlEncoderDestroy(enc);
			return 0;
		}
		if (JxlEncoderSetExtraChannelName(enc, image->num_extra_channels + i, extras[i].type_name, strlen(extras[i].type_name)) != JXL_ENC_SUCCESS) {
			snprintf(err, err_cap, "JxlEncoderSetExtraChannelName failed");
			JxlEncoderDestroy(enc);
			return 0;
		}
	}
	if (JxlEncoderAddImageFrame(settings, &format, image->pixels, image->pixels_size) != JXL_ENC_SUCCESS) {
		snprintf(err, err_cap, "JxlEncoderAddImageFrame failed");
		JxlEncoderDestroy(enc);
		return 0;
	}
	if (extra_count != 0) {
		JxlPixelFormat extra_format = {
			1,
			JXL_TYPE_UINT8,
			JXL_NATIVE_ENDIAN,
			0,
		};
		for (size_t i = 0; i < extra_count; ++i) {
			if (
				JxlEncoderSetExtraChannelBuffer(
					settings,
					&extra_format,
					extras[i].image.pixels,
					extras[i].image.pixels_size,
					image->num_extra_channels + (uint32_t)i
				) != JXL_ENC_SUCCESS
			) {
				snprintf(err, err_cap, "JxlEncoderSetExtraChannelBuffer failed");
				JxlEncoderDestroy(enc);
				return 0;
			}
		}
	}
	JxlEncoderCloseInput(enc);

	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	size_t encoded_cap = 0;
	for (;;) {
		uint8_t chunk[64];
		uint8_t* next_out = chunk;
		size_t avail_out = sizeof(chunk);
		JxlEncoderStatus status = JxlEncoderProcessOutput(enc, &next_out, &avail_out);
		size_t produced = sizeof(chunk) - avail_out;
		if (produced && !append_chunk(&encoded, &encoded_size, &encoded_cap, chunk, produced)) {
			snprintf(err, err_cap, "append encoded bytes failed");
			free(encoded);
			JxlEncoderDestroy(enc);
			return 0;
		}
		if (status == JXL_ENC_SUCCESS) break;
		if (status != JXL_ENC_NEED_MORE_OUTPUT) {
			snprintf(err, err_cap, "JxlEncoderProcessOutput failed");
			free(encoded);
			JxlEncoderDestroy(enc);
			return 0;
		}
	}

	JxlEncoderDestroy(enc);
	*encoded_out = encoded;
	*encoded_size_out = encoded_size;
	return 1;
}

int cjxlz_main(int argc, char** argv) {
#ifdef JXLZ_DEBUG_BUILD
	fprintf(stderr, "\x1b[33mDEBUG BUILD\x1b[0m\n");
#endif

	const char* input_path = NULL;
	const char* output_path = NULL;
	ParsedExtraInput extras[MAX_EXTRA_INPUTS];
	memset(extras, 0, sizeof(extras));
	size_t extra_count = 0;

	for (int i = 1; i < argc; ++i) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			print_help(stdout);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			printf("cjxlz %u %s %s\n", JxlEncoderVersion(), platform_name(), arch_name());
			return 0;
		}
		if (strcmp(argv[i], "--extra") == 0) {
			if (i + 2 >= argc) {
				fprintf(stderr, "--extra requires TYPE and PATH\n");
				return 2;
			}
			if (extra_count >= MAX_EXTRA_INPUTS) {
				fprintf(stderr, "too many --extra arguments\n");
				return 2;
			}
			if (!parse_extra_type(argv[i + 1], &extras[extra_count].type, &extras[extra_count].type_name)) {
				fprintf(stderr, "unsupported extra type: %s\n", argv[i + 1]);
				return 2;
			}
			extras[extra_count].path = argv[i + 2];
			extra_count += 1;
			i += 2;
			continue;
		}
		if (argv[i][0] == '-' && argv[i][1] != '\0' && strcmp(argv[i], "-") != 0) {
			fprintf(stderr, "unknown option: %s\n", argv[i]);
			return 2;
		}
		if (!input_path) input_path = argv[i];
		else if (!output_path) output_path = argv[i];
		else {
			fprintf(stderr, "too many positional arguments\n");
			return 2;
		}
	}

	if (!input_path || !output_path) {
		print_help(stderr);
		return 2;
	}

	size_t input_size = 0;
	uint8_t* input = read_path(input_path, &input_size);
	if (!input) {
		fprintf(stderr, "failed to read input: %s\n", input_path);
		return 1;
	}

	char err[256];
	err[0] = '\0';
	ParsedImage image;
	if (!parse_pnm(input, input_size, &image, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err[0] ? err : "parse failed");
		free(input);
		return 1;
	}

	for (size_t i = 0; i < extra_count; ++i) {
		if (!parse_extra_input(&extras[i], image.width, image.height, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err[0] ? err : "extra parse failed");
			for (size_t j = 0; j < extra_count; ++j) free(extras[j].file_data);
			free(input);
			return 1;
		}
	}

	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	if (!encode_image(&image, extras, extra_count, &encoded, &encoded_size, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err[0] ? err : "encode failed");
		for (size_t i = 0; i < extra_count; ++i) free(extras[i].file_data);
		free(input);
		return 1;
	}
	for (size_t i = 0; i < extra_count; ++i) free(extras[i].file_data);
	free(input);

	FILE* out = open_output(output_path);
	if (!out) {
		fprintf(stderr, "failed to open output: %s\n", output_path);
		free(encoded);
		return 1;
	}

	if (fwrite(encoded, 1, encoded_size, out) != encoded_size) {
		fprintf(stderr, "failed to write output\n");
		close_output(output_path, out);
		free(encoded);
		return 1;
	}

	close_output(output_path, out);
	free(encoded);
	return 0;
}
