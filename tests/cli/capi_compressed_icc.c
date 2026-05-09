// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jxl/compressed_icc.h>

static const uint8_t kSyntheticRgbIcc[128] = {
	0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'm', 'n', 't', 'r',
	'R', 'G', 'B', ' ', 'X', 'Y', 'Z', ' ',
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 'a', 'c', 's', 'p',
};

typedef struct {
	size_t alloc_calls;
	size_t free_calls;
} MemoryStats;

static void* tracked_alloc(void* opaque, size_t size) {
	MemoryStats* stats = (MemoryStats*)opaque;
	stats->alloc_calls += 1;
	return malloc(size == 0 ? 1 : size);
}

static void tracked_free(void* opaque, void* address) {
	MemoryStats* stats = (MemoryStats*)opaque;
	stats->free_calls += 1;
	free(address);
}

int main(void) {
	MemoryStats stats = {0, 0};
	JxlMemoryManager mm = {
		.opaque = &stats,
		.alloc = tracked_alloc,
		.free = tracked_free,
	};
	uint8_t* compressed = NULL;
	size_t compressed_size = 123;
	uint8_t* decoded = NULL;
	size_t decoded_size = 456;

	if (!JxlICCProfileEncode(&mm, kSyntheticRgbIcc, sizeof(kSyntheticRgbIcc), &compressed, &compressed_size)) {
		fprintf(stderr, "compress icc failed\n");
		return 1;
	}
	if (compressed == NULL || compressed_size == 0) {
		fprintf(stderr, "compress icc returned empty buffer\n");
		return 1;
	}
	if (stats.alloc_calls != 1 || stats.free_calls != 0) {
		fprintf(stderr, "unexpected alloc/free counts after encode: %zu/%zu\n", stats.alloc_calls, stats.free_calls);
		return 1;
	}

	if (!JxlICCProfileDecode(&mm, compressed, compressed_size, &decoded, &decoded_size)) {
		fprintf(stderr, "decompress icc failed\n");
		mm.free(mm.opaque, compressed);
		return 1;
	}
	if (decoded == NULL || decoded_size != sizeof(kSyntheticRgbIcc)) {
		fprintf(stderr, "unexpected decoded size %zu\n", decoded_size);
		mm.free(mm.opaque, compressed);
		return 1;
	}
	if (memcmp(decoded, kSyntheticRgbIcc, sizeof(kSyntheticRgbIcc)) != 0) {
		fprintf(stderr, "decoded icc mismatch\n");
		mm.free(mm.opaque, decoded);
		mm.free(mm.opaque, compressed);
		return 1;
	}

	mm.free(mm.opaque, decoded);
	mm.free(mm.opaque, compressed);
	if (stats.alloc_calls != 2 || stats.free_calls != 2) {
		fprintf(stderr, "unexpected alloc/free counts after cleanup: %zu/%zu\n", stats.alloc_calls, stats.free_calls);
		return 1;
	}

	{
		JxlMemoryManager bad_mm = {
			.opaque = &stats,
			.alloc = tracked_alloc,
			.free = NULL,
		};
		uint8_t* bad_output = (uint8_t*)(uintptr_t)0x1;
		size_t bad_size = 999;
		if (JxlICCProfileEncode(&bad_mm, kSyntheticRgbIcc, sizeof(kSyntheticRgbIcc), &bad_output, &bad_size)) {
			fprintf(stderr, "invalid memory manager unexpectedly succeeded\n");
			return 1;
		}
		if (bad_output != NULL || bad_size != 0) {
			fprintf(stderr, "invalid memory manager did not zero outputs\n");
			return 1;
		}
	}

	return 0;
}
