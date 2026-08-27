// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// Unified subcommand front end for libjxlz, covering what upstream ships as the
// separate djxl, cjxl, jxlinfo and jxltran binaries.
//
// Like the single-purpose CLIs, this is C on purpose: C cannot `@import` a Zig
// module, so the dogfooding requirement that every consumer go through the
// published header is enforced by the language rather than by policy. `decode`
// and `encode` dispatch into the existing djxlz/cjxlz entry points instead of
// reimplementing them, so there is exactly one implementation of each.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <jxl/decode.h>
#include <jxl/validate.h>

extern int djxlz_main(int argc, char** argv);
extern int cjxlz_main(int argc, char** argv);

#ifndef JXLZ_VERSION
#define JXLZ_VERSION 1000
#endif

static const char* platform_name(void) {
#if defined(_WIN32)
	return "windows";
#elif defined(__APPLE__)
	return "macos";
#else
	return "linux";
#endif
}

static const char* arch_name(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
	return "aarch64";
#else
	return "x86_64";
#endif
}

static void print_about(FILE* out) {
	fprintf(out, "jxlz %d %s %s\n", JXLZ_VERSION, platform_name(), arch_name());
}

static void print_help(FILE* out) {
	fprintf(out,
		"Usage: jxlz [options] <subcommand> [subcommand options] [arguments]\n"
		"\n"
		"One front end for the JPEG XL tools. Each subcommand takes its own\n"
		"options; run `jxlz <subcommand> --help` for those.\n"
		"\n"
		"Subcommands:\n"
		"  decode      Decode a JPEG XL file to PPM, PGM, PAM or GIF\n"
		"  encode      Encode an image into a JPEG XL file\n"
		"  info        Report codestream metadata without writing pixels\n"
		"  validate    Strict-validate a JPEG XL buffer (verdict, finding, feature)\n"
		"  transform   Lossless transforms of an existing file (not yet implemented)\n"
		"\n"
		"Aliases: d/dec = decode, e/enc = encode, i = info, v = validate\n"
		"\n"
		"Options:\n"
		"  -h, --help       Show this help, or a subcommand's help after it\n"
		"      --about      One-line description, version, platform and architecture\n"
		"      --version    Print the version number only\n"
		"      --lang CODE  Display language (also read from JXLZ_LANG, then LANG)\n"
		"      --no-color   Suppress ANSI colour (also --no-ansi)\n"
		"      --simple     Plain output: no colour, no Unicode decoration\n"
		"\n"
		"Everything after `--` is treated as a positional argument, never as a\n"
		"switch or a subcommand.\n"
		"\n"
		"Examples:\n"
		"  jxlz info photo.jxl\n"
		"  jxlz info --json photo.jxl\n"
		"  jxlz validate photo.jxl\n"
		"  jxlz validate --json photo.jxl\n"
		"  jxlz decode photo.jxl out.ppm\n"
		"  jxlz encode in.ppm out.jxl\n");
}

// Reads a whole stream into memory. Callers own the returned buffer.
static uint8_t* read_stream(FILE* f, size_t* size_out) {
	size_t cap = 1 << 16;
	size_t len = 0;
	uint8_t* buf = (uint8_t*)malloc(cap);
	if (buf == NULL) return NULL;
	for (;;) {
		if (len == cap) {
			size_t next = cap * 2;
			uint8_t* grown = (uint8_t*)realloc(buf, next);
			if (grown == NULL) {
				free(buf);
				return NULL;
			}
			buf = grown;
			cap = next;
		}
		size_t got = fread(buf + len, 1, cap - len, f);
		len += got;
		if (got == 0) {
			if (feof(f)) break;
			free(buf);
			return NULL;
		}
	}
	*size_out = len;
	return buf;
}

// Accepts "-" and "@stdin" as stdin, per the project's CLI conventions.
static uint8_t* read_path(const char* path, size_t* size_out) {
	if (strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0) {
		return read_stream(stdin, size_out);
	}
	FILE* f = fopen(path, "rb");
	if (f == NULL) return NULL;
	uint8_t* buf = read_stream(f, size_out);
	fclose(f);
	return buf;
}

typedef struct {
	uint32_t xsize;
	uint32_t ysize;
	uint32_t bits_per_sample;
	uint32_t num_color_channels;
	uint32_t num_extra_channels;
	uint32_t alpha_bits;
	bool have_animation;
	bool uses_original_profile;
} jxlz_info_fields;

