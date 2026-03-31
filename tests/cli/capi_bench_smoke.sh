#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
TMP_C="${TMPDIR}/libjxlz_capi_bench"
BUILD_LOG="${TMPDIR}/libjxlz_capi_bench_build.log"
COMPILE_LOG="${TMPDIR}/libjxlz_capi_bench_compile.log"
RUN_LOG="${TMPDIR}/libjxlz_capi_bench_run.log"
EXPECTED_CHECKSUM="061972761c7cb673"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/benchmark/decode_public_api.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${TMP_C}" >"${COMPILE_LOG}" 2>&1; then
	cat "${COMPILE_LOG}"
	exit 1
fi

if ! "${TMP_C}" \
	--print-checksum \
	--expect-checksum "${EXPECTED_CHECKSUM}" \
	src/lib/testdata/lossless_4x4.jxl >"${RUN_LOG}" 2>&1; then
	cat "${RUN_LOG}"
	exit 1
fi

if ! grep -qx "${EXPECTED_CHECKSUM}" "${RUN_LOG}"; then
	cat "${RUN_LOG}"
	exit 1
fi
