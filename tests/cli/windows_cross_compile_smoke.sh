#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

TARGET="x86_64-windows-gnu"
BUILD_LOG="${TMPDIR}/libjxlz_windows_build.log"
CAPI_LOG="${TMPDIR}/libjxlz_windows_capi.log"
DJXLZ_LOG="${TMPDIR}/libjxlz_windows_djxlz.log"
CJXLZ_LOG="${TMPDIR}/libjxlz_windows_cjxlz.log"
LIB_TEST_LOG="${TMPDIR}/libjxlz_windows_lib_test.log"
ENCODE_PREP_TEST_LOG="${TMPDIR}/libjxlz_windows_encode_prep_test.log"
ENCODE_PREP_BUILD_LOG="${TMPDIR}/libjxlz_windows_encode_prep_build.log"
ENCODE_CODESTREAM_TEST_LOG="${TMPDIR}/libjxlz_windows_encode_codestream_test.log"
ENCODE_CODESTREAM_BUILD_LOG="${TMPDIR}/libjxlz_windows_encode_codestream_build.log"

if ! zig build -Dtarget="${TARGET}" -Doptimize=ReleaseFast -Dpng_input=false -Dgif_input=false -Dgif_output=false >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! zig build capi -Dtarget="${TARGET}" -Doptimize=ReleaseFast >"${CAPI_LOG}" 2>&1; then
	cat "${CAPI_LOG}"
	exit 1
fi

if ! zig build djxlz -Dtarget="${TARGET}" -Doptimize=ReleaseFast -Dgif_output=false >"${DJXLZ_LOG}" 2>&1; then
	cat "${DJXLZ_LOG}"
	exit 1
fi

if ! zig build cjxlz -Dtarget="${TARGET}" -Doptimize=ReleaseFast -Dpng_input=false -Dgif_input=false >"${CJXLZ_LOG}" 2>&1; then
	cat "${CJXLZ_LOG}"
	exit 1
fi

if ! zig test src/lib/root.zig -target "${TARGET}" -fno-emit-bin >"${LIB_TEST_LOG}" 2>&1; then
	cat "${LIB_TEST_LOG}"
	exit 1
fi

if ! zig test bench_modular_encode_prep.zig -target "${TARGET}" -fno-emit-bin >"${ENCODE_PREP_TEST_LOG}" 2>&1; then
	cat "${ENCODE_PREP_TEST_LOG}"
	exit 1
fi

if ! zig build-exe bench_modular_encode_prep.zig -O ReleaseFast -target "${TARGET}" -fno-emit-bin >"${ENCODE_PREP_BUILD_LOG}" 2>&1; then
	cat "${ENCODE_PREP_BUILD_LOG}"
	exit 1
fi

if ! zig test bench_modular_encode_codestream.zig -target "${TARGET}" -fno-emit-bin >"${ENCODE_CODESTREAM_TEST_LOG}" 2>&1; then
	cat "${ENCODE_CODESTREAM_TEST_LOG}"
	exit 1
fi

if ! zig build-exe bench_modular_encode_codestream.zig -O ReleaseFast -target "${TARGET}" -fno-emit-bin >"${ENCODE_CODESTREAM_BUILD_LOG}" 2>&1; then
	cat "${ENCODE_CODESTREAM_BUILD_LOG}"
	exit 1
fi
