#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

TMP_BIN="${TMPDIR}/libjxlz_encode_prep_bench"
BUILD_LOG="${TMPDIR}/libjxlz_encode_prep_bench_build.log"
RUN_LOG="${TMPDIR}/libjxlz_encode_prep_bench_run.log"
EXPECTED_CHECKSUM="503a7abf436bb4fc"

if ! zig build-exe bench_modular_encode_prep.zig -O ReleaseFast -femit-bin="${TMP_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
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