// Pulls basic info through the public decoder API rather than reaching into the
// Zig core, so `info` exercises the same FFI surface every other consumer uses.
static int collect_info(const uint8_t* data, size_t size, jxlz_info_fields* out) {
	JxlDecoder* dec = JxlDecoderCreate(NULL);
	if (dec == NULL) return 1;

	int rc = 1;
	if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO) != JXL_DEC_SUCCESS) goto done;
	if (JxlDecoderSetInput(dec, data, size) != JXL_DEC_SUCCESS) goto done;
	JxlDecoderCloseInput(dec);

	for (;;) {
		JxlDecoderStatus status = JxlDecoderProcessInput(dec);
		if (status == JXL_DEC_BASIC_INFO) {
			JxlBasicInfo info;
			if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) goto done;
			out->xsize = info.xsize;
			out->ysize = info.ysize;
			out->bits_per_sample = info.bits_per_sample;
			out->num_color_channels = info.num_color_channels;
			out->num_extra_channels = info.num_extra_channels;
			out->alpha_bits = info.alpha_bits;
			out->have_animation = info.have_animation != 0;
			out->uses_original_profile = info.uses_original_profile != 0;
			rc = 0;
			goto done;
		}
		if (status == JXL_DEC_ERROR || status == JXL_DEC_NEED_MORE_INPUT ||
			status == JXL_DEC_SUCCESS) {
			goto done;
		}
	}

done:
	JxlDecoderDestroy(dec);
	return rc;
}

static void print_info_text(FILE* out, const jxlz_info_fields* f) {
	fprintf(out, "dimensions\t%ux%u\n", f->xsize, f->ysize);
	fprintf(out, "bits per sample\t%u\n", f->bits_per_sample);
	fprintf(out, "color channels\t%u\n", f->num_color_channels);
	fprintf(out, "extra channels\t%u\n", f->num_extra_channels);
	fprintf(out, "alpha bits\t%u\n", f->alpha_bits);
	fprintf(out, "animation\t%s\n", f->have_animation ? "yes" : "no");
	fprintf(out, "original profile\t%s\n", f->uses_original_profile ? "yes" : "no");
}

static void print_info_json(FILE* out, const jxlz_info_fields* f) {
	fprintf(out,
		"{\n"
		"  \"width\": %u,\n"
		"  \"height\": %u,\n"
		"  \"bits_per_sample\": %u,\n"
		"  \"num_color_channels\": %u,\n"
		"  \"num_extra_channels\": %u,\n"
		"  \"alpha_bits\": %u,\n"
		"  \"have_animation\": %s,\n"
		"  \"uses_original_profile\": %s\n"
		"}\n",
		f->xsize, f->ysize, f->bits_per_sample, f->num_color_channels,
		f->num_extra_channels, f->alpha_bits,
		f->have_animation ? "true" : "false",
		f->uses_original_profile ? "true" : "false");
}

static int run_info(int argc, char** argv) {
	bool json = false;
	bool no_more_switches = false;
	const char* path = NULL;

	for (int i = 0; i < argc; i++) {
		const char* arg = argv[i];
		if (!no_more_switches && strcmp(arg, "--") == 0) {
			no_more_switches = true;
			continue;
		}
		if (!no_more_switches && arg[0] == '-' && arg[1] != '\0') {
			if (strcmp(arg, "--json") == 0) {
				json = true;
			} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
				fprintf(stdout,
					"Usage: jxlz info [--json] <input.jxl>\n"
					"\n"
					"Report codestream metadata without decoding pixels.\n"
					"Accepts `-` or `@stdin` for the input path.\n"
					"\n"
					"Options:\n"
					"      --json   Emit the same fields as JSON for tooling\n"
					"  -h, --help   Show this help\n");
				return 0;
			} else {
				fprintf(stderr, "jxlz info: unknown option '%s'\n", arg);
				return 2;
			}
			continue;
		}
		// Later positional arguments override earlier ones.
		path = arg;
	}

	if (path == NULL) {
		fprintf(stderr, "jxlz info: expected an input path\n");
		return 2;
	}

	size_t size = 0;
	uint8_t* data = read_path(path, &size);
	if (data == NULL) {
		fprintf(stderr, "jxlz info: could not read '%s'\n", path);
		return 1;
	}

	jxlz_info_fields fields;
	memset(&fields, 0, sizeof(fields));
	int rc = collect_info(data, size, &fields);
	free(data);
	if (rc != 0) {
		fprintf(stderr, "jxlz info: '%s' is not a readable JPEG XL codestream\n", path);
		return 1;
	}

	if (json) {
		print_info_json(stdout, &fields);
	} else {
		print_info_text(stdout, &fields);
	}
	return 0;
}

