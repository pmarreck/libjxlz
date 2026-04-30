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

resolve_cross_brotli_paths() {
	local system expr_prefix expr
	if [ -n "${BROTLI_INCLUDE_DIR:-}" ] && [ -n "${BROTLI_LIB_DIR:-}" ]; then
		return 0
	fi

	system="$(nix eval --impure --raw --expr builtins.currentSystem)"
	if [ "${system}" != "x86_64-linux" ]; then
		return 2
	fi

	expr_prefix='let flake = builtins.getFlake (toString ./.); pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; }; in '
	expr="${expr_prefix}pkgs.lib.getDev pkgs.pkgsCross.mingwW64.brotli"
	if ! BROTLI_INCLUDE_DIR="$(nix build --impure --no-link --print-out-paths --expr "${expr}" 2>"${BUILD_LOG}")/include"; then
		cat "${BUILD_LOG}"
		return 1
	fi
	expr="${expr_prefix}pkgs.lib.getLib pkgs.pkgsCross.mingwW64.brotli"
	if ! BROTLI_LIB_DIR="$(nix build --impure --no-link --print-out-paths --expr "${expr}" 2>"${BUILD_LOG}")/lib"; then
		cat "${BUILD_LOG}"
		return 1
	fi

	export BROTLI_INCLUDE_DIR
	export BROTLI_LIB_DIR
}

resolve_cross_brotli_paths
status=$?
if [ "${status}" -eq 2 ]; then
	exit 0
fi
if [ "${status}" -ne 0 ]; then
	exit 1
fi

export CPATH="${BROTLI_INCLUDE_DIR}${CPATH:+:$CPATH}"
export LIBRARY_PATH="${BROTLI_LIB_DIR}${LIBRARY_PATH:+:$LIBRARY_PATH}"

BROTLI_ZIG_FLAGS=(
	-I "${BROTLI_INCLUDE_DIR}"
	-L "${BROTLI_LIB_DIR}"
	-lbrotlienc
	-lbrotlidec
	-lbrotlicommon
)

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

if ! zig test src/lib/root.zig -target "${TARGET}" -fno-emit-bin "${BROTLI_ZIG_FLAGS[@]}" >"${LIB_TEST_LOG}" 2>&1; then
	cat "${LIB_TEST_LOG}"
	exit 1
fi

if ! zig test bench_modular_encode_prep.zig -target "${TARGET}" -fno-emit-bin "${BROTLI_ZIG_FLAGS[@]}" >"${ENCODE_PREP_TEST_LOG}" 2>&1; then
	cat "${ENCODE_PREP_TEST_LOG}"
	exit 1
fi

if ! zig build-exe bench_modular_encode_prep.zig -O ReleaseFast -target "${TARGET}" -fno-emit-bin "${BROTLI_ZIG_FLAGS[@]}" >"${ENCODE_PREP_BUILD_LOG}" 2>&1; then
	cat "${ENCODE_PREP_BUILD_LOG}"
	exit 1
fi

if ! zig test bench_modular_encode_codestream.zig -target "${TARGET}" -fno-emit-bin "${BROTLI_ZIG_FLAGS[@]}" >"${ENCODE_CODESTREAM_TEST_LOG}" 2>&1; then
	cat "${ENCODE_CODESTREAM_TEST_LOG}"
	exit 1
fi

if ! zig build-exe bench_modular_encode_codestream.zig -O ReleaseFast -target "${TARGET}" -fno-emit-bin "${BROTLI_ZIG_FLAGS[@]}" >"${ENCODE_CODESTREAM_BUILD_LOG}" 2>&1; then
	cat "${ENCODE_CODESTREAM_BUILD_LOG}"
	exit 1
fi
