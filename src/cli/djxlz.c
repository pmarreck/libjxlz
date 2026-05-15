#include <stdbool.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <jxl/decode.h>

#ifdef JXLZ_HAVE_GIF_OUTPUT
#include <gif_lib.h>
#if defined(_WIN32)
#include <io.h>
#define jxlz_dup _dup
#define jxlz_close _close
#define jxlz_fileno _fileno
#else
#include <unistd.h>
#define jxlz_dup dup
#define jxlz_close close
#define jxlz_fileno fileno
#endif
#endif

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
		"Decode a JPEG XL codestream to PPM, PGM, PAM, or GIF using the public C FFI only.\n\n"
		"Options:\n"
		"  -h, --help               Show this help\n"
		"  --about                  Show version, platform, and architecture\n"
		"  --icc-profile-output P   Write the decoded original ICC profile to PATH\n"
		"  --output_format FORMAT   One of: ppm, pgm, pam, pnm, gif\n\n"
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
	if (strcasecmp(dot, ".gif") == 0) return "gif";
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

static int write_blob(FILE* out, const uint8_t* bytes, size_t size) {
	if (size == 0) return 1;
	return fwrite(bytes, 1, size, out) == size;
}

static int extract_icc_profile(const uint8_t* data, size_t size, uint8_t** icc_out, size_t* icc_size_out, char* err, size_t err_cap) {
	*icc_out = NULL;
	*icc_size_out = 0;

	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (!dec) {
		snprintf(err, err_cap, "JxlDecoderCreate failed");
		return 0;
	}
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING) != JXL_DEC_SUCCESS) {
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
		if (status == JXL_DEC_BASIC_INFO) continue;
		if (status == JXL_DEC_COLOR_ENCODING) {
			if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, icc_size_out) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderGetICCProfileSize failed");
				JxlDecoderDestroy(dec);
				return 0;
			}
			*icc_out = (uint8_t*)malloc(*icc_size_out == 0 ? 1 : *icc_size_out);
			if (!*icc_out) {
				snprintf(err, err_cap, "malloc failed");
				JxlDecoderDestroy(dec);
				return 0;
			}
			if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, *icc_out, *icc_size_out) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderGetColorAsICCProfile failed");
				free(*icc_out);
				*icc_out = NULL;
				*icc_size_out = 0;
				JxlDecoderDestroy(dec);
				return 0;
			}
			JxlDecoderDestroy(dec);
			return 1;
		}
		if (status == JXL_DEC_ERROR) {
			snprintf(err, err_cap, "JxlDecoderProcessInput failed");
			JxlDecoderDestroy(dec);
			return 0;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT || status == JXL_DEC_SUCCESS) {
			snprintf(err, err_cap, "decoder failed before color encoding");
			JxlDecoderDestroy(dec);
			return 0;
		}
	}
}

#ifdef JXLZ_HAVE_GIF_OUTPUT
static uint8_t quantize_rgb332_code(const uint8_t* pixel, uint32_t channels) {
	uint8_t r = pixel[0];
	uint8_t g = channels >= 3 ? pixel[1] : pixel[0];
	uint8_t b = channels >= 3 ? pixel[2] : pixel[0];
	return (uint8_t)((r & 0xe0u) | ((g & 0xe0u) >> 3) | ((b & 0xc0u) >> 6));
}

static GifColorType expand_rgb332_color(uint8_t code) {
	GifColorType color;
	uint8_t r = (uint8_t)((code >> 5) & 0x07u);
	uint8_t g = (uint8_t)((code >> 2) & 0x07u);
	uint8_t b = (uint8_t)(code & 0x03u);
	color.Red = (GifByteType)((r * 255u + 3u) / 7u);
	color.Green = (GifByteType)((g * 255u + 3u) / 7u);
	color.Blue = (GifByteType)((b * 255u + 1u) / 3u);
	return color;
}

static int next_power_of_two_int(int value) {
	int out = 1;
	while (out < value && out < 256) out <<= 1;
	return out;
}

static uint16_t frame_delay_centiseconds(const JxlBasicInfo* info, const JxlFrameHeader* frame_header) {
	if (info->have_animation == 0) return 0;
	if (info->animation.tps_numerator == 0) return 0;
	uint64_t num = (uint64_t)frame_header->duration * (uint64_t)info->animation.tps_denominator * 100u;
	uint64_t den = (uint64_t)info->animation.tps_numerator;
	uint64_t rounded = (num + den / 2u) / den;
	if (rounded > 0xffffu) rounded = 0xffffu;
	return (uint16_t)rounded;
}

static int write_loop_extension(GifFileType* gif, uint32_t num_loops) {
	const unsigned char app_id[11] = { 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0' };
	unsigned char loop_block[3];
	loop_block[0] = 1;
	loop_block[1] = (unsigned char)(num_loops & 0xffu);
	loop_block[2] = (unsigned char)((num_loops >> 8) & 0xffu);
	if (EGifPutExtensionLeader(gif, APPLICATION_EXT_FUNC_CODE) == GIF_ERROR) return 0;
	if (EGifPutExtensionBlock(gif, 11, app_id) == GIF_ERROR) return 0;
	if (EGifPutExtensionBlock(gif, 3, loop_block) == GIF_ERROR) return 0;
	if (EGifPutExtensionTrailer(gif) == GIF_ERROR) return 0;
	return 1;
}

static int prepare_gif_frame(
	const uint8_t* pixels,
	uint32_t width,
	uint32_t height,
	uint32_t channels,
	GifByteType* indices,
	ColorMapObject** color_map_out,
	int* transparent_index_out,
	char* err,
	size_t err_cap
) {
	bool used_codes[256] = { false };
	int code_to_index[256];
	size_t pixel_count = (size_t)width * height;
	int opaque_codes = 0;
	int transparent_index = NO_TRANSPARENT_COLOR;
	bool saw_transparent = false;

	for (int i = 0; i < 256; ++i) code_to_index[i] = -1;

	for (size_t i = 0; i < pixel_count; ++i) {
		const uint8_t* pixel = pixels + i * channels;
		bool transparent = (channels == 2 || channels == 4) && pixel[channels - 1] < 128u;
		if (transparent) {
			saw_transparent = true;
			continue;
		}
		uint8_t code = quantize_rgb332_code(pixel, channels);
		if (!used_codes[code]) {
			used_codes[code] = true;
			opaque_codes += 1;
		}
	}

	if (saw_transparent && opaque_codes >= 256) {
		snprintf(err, err_cap, "gif export needs one transparent slot but all 256 rgb332 colors are in use");
		return 0;
	}

	int used_entries = opaque_codes + (saw_transparent ? 1 : 0);
	if (used_entries <= 0) used_entries = 1;
	int color_count = next_power_of_two_int(used_entries < 2 ? 2 : used_entries);
	GifColorType colors[256];
	memset(colors, 0, sizeof(colors));

	int next_index = 0;
	if (saw_transparent) {
		transparent_index = next_index++;
	}

	for (int code = 0; code < 256; ++code) {
		if (!used_codes[code]) continue;
		code_to_index[code] = next_index;
		colors[next_index] = expand_rgb332_color((uint8_t)code);
		next_index += 1;
	}

	ColorMapObject* color_map = GifMakeMapObject(color_count, colors);
	if (!color_map) {
		snprintf(err, err_cap, "GifMakeMapObject failed");
		return 0;
	}

	for (size_t i = 0; i < pixel_count; ++i) {
		const uint8_t* pixel = pixels + i * channels;
		bool transparent = (channels == 2 || channels == 4) && pixel[channels - 1] < 128u;
		if (transparent) {
			indices[i] = (GifByteType)transparent_index;
			continue;
		}
		uint8_t code = quantize_rgb332_code(pixel, channels);
		int palette_index = code_to_index[code];
		if (palette_index < 0) {
			GifFreeMapObject(color_map);
			snprintf(err, err_cap, "gif palette mapping failed");
			return 0;
		}
		indices[i] = (GifByteType)palette_index;
	}

	*color_map_out = color_map;
	*transparent_index_out = transparent_index;
	return 1;
}

static int write_gif(const uint8_t* data, size_t size, FILE* out, char* err, size_t err_cap) {
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	uint8_t* pixels = NULL;
	size_t pixels_size = 0;
	JxlBasicInfo info;
	JxlFrameHeader frame_header;
	JxlPixelFormat format;
	int output_fd = -1;
	int gif_error = GIF_OK;
	GifFileType* gif = NULL;
	bool have_basic_info = false;
	bool have_frame_header = false;

	memset(&info, 0, sizeof(info));
	memset(&frame_header, 0, sizeof(frame_header));
	memset(&format, 0, sizeof(format));

	if (!dec) {
		snprintf(err, err_cap, "JxlDecoderCreate failed");
		return 0;
	}

	if (
		JxlDecoderSubscribeEvents(
			dec,
			JXL_DEC_BASIC_INFO |
				JXL_DEC_FRAME |
				JXL_DEC_FULL_IMAGE
		) != JXL_DEC_SUCCESS
	) {
		snprintf(err, err_cap, "JxlDecoderSubscribeEvents failed");
		goto fail;
	}

	if (JxlDecoderSetInput(dec, data, size) != JXL_DEC_SUCCESS) {
		snprintf(err, err_cap, "JxlDecoderSetInput failed");
		goto fail;
	}
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_ERROR) {
			snprintf(err, err_cap, "JxlDecoderProcessInput failed");
			goto fail;
		}
		if (status == JXL_DEC_NEED_MORE_INPUT) {
			snprintf(err, err_cap, "unexpected need-more-input");
			goto fail;
		}
		if (status == JXL_DEC_BASIC_INFO) {
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderGetBasicInfo failed");
				goto fail;
			}
			if (info.num_extra_channels > (info.alpha_bits != 0 ? 1u : 0u)) {
				snprintf(err, err_cap, "gif export only supports color channels plus optional alpha");
				goto fail;
			}

			format.num_channels = info.num_color_channels + (info.alpha_bits != 0 ? 1u : 0u);
			format.data_type = JXL_TYPE_UINT8;
			format.endianness = JXL_NATIVE_ENDIAN;
			format.align = 0;

			if (fflush(out) != 0) {
				snprintf(err, err_cap, "failed to flush output stream");
				goto fail;
			}
			output_fd = jxlz_dup(jxlz_fileno(out));
			if (output_fd < 0) {
				snprintf(err, err_cap, "failed to duplicate output file handle");
				goto fail;
			}
			gif = EGifOpenFileHandle(output_fd, &gif_error);
			if (!gif) {
				snprintf(err, err_cap, "failed to open GIF output: %s", GifErrorString(gif_error));
				output_fd = -1;
				goto fail;
			}
			output_fd = -1;
			EGifSetGifVersion(gif, true);
			if (EGifPutScreenDesc(gif, (int)info.xsize, (int)info.ysize, 8, 0, NULL) == GIF_ERROR) {
				snprintf(err, err_cap, "failed to write GIF screen descriptor: %s", GifErrorString(gif->Error));
				goto fail;
			}
			if (info.have_animation != 0 && !write_loop_extension(gif, info.animation.num_loops)) {
				snprintf(err, err_cap, "failed to write GIF loop extension: %s", GifErrorString(gif->Error));
				goto fail;
			}
			have_basic_info = true;
			continue;
		}
		if (status == JXL_DEC_FRAME) {
			if (JxlDecoderGetFrameHeader(dec, &frame_header) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderGetFrameHeader failed");
				goto fail;
			}
			have_frame_header = true;
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			if (!have_basic_info) {
				snprintf(err, err_cap, "image output requested before basic info");
				goto fail;
			}
			if (JxlDecoderImageOutBufferSize(dec, &format, &pixels_size) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderImageOutBufferSize failed");
				goto fail;
			}
			uint8_t* grown = (uint8_t*)realloc(pixels, pixels_size);
			if (!grown) {
				snprintf(err, err_cap, "malloc failed");
				goto fail;
			}
			pixels = grown;
			if (JxlDecoderSetImageOutBuffer(dec, &format, pixels, pixels_size) != JXL_DEC_SUCCESS) {
				snprintf(err, err_cap, "JxlDecoderSetImageOutBuffer failed");
				goto fail;
			}
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE) {
			if (!have_basic_info || !have_frame_header || !gif) {
				snprintf(err, err_cap, "gif frame arrived before header state");
				goto fail;
			}
			size_t pixel_count = (size_t)info.xsize * info.ysize;
			GifByteType* indices = (GifByteType*)malloc(pixel_count);
			ColorMapObject* color_map = NULL;
			int transparent_index = NO_TRANSPARENT_COLOR;
			if (!indices) {
				snprintf(err, err_cap, "gif index allocation failed");
				goto fail;
			}
			if (!prepare_gif_frame(pixels, info.xsize, info.ysize, format.num_channels, indices, &color_map, &transparent_index, err, err_cap)) {
				free(indices);
				goto fail;
			}

			GraphicsControlBlock gcb;
			memset(&gcb, 0, sizeof(gcb));
			gcb.TransparentColor = transparent_index;
			gcb.DelayTime = frame_delay_centiseconds(&info, &frame_header);
			gcb.DisposalMode = DISPOSE_DO_NOT;

			GifByteType gce[4];
			EGifGCBToExtension(&gcb, gce);
			if (EGifPutExtension(gif, GRAPHICS_EXT_FUNC_CODE, 4, gce) == GIF_ERROR) {
				GifFreeMapObject(color_map);
				free(indices);
				snprintf(err, err_cap, "failed to write GIF graphics control extension: %s", GifErrorString(gif->Error));
				goto fail;
			}

			if (EGifPutImageDesc(gif, 0, 0, (int)info.xsize, (int)info.ysize, false, color_map) == GIF_ERROR) {
				GifFreeMapObject(color_map);
				free(indices);
				snprintf(err, err_cap, "failed to write GIF image descriptor: %s", GifErrorString(gif->Error));
				goto fail;
			}
			for (uint32_t y = 0; y < info.ysize; ++y) {
				GifPixelType* row = indices + (size_t)y * info.xsize;
				if (EGifPutLine(gif, row, (int)info.xsize) == GIF_ERROR) {
					GifFreeMapObject(color_map);
					free(indices);
					snprintf(err, err_cap, "failed to write GIF raster data: %s", GifErrorString(gif->Error));
					goto fail;
				}
			}

			GifFreeMapObject(color_map);
			free(indices);
			have_frame_header = false;
			continue;
		}
		if (status == JXL_DEC_SUCCESS) {
			free(pixels);
			if (gif) {
				if (EGifCloseFile(gif, &gif_error) == GIF_ERROR) {
					JxlDecoderDestroy(dec);
					snprintf(err, err_cap, "failed to finalize GIF output: %s", GifErrorString(gif_error));
					return 0;
				}
			}
			JxlDecoderDestroy(dec);
			return 1;
		}
		snprintf(err, err_cap, "unexpected decoder status %d", (int)status);
		goto fail;
	}