static const char* verdict_name(JxlValidationVerdict verdict) {
	switch (verdict) {
	case JXL_VALIDATION_VALID: return "valid";
	case JXL_VALIDATION_CORRUPT: return "corrupt";
	case JXL_VALIDATION_UNSUPPORTED: return "unsupported";
	case JXL_VALIDATION_INDETERMINATE: return "indeterminate";
	}
	return "indeterminate";
}

static const char* finding_name(JxlValidationFindingCode code) {
	switch (code) {
	case JXL_VALIDATION_FINDING_NONE: return "none";
	case JXL_VALIDATION_FINDING_INVALID_SIGNATURE: return "invalid_signature";
	case JXL_VALIDATION_FINDING_TRUNCATED: return "truncated";
	case JXL_VALIDATION_FINDING_MALFORMED: return "malformed";
	case JXL_VALIDATION_FINDING_UNSUPPORTED_FEATURE: return "unsupported_feature";
	case JXL_VALIDATION_FINDING_RESOURCE_LIMIT: return "resource_limit";
	case JXL_VALIDATION_FINDING_OUT_OF_MEMORY: return "out_of_memory";
	case JXL_VALIDATION_FINDING_INVALID_ARGUMENT: return "invalid_argument";
	case JXL_VALIDATION_FINDING_UNCLASSIFIED_DECODER_ERROR: return "unclassified_decoder_error";
	}
	return "unclassified_decoder_error";
}

static void print_validate_text(FILE* out, const JxlValidationResult* r) {
	fprintf(out, "verdict\t%s\n", verdict_name(r->verdict));
	fprintf(out, "finding\t%s\n", finding_name(r->code));
	fprintf(out, "feature\t%s\n", JxlValidationFeatureName(r->feature));
	fprintf(out, "byte_offset\t%llu\n", (unsigned long long)r->byte_offset);
	fprintf(out, "host_byte_offset\t%llu\n", (unsigned long long)r->host_byte_offset);
	fprintf(out, "offset_is_exact\t%s\n", r->offset_is_exact ? "yes" : "no");
	fprintf(out, "frames_validated\t%u\n", r->frames_validated);
}

static void print_validate_json(FILE* out, const JxlValidationResult* r) {
	fprintf(out,
		"{\n"
		"  \"verdict\": \"%s\",\n"
		"  \"finding\": \"%s\",\n"
		"  \"feature\": \"%s\",\n"
		"  \"byte_offset\": %llu,\n"
		"  \"host_byte_offset\": %llu,\n"
		"  \"offset_is_exact\": %s,\n"
		"  \"frames_validated\": %u\n"
		"}\n",
		verdict_name(r->verdict),
		finding_name(r->code),
		JxlValidationFeatureName(r->feature),
		(unsigned long long)r->byte_offset,
		(unsigned long long)r->host_byte_offset,
		r->offset_is_exact ? "true" : "false",
		r->frames_validated);
}

// Strict-validates one bounded buffer through the public C FFI, the same
// surface jpegz/tiffz/validate consume. Exit 0 only for VALID so a one-liner
// coverage matrix can branch on status and still read the JSON body.
static int run_validate(int argc, char** argv) {
	bool json = false;
	bool no_more_switches = false;
	const char* path = NULL;
	JxlValidationOptions options = JXL_VALIDATION_OPTIONS_INIT;

	for (int i = 0; i < argc; i++) {
		const char* arg = argv[i];
		if (!no_more_switches && strcmp(arg, "--") == 0) {
			no_more_switches = true;
			continue;
		}
		if (!no_more_switches && arg[0] == '-' && arg[1] != '\0') {
			if (strcmp(arg, "--json") == 0) {
				json = true;
			} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
				fprintf(stdout,
					"Usage: jxlz validate [--json] <input.jxl>\n"
					"\n"
					"Strictly validate a JPEG XL codestream or container without\n"
					"decoding through an external implementation. Prints verdict,\n"
					"finding, named feature, offsets, exactness, and frames validated.\n"
					"Accepts `-` or `@stdin` for the input path.\n"
					"\n"
					"Exit status: 0 if valid, 1 if a verdict other than valid was\n"
					"reached (the report is still written to stdout), 2 on usage errors.\n"
					"\n"
					"Options:\n"
					"      --json   Emit the same fields as JSON for tooling\n"
					"  -h, --help   Show this help\n");
				return 0;
			} else {
				fprintf(stderr, "jxlz validate: unknown option '%s'\n", arg);
				return 2;
			}
			continue;
		}
		path = arg;
	}

	if (path == NULL) {
		fprintf(stderr, "jxlz validate: expected an input path\n");
		return 2;
	}

	size_t size = 0;
	uint8_t* data = read_path(path, &size);
	if (data == NULL) {
		fprintf(stderr, "jxlz validate: could not read '%s'\n", path);
		return 1;
	}

	JxlValidationResult result;
	JxlValidationVerdict verdict = JxlValidate(data, size, &options, &result);
	free(data);

	if (json) {
		print_validate_json(stdout, &result);
	} else {
		print_validate_text(stdout, &result);
	}
	return verdict == JXL_VALIDATION_VALID ? 0 : 1;
}

