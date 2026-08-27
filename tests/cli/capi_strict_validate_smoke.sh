#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_OUT="${PACKAGE_OUT_OVERRIDE:-$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default")}" || exit 1
BUILD_LOG="${TMPDIR}/capi_strict_validate_build.log"
RUN_STDERR="${TMPDIR}/capi_strict_validate_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_strict_validate"

if [ ! -f "${PACKAGE_OUT}/include/jxl/validate.h" ]; then
	echo "installed package is missing include/jxl/validate.h" >&2
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-I"${PACKAGE_OUT}/include" \
	tests/cli/capi_strict_validate.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" \
	tests/corpus/labeled/good/delta_palette.jxl \
	tests/corpus/labeled/good/patches_lossless.jxl \
	tests/corpus/labeled/good/bicycles.jxl \
	tests/corpus/labeled/good/grayscale.jxl \
	>/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi
