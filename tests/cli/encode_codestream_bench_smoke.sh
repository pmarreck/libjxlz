#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/libjxlz_encode_codestream_bench_build.log"
LINUX_COMPILE_LOG="${TMPDIR}/libjxlz_encode_codestream_bench_linux_compile.log"
RUN_LOG="${TMPDIR}/libjxlz_encode_codestream_bench_run.log"
EXPECTED_CHECKSUM="d15da41c5dc623cf"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

TMP_BIN="${PACKAGE_OUT}/bin/bench_modular_encode_codestream"

if ! zig build-exe bench_modular_encode_codestream.zig -O ReleaseFast -target x86_64-linux -fno-emit-bin >"${LINUX_COMPILE_LOG}" 2>&1; then
	cat "${LINUX_COMPILE_LOG}"
	exit 1
fi

if ! "${TMP_BIN}" \
	--print-checksum \
	--expect-checksum "${EXPECTED_CHECKSUM}" >"${RUN_LOG}" 2>&1; then
	cat "${RUN_LOG}"
	exit 1
fi

if ! grep -qx "${EXPECTED_CHECKSUM}" "${RUN_LOG}"; then
	cat "${RUN_LOG}"
	exit 1
fi