// Rebuilds argv for a delegated subcommand so argv[0] reads as `jxlz decode`
// rather than the bare program name, then hands off to the existing entry point.
static int delegate(int (*entry)(int, char**), const char* display, int argc, char** argv) {
	char** sub = (char**)malloc(sizeof(char*) * (size_t)(argc + 2));
	if (sub == NULL) return 1;
	sub[0] = (char*)display;
	for (int i = 0; i < argc; i++) sub[i + 1] = argv[i];
	sub[argc + 1] = NULL;
	int rc = entry(argc + 1, sub);
	free(sub);
	return rc;
}

static bool matches(const char* arg, const char* full, const char* a, const char* b) {
	if (strcmp(arg, full) == 0) return true;
	if (a != NULL && strcmp(arg, a) == 0) return true;
	if (b != NULL && strcmp(arg, b) == 0) return true;
	return false;
}

int jxlz_main(int argc, char** argv) {
#ifdef JXLZ_DEBUG_BUILD
	if (getenv("MUTE_DEBUG_STATUS") == NULL) {
		fprintf(stderr, "\x1b[33mDEBUG BUILD\x1b[0m\n");
	}
#endif

	int i = 1;
	bool want_help = false;

	// Global switches may appear in any order before the subcommand. Anything
	// after `--` is positional, so it can never be mistaken for a subcommand.
	for (; i < argc; i++) {
		const char* arg = argv[i];
		if (strcmp(arg, "--") == 0) {
			i++;
			break;
		}
		if (arg[0] != '-' || arg[1] == '\0') break;

		if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			want_help = true;
		} else if (strcmp(arg, "--about") == 0) {
			print_about(stdout);
			return 0;
		} else if (strcmp(arg, "--version") == 0) {
			fprintf(stdout, "%d\n", JXLZ_VERSION);
			return 0;
		} else if (strcmp(arg, "--no-color") == 0 || strcmp(arg, "--no-ansi") == 0 ||
				   strcmp(arg, "--simple") == 0) {
			// Presentation only; the dispatcher itself emits no decoration yet.
			continue;
		} else if (strcmp(arg, "--lang") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "jxlz: --lang requires a language code\n");
				return 2;
			}
			i++;  // i18n groundwork: accepted and validated, not yet applied.
		} else {
			fprintf(stderr, "jxlz: unknown option '%s'\n", arg);
			fprintf(stderr, "Run `jxlz --help` for usage.\n");
			return 2;
		}
	}

	if (i >= argc) {
		if (want_help) {
			print_help(stdout);
			return 0;
		}
		fprintf(stderr, "jxlz: expected a subcommand\n");
		fprintf(stderr, "Run `jxlz --help` for usage.\n");
		return 2;
	}

	const char* sub = argv[i];
	int rest_argc = argc - i - 1;
	char** rest_argv = argv + i + 1;

	if (matches(sub, "help", NULL, NULL)) {
		print_help(stdout);
		return 0;
	}
	if (matches(sub, "decode", "d", "dec")) {
		return delegate(djxlz_main, "jxlz decode", rest_argc, rest_argv);
	}
	if (matches(sub, "encode", "e", "enc")) {
		return delegate(cjxlz_main, "jxlz encode", rest_argc, rest_argv);
	}
	if (matches(sub, "info", "i", NULL)) {
		if (want_help) {
			char* help_argv[1];
			help_argv[0] = (char*)"--help";
			return run_info(1, help_argv);
		}
		return run_info(rest_argc, rest_argv);
	}
	if (matches(sub, "validate", "v", NULL)) {
		if (want_help) {
			char* help_argv[1];
			help_argv[0] = (char*)"--help";
			return run_validate(1, help_argv);
		}
		return run_validate(rest_argc, rest_argv);
	}
	if (matches(sub, "transform", "t", NULL)) {
		fprintf(stderr,
			"jxlz transform: not yet implemented.\n"
			"Upstream jxltran performs lossless transforms that libjxlz does not\n"
			"support yet. Use `jxlz decode` and `jxlz encode` in the meantime.\n");
		return 3;
	}

	fprintf(stderr, "jxlz: unknown subcommand '%s'\n", sub);
	fprintf(stderr, "Run `jxlz --help` for the list of subcommands.\n");
	return 2;
}
