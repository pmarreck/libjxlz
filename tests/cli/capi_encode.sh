#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
TMP_C="${TMPDIR}/libjxlz_capi_encode"
BUILD_LOG="${TMPDIR}/libjxlz_capi_encode_build.log"
COMPILE_LOG="${TMPDIR}/libjxlz_capi_encode_compile.log"
RUN_LOG="${TMPDIR}/libjxlz_capi_encode_run.log"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_encode.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${TMP_C}" >"${COMPILE_LOG}" 2>&1; then
	cat "${COMPILE_LOG}"
	exit 1
fi

if ! "${TMP_C}" >"${RUN_LOG}" 2>&1; then
	cat "${RUN_LOG}"
	exit 1
fi