fail:
	if (gif) EGifCloseFile(gif, &gif_error);
	if (output_fd >= 0) jxlz_close(output_fd);
	free(pixels);
	JxlDecoderDestroy(dec);
	return 0;
}
#endif

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
	const char* icc_profile_output_path = NULL;

	for (int i = 1; i < argc; ++i) {
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			print_help(stdout);
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			printf("djxlz %u %s %s\n", JxlDecoderVersion(), platform_name(), arch_name());
			return 0;
		}
		if (strcmp(argv[i], "--icc-profile-output") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "missing value for --icc-profile-output\n");
				return 2;
			}
			icc_profile_output_path = argv[++i];
			continue;
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
	FILE* out = open_output(output_path);
	if (!out) {
		fprintf(stderr, "failed to open output: %s\n", output_path);
		free(input);
		return 1;
	}
	uint8_t* extracted_icc = NULL;
	size_t extracted_icc_size = 0;
	if (icc_profile_output_path) {
		if (!extract_icc_profile(input, input_size, &extracted_icc, &extracted_icc_size, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err[0] ? err : "icc extraction failed");
			close_output(output_path, out);
			free(input);
			return 1;
		}
	}

	if (strcmp(output_format, "gif") == 0) {
#ifdef JXLZ_HAVE_GIF_OUTPUT
		if (!write_gif(input, input_size, out, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err[0] ? err : "gif export failed");
			close_output(output_path, out);
			free(extracted_icc);
			free(input);
			return 1;
		}
#else
		fprintf(stderr, "gif output is not supported in this build\n");
		close_output(output_path, out);
		free(extracted_icc);
		free(input);
		return 1;
#endif
	} else {
		DecodedImage image;
		if (!decode_image(input, input_size, output_format, &image, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err[0] ? err : "decode failed");
			close_output(output_path, out);
			free(extracted_icc);
			free(input);
			return 1;
		}
		if (!write_pnm(out, &image, output_format)) {
			fprintf(stderr, "failed to write output\n");
			close_output(output_path, out);
			free(image.pixels);
			free(extracted_icc);
			free(input);
			return 1;
		}
		free(image.pixels);
	}
	if (icc_profile_output_path) {
		FILE* icc_out = open_output(icc_profile_output_path);
		if (!icc_out) {
			fprintf(stderr, "failed to open icc output: %s\n", icc_profile_output_path);
			close_output(output_path, out);
			free(extracted_icc);
			free(input);
			return 1;
		}
		if (!write_blob(icc_out, extracted_icc, extracted_icc_size)) {
			fprintf(stderr, "failed to write icc output\n");
			close_output(icc_profile_output_path, icc_out);
			close_output(output_path, out);
			free(extracted_icc);
			free(input);
			return 1;
		}
		close_output(icc_profile_output_path, icc_out);
	}

	close_output(output_path, out);
	free(extracted_icc);
	free(input);
	return 0;
}
