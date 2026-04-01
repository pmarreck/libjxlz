#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/encode.h>

#ifdef JXLZ_HAVE_PNG_INPUT
#include <png.h>
#endif

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t channels;
	uint32_t num_color_channels;
	uint32_t num_extra_channels;
	const uint8_t* pixels;
	size_t pixels_size;
	uint8_t* owned_pixels;
} ParsedImage;

#define MAX_EXTRA_INPUTS 16

typedef struct {
	JxlExtraChannelType type;
	const char* type_name;
	const char* path;
	JxlExtraChannelInfo info;
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
		"Encode simple image inputs into JPEG XL using the public C FFI only.\n\n"
		"Options:\n"
		"  -h, --help                Show this help\n"
		"  --about                   Show version, platform, and architecture\n"
		"  --premultiplied-alpha     Mark the alpha channel as premultiplied/associated\n"
		"  --associated-alpha        Alias for --premultiplied-alpha\n"
		"  --linear-srgb             Use linear sRGB/gray instead of nonlinear sRGB\n"
		"  --alpha-name NAME         Set the alpha extra-channel name\n"
		"  --intensity-target NITS   Set tone-mapping intensity_target\n"
		"  --min-nits NITS           Set tone-mapping min_nits\n"
		"  --relative-to-max-display Mark tone mapping as relative_to_max_display\n"
		"  --linear-below VALUE      Set tone-mapping linear_below\n"
		"  --orientation N           Set orientation 1..8\n"
		"  --intrinsic-size WxH      Set intrinsic pixel size metadata\n"
		"  --extra TYPE PATH         Add a grayscale sidecar extra channel\n"
		"                            TYPE may be one of:\n"
		"                              alpha[:SHIFT]\n"
		"                              selection_mask[:SHIFT], depth[:SHIFT], black[:SHIFT]\n"
		"                              thermal[:SHIFT], optional[:SHIFT]\n"
		"                              spot_color:R,G,B,S\n"
		"                              cfa:N\n\n"
		"Formats:\n"
		"  INPUT may be "
#ifdef JXLZ_HAVE_PNG_INPUT
		"PNG, "
#endif
		"raw binary P5/P6 with MAXVAL 255, or narrow P7 PAM with\n"
		"  TUPLTYPE GRAYSCALE, RGB, GRAYSCALE_ALPHA, or RGB_ALPHA and MAXVAL 255\n"
		"  --extra PATH must be a "
#ifdef JXLZ_HAVE_PNG_INPUT
		"PNG or "
#endif
		"raw binary P5 grayscale image with matching dimensions\n"
		"  after optional SHIFT subsampling (for example depth:1 expects ceil(W/2)xceil(H/2))\n\n"
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

static int parse_f32_token(const char* token, float* value) {
	char* end = NULL;
	float parsed = strtof(token, &end);
	if (!end || *end != '\0') return 0;
	*value = parsed;
	return 1;
}

static int parse_spot_color(const char* args, JxlExtraChannelInfo* info) {
	const char* part = args;
	for (int i = 0; i < 4; ++i) {
		const char* comma = strchr(part, ',');
		size_t len = comma ? (size_t)(comma - part) : strlen(part);
		char token[32];
		if (len == 0 || len + 1 > sizeof(token)) return 0;
		memcpy(token, part, len);
		token[len] = '\0';
		if (!parse_f32_token(token, &info->spot_color[i])) return 0;
		if (i < 3) {
			if (!comma) return 0;
			part = comma + 1;
		} else {
			if (comma) return 0;
		}
	}
	return 1;
}

static int parse_cfa_channel(const char* args, JxlExtraChannelInfo* info) {
	uint32_t channel = 0;
	if (!args || !parse_u32_token(args, &channel)) return 0;
	info->cfa_channel = channel;
	return 1;
}

static int parse_dim_shift(const char* args, JxlExtraChannelInfo* info) {
	uint32_t shift = 0;
	if (!args || !parse_u32_token(args, &shift) || shift > 3) return 0;
	info->dim_shift = shift;
	return 1;
}

static int parse_intrinsic_size(const char* text, uint32_t* width, uint32_t* height) {
	const char* sep = strchr(text, 'x');
	if (!sep) sep = strchr(text, 'X');
	if (!sep) return 0;

	size_t width_len = (size_t)(sep - text);
	const char* height_text = sep + 1;
	if (width_len == 0 || *height_text == '\0') return 0;

	char width_buf[32];
	if (width_len + 1 > sizeof(width_buf)) return 0;
	memcpy(width_buf, text, width_len);
	width_buf[width_len] = '\0';

	if (!parse_u32_token(width_buf, width)) return 0;
	if (!parse_u32_token(height_text, height)) return 0;
	if (*width == 0 || *height == 0) return 0;
	return 1;
}

static int parse_extra_spec(ParsedExtraInput* extra, const char* text) {
	memset(&extra->info, 0, sizeof(extra->info));

	const char* sep = strchr(text, ':');
	size_t type_len = sep ? (size_t)(sep - text) : strlen(text);
	char type_name[64];
	if (type_len == 0 || type_len >= sizeof(type_name)) return 0;
	memcpy(type_name, text, type_len);
	type_name[type_len] = '\0';

	const char* args = sep ? sep + 1 : NULL;

	if (strcmp(type_name, "alpha") == 0) {
		extra->type = JXL_CHANNEL_ALPHA;
		extra->type_name = "alpha";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(text, "selection_mask") == 0 || strcmp(text, "selection-mask") == 0) {
		extra->type = JXL_CHANNEL_SELECTION_MASK;
		extra->type_name = "selection_mask";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		return 1;
	}
	if (strcmp(type_name, "depth") == 0) {
		extra->type = JXL_CHANNEL_DEPTH;
		extra->type_name = "depth";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "black") == 0) {
		extra->type = JXL_CHANNEL_BLACK;
		extra->type_name = "black";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "thermal") == 0) {
		extra->type = JXL_CHANNEL_THERMAL;
		extra->type_name = "thermal";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "optional") == 0) {
		extra->type = JXL_CHANNEL_OPTIONAL;
		extra->type_name = "optional";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "selection_mask") == 0 || strcmp(type_name, "selection-mask") == 0) {
		extra->type = JXL_CHANNEL_SELECTION_MASK;
		extra->type_name = "selection_mask";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (args && !parse_dim_shift(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "spot_color") == 0 && args) {
		extra->type = JXL_CHANNEL_SPOT_COLOR;
		extra->type_name = "spot_color";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (!parse_spot_color(args, &extra->info)) return 0;
		return 1;
	}
	if (strcmp(type_name, "cfa") == 0 && args) {
		extra->type = JXL_CHANNEL_CFA;
		extra->type_name = "cfa";
		JxlEncoderInitExtraChannelInfo(extra->type, &extra->info);
		if (!parse_cfa_channel(args, &extra->info)) return 0;
		return 1;
	}
	return 0;
}

