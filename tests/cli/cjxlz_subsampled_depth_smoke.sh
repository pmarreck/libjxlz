#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_subsampled_depth_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_subsampled_depth_run_stderr.log"
CHECK_STDOUT="${TMPDIR}/cjxlz_subsampled_depth_check_stdout.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_subsampled_depth_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_subsampled_depth_info"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_subsampled_depth_check_build.log"
INPUT_PPM="${TMPDIR}/cjxlz_subsampled_depth_input.ppm"
DEPTH_PGM="${TMPDIR}/cjxlz_subsampled_depth_plane.pgm"
ENCODED_JXL="${TMPDIR}/cjxlz_subsampled_depth_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_subsampled_depth_roundtrip.ppm"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n4 2\n255\n' >"${INPUT_PPM}"
printf '\x04\x08\x0C\x06\x0A\x0E\x08\x0C\x10\x0A\x0E\x12\x03\x06\x09\x05\x08\x0B\x07\x0A\x0D\x09\x0C\x0F' >>"${INPUT_PPM}"
printf 'P5\n2 1\n255\n' >"${DEPTH_PGM}"
printf '\x64\x19' >>"${DEPTH_PGM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --extra depth:1 "${DEPTH_PGM}" "${INPUT_PPM}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${RUN_STDERR}"; then
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
	tests/cli/cjxlz_extra_channel_info.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${CHECK_BIN}" >"${CHECK_BUILD_LOG}" 2>&1; then
	cat "${CHECK_BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! grep -Eq '^4 2 3 1 0 1 1 0$' "${CHECK_STDOUT}"; then
	echo "unexpected decoded extra-channel info"
	cat "${CHECK_STDOUT}"
	exit 1
fi
