#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/djxlz_build.log"
RUN_STDOUT="${TMPDIR}/djxlz_stdout.bin"
RUN_STDERR="${TMPDIR}/djxlz_stderr.log"
ABOUT_STDOUT="${TMPDIR}/djxlz_about_stdout.txt"
ABOUT_STDERR="${TMPDIR}/djxlz_about_stderr.txt"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" --about >"${ABOUT_STDOUT}" 2>"${ABOUT_STDERR}"; then
	cat "${ABOUT_STDERR}"
	exit 1
fi

if ! grep -Eq '^djxlz [0-9]+ (macos|linux|windows) (aarch64|x86_64)$' "${ABOUT_STDOUT}"; then
	echo "unexpected --about output"
	cat "${ABOUT_STDOUT}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" src/lib/testdata/lossless_4x4.jxl - --output_format ppm >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

EXPECTED_HEADER="${TMPDIR}/djxlz_expected_header.txt"
printf 'P6\n4 4\n255\n' >"${EXPECTED_HEADER}"

ACTUAL_HEADER="${TMPDIR}/djxlz_actual_header.txt"
dd if="${RUN_STDOUT}" of="${ACTUAL_HEADER}" bs=1 count=11 2>/dev/null

if ! cmp -s "${EXPECTED_HEADER}" "${ACTUAL_HEADER}"; then
	echo "unexpected ppm header"
	exit 1
fi

PIXELS="${TMPDIR}/djxlz_pixels.bin"
dd if="${RUN_STDOUT}" of="${PIXELS}" bs=1 skip=11 2>/dev/null

FIRST_PIXEL="$(od -An -t u1 -N 3 "${PIXELS}" | awk '{$1=$1; print}')"
LAST_PIXEL="$(od -An -t u1 -j 45 -N 3 "${PIXELS}" | awk '{$1=$1; print}')"

if [ "${FIRST_PIXEL}" != "0 0 128" ]; then
	echo "unexpected first pixel:${FIRST_PIXEL}"
	exit 1
fi

if [ "${LAST_PIXEL}" != "255 255 128" ]; then
	echo "unexpected last pixel:${LAST_PIXEL}"
	exit 1
fi