static uint32_t subsampled_size(uint32_t size, uint32_t shift) {
	if (shift == 0) return size;
	uint32_t step = 1u << shift;
	return (size + step - 1) / step;
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

static int has_png_signature(const uint8_t* data, size_t size) {
	static const uint8_t signature[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
	return size >= sizeof(signature) && memcmp(data, signature, sizeof(signature)) == 0;
}

#ifdef JXLZ_HAVE_PNG_INPUT
static int parse_png(const uint8_t* data, size_t size, ParsedImage* image, char* err, size_t err_cap) {
	png_image png_image_state;
	memset(image, 0, sizeof(*image));
	memset(&png_image_state, 0, sizeof(png_image_state));
	png_image_state.version = PNG_IMAGE_VERSION;

	if (!png_image_begin_read_from_memory(&png_image_state, data, size)) {
		snprintf(err, err_cap, "png header read failed: %s", png_image_state.message);
		png_image_free(&png_image_state);
		return 0;
	}

	if (png_image_state.width == 0 || png_image_state.height == 0) {
		snprintf(err, err_cap, "png dimensions must be positive");
		png_image_free(&png_image_state);
		return 0;
	}

	const int is_color = (png_image_state.format & PNG_FORMAT_FLAG_COLOR) != 0;
	const int has_alpha = (png_image_state.format & PNG_FORMAT_FLAG_ALPHA) != 0;
	png_image_state.format = is_color ? (has_alpha ? PNG_FORMAT_RGBA : PNG_FORMAT_RGB) : (has_alpha ? PNG_FORMAT_GA : PNG_FORMAT_GRAY);

	const size_t pixels_size = PNG_IMAGE_SIZE(png_image_state);
	uint8_t* pixels = (uint8_t*)malloc(pixels_size);
	if (!pixels) {
		snprintf(err, err_cap, "png pixel allocation failed");
		png_image_free(&png_image_state);
		return 0;
	}

	if (!png_image_finish_read(&png_image_state, NULL, pixels, 0, NULL)) {
		snprintf(err, err_cap, "png decode failed: %s", png_image_state.message);
		free(pixels);
		png_image_free(&png_image_state);
		return 0;
	}

	image->width = png_image_state.width;
	image->height = png_image_state.height;
	image->channels = is_color ? (has_alpha ? 4 : 3) : (has_alpha ? 2 : 1);
	image->num_color_channels = is_color ? 3 : 1;
	image->num_extra_channels = has_alpha ? 1 : 0;
	image->pixels = pixels;
	image->pixels_size = pixels_size;
	image->owned_pixels = pixels;
	png_image_free(&png_image_state);
	return 1;
}
#endif

static int parse_input_image(const uint8_t* data, size_t size, ParsedImage* image, char* err, size_t err_cap) {
	if (has_png_signature(data, size)) {
#ifdef JXLZ_HAVE_PNG_INPUT
		return parse_png(data, size, image, err, err_cap);
#else
		snprintf(err, err_cap, "png input is not supported in this build");
		return 0;
#endif
	}
	return parse_pnm(data, size, image, err, err_cap);
}

static void free_parsed_image(ParsedImage* image) {
	if (!image) return;
	free(image->owned_pixels);
	memset(image, 0, sizeof(*image));
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
	if (!parse_input_image(extra->file_data, extra->file_size, &extra->image, err, err_cap)) {
		return 0;
	}
	const uint32_t expected_width = subsampled_size(width, extra->info.dim_shift);
	const uint32_t expected_height = subsampled_size(height, extra->info.dim_shift);
	if (
		extra->image.width != expected_width ||
		extra->image.height != expected_height ||
		extra->image.channels != 1 ||
		extra->image.num_color_channels != 1 ||
		extra->image.num_extra_channels != 0
	) {
		snprintf(
			err,
			err_cap,
			"--extra input must be a matching grayscale "
#ifdef JXLZ_HAVE_PNG_INPUT
			"PNG or "
#endif
			"P5 image for dim_shift=%u (%ux%u expected)",
			extra->info.dim_shift,
			expected_width,
			expected_height
		);
		return 0;
	}
	return 1;
}

static int encode_image(
	const ParsedImage* image,
	const ParsedExtraInput* extras,
	size_t extra_count,
	int alpha_premultiplied,
	int linear_srgb,
	const char* alpha_name,
	float intensity_target,
	float min_nits,
	int relative_to_max_display,
	float linear_below,
	int orientation,
	uint32_t intrinsic_width,
	uint32_t intrinsic_height,
	uint8_t** encoded_out,
	size_t* encoded_size_out,
	char* err,
	size_t err_cap
) {
	int staged_alpha_seen = 0;
	for (size_t i = 0; i < extra_count; ++i) {
		if (extras[i].type != JXL_CHANNEL_ALPHA) continue;
		if (image->num_extra_channels != 0) {
			snprintf(err, err_cap, "sidecar alpha is not supported when the main image already carries alpha");
			return 0;
		}
		if (staged_alpha_seen) {
			snprintf(err, err_cap, "only one sidecar alpha input is supported");
			return 0;
		}
		staged_alpha_seen = 1;
	}

	JxlBasicInfo info;
	JxlEncoderInitBasicInfo(&info);
	info.xsize = image->width;
	info.ysize = image->height;
	info.bits_per_sample = 8;
	info.num_color_channels = image->num_color_channels;
	info.num_extra_channels = image->num_extra_channels + (uint32_t)extra_count;
	info.alpha_bits = (image->num_extra_channels != 0 || staged_alpha_seen) ? 8 : 0;
	info.intensity_target = intensity_target;
	info.min_nits = min_nits;
	info.relative_to_max_display = relative_to_max_display ? 1 : 0;
	info.linear_below = linear_below;
	info.orientation = (JxlOrientation)orientation;
	info.intrinsic_xsize = intrinsic_width;
	info.intrinsic_ysize = intrinsic_height;
	if (info.alpha_bits == 0 && alpha_premultiplied) {
		snprintf(err, err_cap, "--premultiplied-alpha requires an alpha channel");
		return 0;
	}
	if (info.alpha_bits == 0 && alpha_name) {
		snprintf(err, err_cap, "--alpha-name requires an alpha channel");
		return 0;
	}
	info.alpha_premultiplied = alpha_premultiplied ? 1 : 0;

	JxlColorEncoding color;
	if (linear_srgb) {
		JxlColorEncodingSetToLinearSRGB(&color, image->num_color_channels == 1 ? 1 : 0);
	} else {
		JxlColorEncodingSetToSRGB(&color, image->num_color_channels == 1 ? 1 : 0);
	}

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
	if (alpha_name) {
		JxlExtraChannelInfo alpha;
		JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_ALPHA, &alpha);
		alpha.alpha_premultiplied = info.alpha_premultiplied;
		if (JxlEncoderSetExtraChannelInfo(enc, 0, &alpha) != JXL_ENC_SUCCESS) {
			snprintf(err, err_cap, "JxlEncoderSetExtraChannelInfo failed");
			JxlEncoderDestroy(enc);
			return 0;
		}
		if (JxlEncoderSetExtraChannelName(enc, 0, alpha_name, strlen(alpha_name)) != JXL_ENC_SUCCESS) {
			snprintf(err, err_cap, "JxlEncoderSetExtraChannelName failed");
			JxlEncoderDestroy(enc);
			return 0;
		}
	}
	for (size_t i = 0; i < extra_count; ++i) {
		uint32_t extra_index = image->num_extra_channels + (uint32_t)i;
		if (staged_alpha_seen && image->num_extra_channels == 0) {
			if (extras[i].type == JXL_CHANNEL_ALPHA) {
				extra_index = 0;
			} else {
				uint32_t non_alpha_before = 0;
				for (size_t j = 0; j < i; ++j) {
					if (extras[j].type != JXL_CHANNEL_ALPHA) ++non_alpha_before;
				}
				extra_index = 1 + non_alpha_before;
			}
		}
		JxlExtraChannelInfo extra_info = extras[i].info;
		if (extras[i].type == JXL_CHANNEL_ALPHA) {
			extra_info.alpha_premultiplied = info.alpha_premultiplied;
		}
		if (JxlEncoderSetExtraChannelInfo(enc, extra_index, &extra_info) != JXL_ENC_SUCCESS) {
			snprintf(err, err_cap, "JxlEncoderSetExtraChannelInfo failed");
			JxlEncoderDestroy(enc);
			return 0;
		}
		if (extras[i].type != JXL_CHANNEL_ALPHA && JxlEncoderSetExtraChannelName(enc, extra_index, extras[i].type_name, strlen(extras[i].type_name)) != JXL_ENC_SUCCESS) {
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
			uint32_t extra_index = image->num_extra_channels + (uint32_t)i;
			if (staged_alpha_seen && image->num_extra_channels == 0) {
				if (extras[i].type == JXL_CHANNEL_ALPHA) {
					extra_index = 0;
				} else {
					uint32_t non_alpha_before = 0;
					for (size_t j = 0; j < i; ++j) {
						if (extras[j].type != JXL_CHANNEL_ALPHA) ++non_alpha_before;
					}
					extra_index = 1 + non_alpha_before;
				}
			}
			if (
				JxlEncoderSetExtraChannelBuffer(
					settings,
					&extra_format,
					extras[i].image.pixels,
					extras[i].image.pixels_size,
					extra_index
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
	int alpha_premultiplied = 0;
	int linear_srgb = 0;
	const char* alpha_name = NULL;
	float intensity_target = 255.0f;
	float min_nits = 0.0f;
	int relative_to_max_display = 0;
	float linear_below = 0.0f;
	int orientation = 1;
	uint32_t intrinsic_width = 0;
	uint32_t intrinsic_height = 0;
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
		if (strcmp(argv[i], "--premultiplied-alpha") == 0 || strcmp(argv[i], "--associated-alpha") == 0) {
			alpha_premultiplied = 1;
			continue;
		}
		if (strcmp(argv[i], "--linear-srgb") == 0) {
			linear_srgb = 1;
			continue;
		}
		if (strcmp(argv[i], "--alpha-name") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "--alpha-name requires NAME\n");
				return 2;
			}
			alpha_name = argv[i + 1];
			i += 1;
			continue;
		}
		if (strcmp(argv[i], "--intensity-target") == 0) {
			if (i + 1 >= argc || !parse_f32_token(argv[i + 1], &intensity_target)) {
				fprintf(stderr, "--intensity-target requires NITS\n");
				return 2;
			}
			i += 1;
			continue;
		}
		if (strcmp(argv[i], "--min-nits") == 0) {
			if (i + 1 >= argc || !parse_f32_token(argv[i + 1], &min_nits)) {
				fprintf(stderr, "--min-nits requires NITS\n");
				return 2;
			}
			i += 1;
			continue;
		}
		if (strcmp(argv[i], "--relative-to-max-display") == 0) {
			relative_to_max_display = 1;
			continue;
		}
		if (strcmp(argv[i], "--linear-below") == 0) {
			if (i + 1 >= argc || !parse_f32_token(argv[i + 1], &linear_below)) {
				fprintf(stderr, "--linear-below requires VALUE\n");
				return 2;
			}
			i += 1;
			continue;
		}
		if (strcmp(argv[i], "--orientation") == 0) {
			uint32_t parsed = 0;
			if (i + 1 >= argc || !parse_u32_token(argv[i + 1], &parsed) || parsed < 1 || parsed > 8) {
				fprintf(stderr, "--orientation requires a value in 1..8\n");
				return 2;
			}
			orientation = (int)parsed;
			i += 1;
			continue;
		}
		if (strcmp(argv[i], "--intrinsic-size") == 0) {
			if (i + 1 >= argc || !parse_intrinsic_size(argv[i + 1], &intrinsic_width, &intrinsic_height)) {
				fprintf(stderr, "--intrinsic-size requires WxH with positive dimensions\n");
				return 2;
			}
			i += 1;
			continue;
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
			if (!parse_extra_spec(&extras[extra_count], argv[i + 1])) {
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
	if (!parse_input_image(input, input_size, &image, err, sizeof(err))) {
		fprintf(stderr, "%s\n", err[0] ? err : "parse failed");
		free(input);
		return 1;
	}

	for (size_t i = 0; i < extra_count; ++i) {
		if (!parse_extra_input(&extras[i], image.width, image.height, err, sizeof(err))) {
			fprintf(stderr, "%s\n", err[0] ? err : "extra parse failed");
			for (size_t j = 0; j < extra_count; ++j) {
				free_parsed_image(&extras[j].image);
				free(extras[j].file_data);
			}
			free_parsed_image(&image);
			free(input);
			return 1;
		}
	}

	uint8_t* encoded = NULL;
	size_t encoded_size = 0;
	if (!encode_image(
		&image,
		extras,
		extra_count,
		alpha_premultiplied,
		linear_srgb,
		alpha_name,
		intensity_target,
		min_nits,
		relative_to_max_display,
		linear_below,
		orientation,
		intrinsic_width,
		intrinsic_height,
		&encoded,
		&encoded_size,
		err,
		sizeof(err)
	)) {
		fprintf(stderr, "%s\n", err[0] ? err : "encode failed");
		for (size_t i = 0; i < extra_count; ++i) {
			free_parsed_image(&extras[i].image);
			free(extras[i].file_data);
		}
		free_parsed_image(&image);
		free(input);
		return 1;
	}
	for (size_t i = 0; i < extra_count; ++i) {
		free_parsed_image(&extras[i].image);
		free(extras[i].file_data);
	}
	free_parsed_image(&image);
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
