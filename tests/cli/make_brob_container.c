// Copyright (c) Peter Marreck and libjxlz contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int read_file(const char* path, uint8_t** data, size_t* size) {
	FILE* f = fopen(path, "rb");
	size_t file_size;
	uint8_t* buf;
	if (!f) return 0;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return 0;
	}
	file_size = (size_t)ftell(f);
	if (fseek(f, 0, SEEK_SET) != 0) {
		fclose(f);
		return 0;
	}
	buf = (uint8_t*)malloc(file_size == 0 ? 1 : file_size);
	if (!buf) {
		fclose(f);
		return 0;
	}
	if (file_size != 0 && fread(buf, 1, file_size, f) != file_size) {
		free(buf);
		fclose(f);
		return 0;
	}
	fclose(f);
	*data = buf;
	*size = file_size;
	return 1;
}

static int write_u32_be(FILE* f, uint32_t value) {
	uint8_t bytes[4];
	bytes[0] = (uint8_t)(value >> 24);
	bytes[1] = (uint8_t)(value >> 16);
	bytes[2] = (uint8_t)(value >> 8);
	bytes[3] = (uint8_t)value;
	return fwrite(bytes, 1, sizeof(bytes), f) == sizeof(bytes);
}

static int write_box(FILE* f, const char type[4], const uint8_t* contents, size_t contents_size) {
	if (contents_size > 0xffffffffu - 8u) return 0;
	if (!write_u32_be(f, (uint32_t)(contents_size + 8u))) return 0;
	if (fwrite(type, 1, 4, f) != 4) return 0;
	return contents_size == 0 || fwrite(contents, 1, contents_size, f) == contents_size;
}

int main(int argc, char** argv) {
	static const uint8_t signature_box[] = {
		0x00, 0x00, 0x00, 0x0c, 'J', 'X', 'L', ' ', 0x0d, 0x0a, 0x87, 0x0a,
	};
	static const uint8_t ftyp_box[] = {
		0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p',
		'j', 'x', 'l', ' ', 0x00, 0x00, 0x00, 0x00, 'j', 'x', 'l', ' ',
	};
	uint8_t* codestream = NULL;
	uint8_t* compressed = NULL;
	uint8_t* brob_contents = NULL;
	size_t codestream_size = 0;
	size_t compressed_size = 0;
	FILE* out = NULL;
	int ok = 0;

	if (argc != 5) {
		fprintf(stderr, "usage: %s OUTPUT CODESTREAM TYPE COMPRESSED\n", argv[0]);
		return 2;
	}
	if (strlen(argv[3]) != 4) {
		fprintf(stderr, "box type must be exactly 4 bytes\n");
		return 1;
	}
	if (!read_file(argv[2], &codestream, &codestream_size)) {
		fprintf(stderr, "failed to read codestream\n");
		goto cleanup;
	}
	if (!read_file(argv[4], &compressed, &compressed_size)) {
		fprintf(stderr, "failed to read compressed payload\n");
		goto cleanup;
	}
	brob_contents = (uint8_t*)malloc(compressed_size + 4u);
	if (!brob_contents) {
		fprintf(stderr, "failed to allocate brob contents\n");
		goto cleanup;
	}
	memcpy(brob_contents, argv[3], 4);
	memcpy(brob_contents + 4, compressed, compressed_size);

	out = fopen(argv[1], "wb");
	if (!out) {
		fprintf(stderr, "failed to open output\n");
		goto cleanup;
	}
	if (fwrite(signature_box, 1, sizeof(signature_box), out) != sizeof(signature_box)) {
		fprintf(stderr, "failed to write signature box\n");
		goto cleanup;
	}
	if (fwrite(ftyp_box, 1, sizeof(ftyp_box), out) != sizeof(ftyp_box)) {
		fprintf(stderr, "failed to write ftyp box\n");
		goto cleanup;
	}
	if (!write_box(out, "brob", brob_contents, compressed_size + 4u)) {
		fprintf(stderr, "failed to write brob box\n");
		goto cleanup;
	}
	if (!write_box(out, "jxlc", codestream, codestream_size)) {
		fprintf(stderr, "failed to write jxlc box\n");
		goto cleanup;
	}
	if (fclose(out) != 0) {
		out = NULL;
		fprintf(stderr, "failed to close output\n");
		goto cleanup;
	}
	out = NULL;
	ok = 1;

cleanup:
	if (out) fclose(out);
	free(codestream);
	free(compressed);
	free(brob_contents);
	return ok ? 0 : 1;
}
