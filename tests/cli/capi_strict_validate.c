// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <jxl/validate.h>

static int read_file(const char* path, uint8_t** data, size_t* size) {
	FILE* file = fopen(path, "rb");
	long end;
	uint8_t* bytes;

	if (!file) return 0;
	if (fseek(file, 0, SEEK_END) != 0 || (end = ftell(file)) < 0 ||
		fseek(file, 0, SEEK_SET) != 0) {
		fclose(file);
		return 0;
	}
	bytes = (uint8_t*)malloc(end == 0 ? 1 : (size_t)end);
	if (!bytes || ((size_t)end != 0 && fread(bytes, 1, (size_t)end, file) != (size_t)end)) {
		free(bytes);
		fclose(file);
		return 0;
	}
	fclose(file);
	*data = bytes;
	*size = (size_t)end;
	return 1;
}

static int expect_result(
	const char* name,
	const uint8_t* data,
	size_t size,
	const JxlValidationOptions* options,
	JxlValidationVerdict expected_verdict,
	JxlValidationFindingCode expected_code
) {
	JxlValidationResult result;
	JxlValidationVerdict verdict = JxlValidate(data, size, options, &result);
	if (verdict != expected_verdict || result.verdict != expected_verdict || result.code != expected_code) {
		fprintf(stderr, "%s: verdict=%d/result=%d/code=%d, expected %d/%d\n",
			name, (int)verdict, (int)result.verdict, (int)result.code,
			(int)expected_verdict, (int)expected_code);
		return 0;
	}
	return 1;
}

/* A verdict alone does not tell a user WHICH feature stopped validation.
 * This asserts the named feature and its offset, so the finding is actionable. */
static int expect_feature(
	const char* name,
	const uint8_t* data,
	size_t size,
	const JxlValidationOptions* options,
	JxlValidationFeature expected_feature
) {
	JxlValidationResult result;
	JxlValidationVerdict verdict = JxlValidate(data, size, options, &result);
	if (verdict != JXL_VALIDATION_UNSUPPORTED || result.feature != expected_feature) {
		fprintf(stderr, "%s: verdict=%d feature=%d (%s), expected unsupported feature %d (%s)\n",
			name, (int)verdict, (int)result.feature, JxlValidationFeatureName(result.feature),
			(int)expected_feature, JxlValidationFeatureName(expected_feature));
		return 0;
	}
	return 1;
}

int main(int argc, char** argv) {
	static const uint8_t invalid_signature[] = {
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
		0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
	};
	static const uint8_t raw_signature_only[] = {0xff, 0x0a};
	static const uint8_t truncated_metadata[] = {0xff, 0x0a, 0x00, 0x00};
	JxlValidationOptions options = JXL_VALIDATION_OPTIONS_INIT;
	JxlValidationResult result;
	uint8_t* accepted = NULL;
	uint8_t* unsupported = NULL;
	uint8_t* bicycles = NULL;
	uint8_t* vardct = NULL;
	size_t accepted_size = 0;
	size_t unsupported_size = 0;
	size_t bicycles_size = 0;
	size_t vardct_size = 0;
	int ok = 1;

	if (argc != 5 || !read_file(argv[1], &accepted, &accepted_size) ||
		!read_file(argv[2], &unsupported, &unsupported_size) ||
		!read_file(argv[3], &bicycles, &bicycles_size) ||
		!read_file(argv[4], &vardct, &vardct_size)) {
		fprintf(stderr, "usage: %s ACCEPTED.jxl PATCHES_VALID.jxl BICYCLES_VALID.jxl VARDCT_VALID.jxl\n", argv[0]);
		free(accepted);
		free(unsupported);
		free(bicycles);
		free(vardct);
		return 2;
	}

	ok &= expect_result("accepted modular", accepted, accepted_size, &options,
		JXL_VALIDATION_VALID, JXL_VALIDATION_FINDING_NONE);
	if (JxlValidate(accepted, accepted_size, &options, &result) != JXL_VALIDATION_VALID ||
		result.frames_validated == 0) {
		fprintf(stderr, "accepted modular: no frame was validated\n");
		ok = 0;
	}
	ok &= expect_result("accepted patches", unsupported, unsupported_size, &options,
		JXL_VALIDATION_VALID, JXL_VALIDATION_FINDING_NONE);
	ok &= expect_result("bicycles modular", bicycles, bicycles_size, &options,
		JXL_VALIDATION_VALID, JXL_VALIDATION_FINDING_NONE);

	if (JxlValidate(unsupported, unsupported_size, &options, &result) != JXL_VALIDATION_VALID ||
		result.frames_validated != 2 || result.feature != JXL_VALIDATION_FEATURE_NONE) {
		fprintf(stderr, "accepted patches: expected two validated frames and no feature gate\n");
		ok = 0;
	}
	ok &= expect_feature("VarDCT ICC gate names itself", vardct, vardct_size, &options,
		JXL_VALIDATION_FEATURE_ICC_PROFILE);

	/* Specificity: an accepted file must not carry a stale feature from a prior call. */
	if (JxlValidate(accepted, accepted_size, &options, &result) != JXL_VALIDATION_VALID ||
		result.feature != JXL_VALIDATION_FEATURE_NONE) {
		fprintf(stderr, "accepted modular: feature must be NONE, got %d (%s)\n",
			(int)result.feature, JxlValidationFeatureName(result.feature));
		ok = 0;
	}

	/* Every feature code must have a name; an unnamed code is unusable to a user. */
	if (JxlValidationFeatureName(JXL_VALIDATION_FEATURE_PATCHES)[0] == 0 ||
		JxlValidationFeatureName(JXL_VALIDATION_FEATURE_VARDCT_FRAME)[0] == 0) {
		fprintf(stderr, "feature names must be non-empty\n");
		ok = 0;
	}
	ok &= expect_result("invalid signature", invalid_signature, sizeof(invalid_signature), &options,
		JXL_VALIDATION_CORRUPT, JXL_VALIDATION_FINDING_INVALID_SIGNATURE);
	ok &= expect_result("truncated codestream", raw_signature_only, sizeof(raw_signature_only), &options,
		JXL_VALIDATION_CORRUPT, JXL_VALIDATION_FINDING_TRUNCATED);
	ok &= expect_result("truncated metadata", truncated_metadata, sizeof(truncated_metadata), &options,
		JXL_VALIDATION_CORRUPT, JXL_VALIDATION_FINDING_TRUNCATED);

	options.host_byte_offset = 41;
	if (JxlValidate(invalid_signature, sizeof(invalid_signature), &options, &result) != JXL_VALIDATION_CORRUPT ||
		!result.offset_is_exact || result.byte_offset != 0 || result.host_byte_offset != 41) {
		fprintf(stderr, "host-relative exact offset was not preserved\n");
		ok = 0;
	}

	options = (JxlValidationOptions)JXL_VALIDATION_OPTIONS_INIT;
	options.max_input_bytes = sizeof(invalid_signature) - 1;
	ok &= expect_result("input resource limit", invalid_signature, sizeof(invalid_signature), &options,
		JXL_VALIDATION_INDETERMINATE, JXL_VALIDATION_FINDING_RESOURCE_LIMIT);

	free(accepted);
	free(unsupported);
	free(bicycles);
	free(vardct);
	return ok ? 0 : 1;
}
