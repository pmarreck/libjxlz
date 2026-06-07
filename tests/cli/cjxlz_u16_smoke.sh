#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_u16_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_u16_run_stderr.log"
INPUT_PPM="${TMPDIR}/cjxlz_u16_input.ppm"
ENCODED_JXL="${TMPDIR}/cjxlz_u16_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_u16_roundtrip.ppm"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}" >&2
	exit 1
fi

printf 'P6\n2 1\n65535\n' >"${INPUT_PPM}"
printf '\x00\x00\x12\x34\xff\xff\x01\x00\x80\x00\xab\xcd' >>"${INPUT_PPM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" "${INPUT_PPM}" "${ENCODED_JXL}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}" >&2
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_JXL}" @stdout --output_format ppm >"${ROUNDTRIP_PPM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}" >&2
	exit 1
fi

if ! cmp -s "${INPUT_PPM}" "${ROUNDTRIP_PPM}"; then
	echo "16-bit ppm roundtrip mismatch" >&2
	cmp -l "${INPUT_PPM}" "${ROUNDTRIP_PPM}" | sed -n '1,20p' >&2
	exit 1
fi

if [ -s "${RUN_STDERR}" ]; then
	cat "${RUN_STDERR}" >&2
	exit 1
fi
