#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/djxlz_icc_profile_build.log"
RUN_STDERR="${TMPDIR}/djxlz_icc_profile_run_stderr.log"
INPUT_PPM="${TMPDIR}/djxlz_icc_profile_input.ppm"
INPUT_ICC="${TMPDIR}/djxlz_icc_profile_input.icc"
INPUT_BLACK="${TMPDIR}/djxlz_icc_profile_black.pgm"
INPUT_CMYK_ICC="${TMPDIR}/djxlz_icc_profile_cmyk.icc"
RGB_JXL="${TMPDIR}/djxlz_icc_profile_rgb.jxl"
RGB_PPM="${TMPDIR}/djxlz_icc_profile_rgb.ppm"
RGB_ICC_OUT="${TMPDIR}/djxlz_icc_profile_rgb.icc"
CMYK_JXL="${TMPDIR}/djxlz_icc_profile_cmyk.jxl"
CMYK_PPM="${TMPDIR}/djxlz_icc_profile_cmyk.ppm"
CMYK_ICC_OUT="${TMPDIR}/djxlz_icc_profile_cmyk.icc"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrRGB XYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${INPUT_ICC}"
head -c 88 /dev/zero >>"${INPUT_ICC}"

printf 'P5\n2 2\n255\n' >"${INPUT_BLACK}"
printf '\x05\x37\x69\x9B' >>"${INPUT_BLACK}"

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrCMYKXYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${INPUT_CMYK_ICC}"
head -c 88 /dev/zero >>"${INPUT_CMYK_ICC}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${INPUT_ICC}" "${INPUT_PPM}" "${RGB_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output "${RGB_ICC_OUT}" "${RGB_JXL}" "${RGB_PPM}" --output_format ppm >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_PPM}" "${RGB_PPM}"; then
	echo "rgb ppm roundtrip mismatch"
	exit 1
fi

if ! cmp -s "${INPUT_ICC}" "${RGB_ICC_OUT}"; then
	echo "rgb icc roundtrip mismatch"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${INPUT_CMYK_ICC}" --extra black "${INPUT_BLACK}" "${INPUT_PPM}" "${CMYK_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output "${CMYK_ICC_OUT}" "${CMYK_JXL}" "${CMYK_PPM}" --output_format ppm >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_PPM}" "${CMYK_PPM}"; then
	echo "cmyk ppm roundtrip mismatch"
	exit 1
fi

if ! cmp -s "${INPUT_CMYK_ICC}" "${CMYK_ICC_OUT}"; then
	echo "cmyk icc roundtrip mismatch"
	exit 1
fi
