#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
TASK_TMP="$(mktemp -d "${TMPDIR}/capi_jpeg_output.XXXXXXXX")" || exit 1
BUILD_LOG="${TASK_TMP}/build.log"
CHECK_BIN="${TASK_TMP}/check"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}" >&2
	exit 1
fi
if ! clang -std=c11 -Wall -Wextra -Werror \
	-I"${PACKAGE_OUT}/include" \
	tests/cli/capi_jpeg_output.c "${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}" >&2
	exit 1
fi
if ! "${CHECK_BIN}" \
	testdata/jxl/jpeg_reconstruction/1x1_exif_xmp.jxl \
	testdata/jxl/jpeg_reconstruction/1x1_exif_xmp.jpg \
	>"${TASK_TMP}/stdout" 2>"${TASK_TMP}/stderr"; then
	cat "${TASK_TMP}/stderr" >&2
	exit 1
fi
if [ -s "${TASK_TMP}/stdout" ] || [ -s "${TASK_TMP}/stderr" ]; then
	cat "${TASK_TMP}/stdout" "${TASK_TMP}/stderr" >&2
	exit 1
fi
