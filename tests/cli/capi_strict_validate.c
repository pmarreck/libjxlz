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

int main(int argc, char** argv) {
	static const uint8_t invalid_signature[] = {
		0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
		0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
	};
	static const uint8_t raw_signature_only[] = {0xff, 0x0a};
	JxlValidationOptions options = JXL_VALIDATION_OPTIONS_INIT;
	JxlValidationResult result;
	uint8_t* accepted = NULL;
	uint8_t* unsupported = NULL;
	uint8_t* unclassified = NULL;
	size_t accepted_size = 0;
	size_t unsupported_size = 0;
	size_t unclassified_size = 0;
	int ok = 1;

	if (argc != 4 || !read_file(argv[1], &accepted, &accepted_size) ||
		!read_file(argv[2], &unsupported, &unsupported_size) ||
		!read_file(argv[3], &unclassified, &unclassified_size)) {
		fprintf(stderr, "usage: %s ACCEPTED.jxl UNSUPPORTED_VALID.jxl UNCLASSIFIED_VALID.jxl\n", argv[0]);
		free(accepted);
		free(unsupported);
		free(unclassified);
		return 2;
	}

	ok &= expect_result("accepted modular", accepted, accepted_size, &options,
		JXL_VALIDATION_VALID, JXL_VALIDATION_FINDING_NONE);
	if (JxlValidate(accepted, accepted_size, &options, &result) != JXL_VALIDATION_VALID ||
		result.frames_validated == 0) {
		fprintf(stderr, "accepted modular: no frame was validated\n");
		ok = 0;
	}
	ok &= expect_result("unsupported valid", unsupported, unsupported_size, &options,
		JXL_VALIDATION_UNSUPPORTED, JXL_VALIDATION_FINDING_UNSUPPORTED_FEATURE);
	ok &= expect_result("unclassified valid", unclassified, unclassified_size, &options,
		JXL_VALIDATION_INDETERMINATE, JXL_VALIDATION_FINDING_UNCLASSIFIED_DECODER_ERROR);
	ok &= expect_result("invalid signature", invalid_signature, sizeof(invalid_signature), &options,
		JXL_VALIDATION_CORRUPT, JXL_VALIDATION_FINDING_INVALID_SIGNATURE);
	ok &= expect_result("truncated codestream", raw_signature_only, sizeof(raw_signature_only), &options,
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
	free(unclassified);
	return ok ? 0 : 1;
}
