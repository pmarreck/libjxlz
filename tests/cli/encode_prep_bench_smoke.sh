#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

source ./tests/lib/zig_runner.bash

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/libjxlz_encode_prep_bench_build.log"
LINUX_COMPILE_LOG="${TMPDIR}/libjxlz_encode_prep_bench_linux_compile.log"
RUN_LOG="${TMPDIR}/libjxlz_encode_prep_bench_run.log"
MINIMAL_RUN_LOG="${TMPDIR}/libjxlz_encode_prep_bench_minimal_run.log"
EXPECTED_CHECKSUM="503a7abf436bb4fc"
EXPECTED_MINIMAL_CHECKSUM="2c1a6fb5a404b318"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

TMP_BIN="${PACKAGE_OUT}/bin/bench_modular_encode_prep"

if ! run_project_zig build-exe bench_modular_encode_prep.zig -O ReleaseFast -target x86_64-linux -fno-emit-bin >"${LINUX_COMPILE_LOG}" 2>&1; then
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

if ! "${TMP_BIN}" \
	--bookkeeping minimal \
	--print-checksum \
	--expect-checksum "${EXPECTED_MINIMAL_CHECKSUM}" >"${MINIMAL_RUN_LOG}" 2>&1; then
	cat "${MINIMAL_RUN_LOG}"
	exit 1
fi

if ! grep -qx "${EXPECTED_MINIMAL_CHECKSUM}" "${MINIMAL_RUN_LOG}"; then
	cat "${MINIMAL_RUN_LOG}"
	exit 1
fi
