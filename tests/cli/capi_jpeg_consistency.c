#include <jxl/decode.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int check(const char *path, int valid) {
	FILE *file = fopen(path, "rb");
	if (!file) return 1;
	if (fseek(file, 0, SEEK_END)) { fclose(file); return 1; }
	long length = ftell(file);
	if (length <= 0 || length > 1000000 || fseek(file, 0, SEEK_SET)) { fclose(file); return 1; }
	uint8_t *bytes = malloc((size_t)length), *output = malloc(65536);
	if (!bytes || !output) { free(bytes); free(output); fclose(file); return 1; }
	int failure = 1, frames = 0, reconstruction = 0;
	JxlDecoder *decoder = NULL;
	if (fread(bytes, 1, (size_t)length, file) != (size_t)length) goto done;
	decoder = JxlDecoderCreate(NULL);
	if (!decoder || JxlDecoderSubscribeEvents(decoder, JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS || JxlDecoderSetInput(decoder, bytes, (size_t)length) != JXL_DEC_SUCCESS) goto done;
	JxlDecoderCloseInput(decoder);
	for (unsigned step = 0; step < 16; ++step) {
		JxlDecoderStatus status = JxlDecoderProcessInput(decoder);
		if (status == JXL_DEC_SUCCESS) { failure = !valid || frames != 1 || reconstruction != 1; break; }
		if (status == JXL_DEC_ERROR) { failure = valid || reconstruction != 1; break; }
		if (status == JXL_DEC_FULL_IMAGE) { ++frames; continue; }
		if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
			++reconstruction;
			if (JxlDecoderSetJPEGBuffer(decoder, output, 65536) != JXL_DEC_SUCCESS) break;
			continue;
		}
		break;
	}
done:
	JxlDecoderDestroy(decoder);
	free(bytes); free(output); fclose(file);
	return failure;
}
int main(int argc, char **argv) {
	if (argc != 3) return 1;
	if (check(argv[1], 1)) { fprintf(stderr, "valid JPEG consistency control failed\n"); return 2; }
	if (check(argv[2], 0)) { fprintf(stderr, "incompatible JPEG consistency control failed\n"); return 3; }
	return 0;
}
