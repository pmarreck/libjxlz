/* Copyright (c) Peter Marreck and libjxlz contributors.
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef JXL_VALIDATE_H_
#define JXL_VALIDATE_H_

#include <jxl/jxl_export.h>
#include <jxl/types.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** A strict validation outcome. Unsupported files are kept separate from corrupt files. */
typedef enum {
	JXL_VALIDATION_VALID = 0,
	JXL_VALIDATION_CORRUPT = 1,
	JXL_VALIDATION_UNSUPPORTED = 2,
	JXL_VALIDATION_INDETERMINATE = 3,
} JxlValidationVerdict;

/** Stable first-finding codes. More detail may be added without changing verdict semantics. */
typedef enum {
	JXL_VALIDATION_FINDING_NONE = 0,
	JXL_VALIDATION_FINDING_INVALID_SIGNATURE = 1,
	JXL_VALIDATION_FINDING_TRUNCATED = 2,
	JXL_VALIDATION_FINDING_MALFORMED = 3,
	JXL_VALIDATION_FINDING_UNSUPPORTED_FEATURE = 4,
	JXL_VALIDATION_FINDING_RESOURCE_LIMIT = 5,
	JXL_VALIDATION_FINDING_OUT_OF_MEMORY = 6,
	JXL_VALIDATION_FINDING_INVALID_ARGUMENT = 7,
	JXL_VALIDATION_FINDING_UNCLASSIFIED_DECODER_ERROR = 8,
} JxlValidationFindingCode;

/**
 * The specific JPEG XL feature that stopped validation, when the verdict is
 * unsupported. `UNKNOWN` means a rejection site has not been given a name yet;
 * it is reported rather than `NONE` so uninstrumented sites stay visible.
 * Values are ABI: appended, never renumbered.
 */
typedef enum {
	JXL_VALIDATION_FEATURE_NONE = 0,
	JXL_VALIDATION_FEATURE_UNKNOWN = 1,
	JXL_VALIDATION_FEATURE_VARDCT_FRAME = 2,
	JXL_VALIDATION_FEATURE_PATCHES = 3,
	JXL_VALIDATION_FEATURE_NOISE = 4,
	JXL_VALIDATION_FEATURE_SPLINES = 5,
	JXL_VALIDATION_FEATURE_PROGRESSIVE_DC_FRAME = 6,
	JXL_VALIDATION_FEATURE_REFERENCE_FRAME = 7,
	JXL_VALIDATION_FEATURE_MODULAR_TRANSFORM = 8,
	JXL_VALIDATION_FEATURE_EXTRA_CHANNEL_TYPE = 9,
	JXL_VALIDATION_FEATURE_COLOR_ENCODING = 10,
	JXL_VALIDATION_FEATURE_ICC_PROFILE = 11,
	JXL_VALIDATION_FEATURE_BIT_DEPTH = 12,
	JXL_VALIDATION_FEATURE_CHROMA_SUBSAMPLING = 13,
	JXL_VALIDATION_FEATURE_FRAME_BLENDING = 14,
	JXL_VALIDATION_FEATURE_UPSAMPLING = 15,
	JXL_VALIDATION_FEATURE_CONTAINER_BOX = 16,
	JXL_VALIDATION_FEATURE_JPEG_RECONSTRUCTION = 17,
	JXL_VALIDATION_FEATURE_ANIMATION = 18,
	JXL_VALIDATION_FEATURE_PREVIEW_FRAME = 19,
	JXL_VALIDATION_FEATURE_COLOR_CHANNEL_COUNT = 20,
	JXL_VALIDATION_FEATURE_CODESTREAM_EXTENSION = 21,
} JxlValidationFeature;

enum {
	JXL_VALIDATION_DEFAULT_MAX_INPUT_BYTES = 512U * 1024U * 1024U,
	JXL_VALIDATION_DEFAULT_MAX_FRAMES = 65535U,
};

#define JXL_VALIDATION_DEFAULT_MAX_PIXELS UINT64_C(268435456)

typedef struct {
	size_t struct_size;
	uint64_t host_byte_offset;
	size_t max_input_bytes;
	uint64_t max_pixels;
	uint32_t max_frames;
} JxlValidationOptions;

#define JXL_VALIDATION_OPTIONS_INIT { \
	sizeof(JxlValidationOptions), 0, \
	JXL_VALIDATION_DEFAULT_MAX_INPUT_BYTES, \
	JXL_VALIDATION_DEFAULT_MAX_PIXELS, \
	JXL_VALIDATION_DEFAULT_MAX_FRAMES \
}

typedef struct {
	JxlValidationVerdict verdict;
	JxlValidationFindingCode code;
	uint64_t byte_offset;
	uint64_t host_byte_offset;
	JXL_BOOL offset_is_exact;
	uint32_t frames_validated;
	/** Set when `verdict` is unsupported; `NONE` otherwise. */
	JxlValidationFeature feature;
} JxlValidationResult;

/**
 * Strictly validates one bounded in-memory JPEG XL codestream or container.
 *
 * No read is performed outside `data[0..size]`. `host_byte_offset` lets an
 * embedding parser report offsets in its containing file. Unsupported valid
 * syntax is never returned as corrupt. A resource limit or allocation failure
 * yields indeterminate, so callers cannot mistake incomplete work for success.
 * Decoder failures lacking a typed violated invariant are also indeterminate.
 */
JXL_EXPORT JxlValidationVerdict JxlValidate(
	const uint8_t* data,
	size_t size,
	const JxlValidationOptions* options,
	JxlValidationResult* result
);

/** Stable ASCII name for a feature code. Never NULL, never empty. */
JXL_EXPORT const char* JxlValidationFeatureName(JxlValidationFeature feature);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* JXL_VALIDATE_H_ */
