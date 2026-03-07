#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <jxl/decode.h>

typedef struct {
	uint8_t* pixels;
	size_t pixels_size;
	JxlBasicInfo info;
	JxlPixelFormat format;
} DecodedImage;

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
		"Usage: djxlz [options] INPUT OUTPUT\n"
		"Decode a JPEG XL codestream to PPM, PGM, or PAM using the public C FFI only.\n\n"
		"Options:\n"
		"  -h, --help               Show this help\n"
		"  --about                  Show version, platform, and architecture\n"
		"  --output_format FORMAT   One of: ppm, pgm, pam, pnm\n\n"
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

static const char* infer_output_format(const char* output_path) {
	const char* dot = strrchr(output_path, '.');
	if (!dot) return NULL;
	if (strcasecmp(dot, ".ppm") == 0) return "ppm";
	if (strcasecmp(dot, ".pgm") == 0) return "pgm";
	if (strcasecmp(dot, ".pam") == 0) return "pam";
	if (strcasecmp(dot, ".pnm") == 0) return "pnm";
	return NULL;
}

static int decode_image(const uint8_t* data, size_t size, const char* output_format, DecodedImage* out, char* err, size_t err_cap) {
	memset(out, 0, sizeof(*out));
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		snprintf(err, err_cap, "JxlDecoderCreate failed");
		return 0;
	}

	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
		snprintf(err, err_cap, "JxlDecoderSubscribeEvents failed");
		JxlDecoderDestroy(dec);
		return 0;
	}

	if (JxlDecoderSetInput(dec, data, size) != JXL_DEC_SUCCESS) {
		snprintf(err, err_cap, "JxlDecoderSetInput failed");
		JxlDecoderDestroy(dec);
		return 0;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_ERROR) {
			snprintf(err, err_cap, "JxlDecoderProcessInput failed");
			free(out->pixels);
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT) {
			snprintf(err, err_cap, "unexpected need-more-input");
			free(out->pixels);
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &out->info) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderGetBasicInfo failed");
				free(out->pixels);
				JxlDecoderDestroy(dec);
				return 0;
			}
			out->format.data_type = JXL_TYPE_UINT8;
			out->format.endianness = JXL_NATIVE_ENDIAN;
			out->format.align = 0;

			if (strcmp(output_format, "pgm") == 0) {
				out->format.num_channels = 1;
			} else if (strcmp(output_format, "ppm") == 0 || strcmp(output_format, "pnm") == 0) {
				out->format.num_channels = 3;
			} else if (strcmp(output_format, "pam") == 0) {
				out->format.num_channels = out->info.num_color_channels + (out->info.alpha_bits != 0 ? 1u : 0u);
			} else {
				snprintf(err, err_cap, "unsupported output format");
				JxlDecoderDestroy(dec);
				return 0;
			}
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (JxlDecoderImageOutBufferSize(dec, &out->format, &out->pixels_size) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderImageOutBufferSize failed");
				free(out->pixels);
				JxlDecoderDestroy(dec);
				return 0;
			}
			out->pixels = (uint8_t*)malloc(out->pixels_size);
			if (!out->pixels) {
				snprintf(err, err_cap, "malloc failed");
				JxlDecoderDestroy(dec);
				return 0;
			}
			if (JxlDecoderSetImageOutBuffer(dec, &out->format, out->pixels, out->pixels_size) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderSetImageOutBuffer failed");
				free(out->pixels);
				JxlDecoderDestroy(dec);
				return 0;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			continue;
		}
		if (status == JXL_DEC_SUCCESS) {
			JxlDecoderDestroy(dec);
			return 1;
		}
		snprintf(err, err_cap, "unexpected decoder status %d", (int)status);
		free(out->pixels);
		JxlDecoderDestroy(dec);
		return 0;
	}
}

static int write_pnm(FILE* out, const DecodedImage* image, const char* output_format) {
	uint32_t channels = image->format.num_channels;
	uint32_t width = image->info.xsize;
	uint32_t height = image->info.ysize;

	if ((strcmp(output_format, "ppm") == 0 || strcmp(output_format, "pnm") == 0) && channels != 3) return 0;
	if (strcmp(output_format, "pgm") == 0 && channels != 1) return 0;

	if (strcmp(output_format, "pam") == 0) {
		const char* tuple = channels == 1 ? "GRAYSCALE" : channels == 2 ? "GRAYSCALE_ALPHA" : channels == 3 ? "RGB" : "RGB_ALPHA";
		if (fprintf(out,
			"P7\nWIDTH %u\nHEIGHT %u\nDEPTH %u\nMAXVAL 255\nTUPLTYPE %s\nENDHDR\n",
			width,
			height,
			channels,
			tuple) < 0) return 0;
	} else if (channels == 1) {
		if (fprintf(out, "P5\n%u %u\n255\n", width, height) < 0) return 0;
	} else if (channels == 3) {
		if (fprintf(out, "P6\n%u %u\n255\n", width, height) < 0) return 0;
	} else {
		return 0;
	}

	return fwrite(image->pixels, 1, image->pixels_size, out) == image->pixels_size;
}

int djxlz_main(int argc, char** argv) {
#ifdef JXLZ_DEBUG_BUILD
	fprintf(stderr, "\x1b[33mDEBUG BUILD\x1b[0m\n");
#endif

	const char* output_format = NULL;
	const char* input_path = NULL;
	const char* output_path = NULL;

	for (int i = 1; i < argc; ++i) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			print_help(stdout);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			printf("djxlz %u %s %s\n", JxlDecoderVersion(), platform_name(), arch_name());
			return 0;
		}
		if (strcmp(argv[i], "--output_format") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "missing value for --output_format\n");
				return 2;
			}
			output_format = argv[++i];
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

	if (!output_format) {
		output_format = infer_output_format(output_path);
		if (!output_format) output_format = "pnm";
	}

	size_t input_size = 0;
	uint8_t* input = read_path(input_path, &input_size);
	if (!input) {
		fprintf(stderr, "failed to read input: %s\n", input_path);
		return 1;
	}

	char err[256];
	err[0] = '\0';
	DecodedImage image;
	if (!decode_image(input, input_size, output_format, &image, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err[0] ? err : "decode failed");
		free(input);
		return 1;
	}
	free(input);

	FILE* out = open_output(output_path);
	if (!out) {
		fprintf(stderr, "failed to open output: %s\n", output_path);
		free(image.pixels);
		return 1;
	}

	if (!write_pnm(out, &image, output_format)) {
		fprintf(stderr, "failed to write output\n");
		close_output(output_path, out);
		free(image.pixels);
		return 1;
	}

	close_output(output_path, out);
	free(image.pixels);
	return 0;
}
