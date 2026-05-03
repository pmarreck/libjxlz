#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/capi_decode_gray_icc_build.log"
RUN_STDERR="${TMPDIR}/capi_decode_gray_icc_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_decode_gray_icc"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_decode_gray_icc.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi
