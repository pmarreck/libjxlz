#!/usr/bin/env bash
set -u

TMP_C="${TMPDIR}/libjxlz_capi_decode"
BUILD_LOG="${TMPDIR}/libjxlz_capi_build.log"
COMPILE_LOG="${TMPDIR}/libjxlz_capi_compile.log"
RUN_LOG="${TMPDIR}/libjxlz_capi_run.log"

if ! zig build capi -Doptimize=ReleaseFast >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_decode.c \
	zig-out/lib/libjxlz_capi.a \
	-o "${TMP_C}" >"${COMPILE_LOG}" 2>&1; then
	cat "${COMPILE_LOG}"
	exit 1
fi

if ! "${TMP_C}" >"${RUN_LOG}" 2>&1; then
	cat "${RUN_LOG}"
	exit 1
fi
