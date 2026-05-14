#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_icc_profile_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_icc_profile_run_stderr.log"
CHECK_STDERR="${TMPDIR}/cjxlz_icc_profile_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_icc_profile_check"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_icc_profile_check_build.log"
INPUT_PPM="${TMPDIR}/cjxlz_icc_profile_input.ppm"
INPUT_ICC="${TMPDIR}/cjxlz_icc_profile_input.icc"
ENCODED_JXL="${TMPDIR}/cjxlz_icc_profile_output.jxl"
BLACK_PGM="${TMPDIR}/cjxlz_icc_profile_black.pgm"
CMYK_ICC="${TMPDIR}/cjxlz_icc_profile_cmyk.icc"
CMYK_JXL="${TMPDIR}/cjxlz_icc_profile_cmyk_output.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrRGB XYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${INPUT_ICC}"
head -c 88 /dev/zero >>"${INPUT_ICC}"

printf 'P5\n2 2\n255\n' >"${BLACK_PGM}"
printf '\x05\x37\x69\x9B' >>"${BLACK_PGM}"

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrCMYKXYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${CMYK_ICC}"
head -c 88 /dev/zero >>"${CMYK_ICC}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${INPUT_ICC}" "${INPUT_PPM}" "${ENCODED_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/cjxlz_icc_profile.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${CHECK_BUILD_LOG}" 2>&1; then
	cat "${CHECK_BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_JXL}" "${INPUT_ICC}" >/dev/null 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${CMYK_ICC}" --extra black "${BLACK_PGM}" "${INPUT_PPM}" "${CMYK_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${CHECK_BIN}" "${CMYK_JXL}" "${CMYK_ICC}" expect-black-extra >/dev/null 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi
