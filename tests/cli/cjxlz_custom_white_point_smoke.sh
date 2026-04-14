#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_custom_white_point_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_custom_white_point_run_stderr.log"
CHECK_STDOUT="${TMPDIR}/cjxlz_custom_white_point_check_stdout.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_custom_white_point_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_custom_white_point_check"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_custom_white_point_check_build.log"
INPUT_PPM="${TMPDIR}/cjxlz_custom_white_point_input.ppm"
ENCODED_JXL="${TMPDIR}/cjxlz_custom_white_point_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_custom_white_point_roundtrip.ppm"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" \
	--white-point-xy 0.321,0.345 \
	"${INPUT_PPM}" "${ENCODED_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_JXL}" @stdout --output_format ppm >"${ROUNDTRIP_PPM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_PPM}" "${ROUNDTRIP_PPM}"; then
	echo "ppm roundtrip mismatch"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/cjxlz_white_point_xy.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${CHECK_BIN}" >"${CHECK_BUILD_LOG}" 2>&1; then
	cat "${CHECK_BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! grep -Eq '^2 0\.321000 0\.345000$' "${CHECK_STDOUT}"; then
	echo "unexpected custom white point"
	cat "${CHECK_STDOUT}"
	exit 1
fi
