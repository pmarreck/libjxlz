#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_build.log"
ABOUT_STDOUT="${TMPDIR}/cjxlz_about_stdout.txt"
ABOUT_STDERR="${TMPDIR}/cjxlz_about_stderr.txt"
RUN_STDERR="${TMPDIR}/cjxlz_run_stderr.log"
INPUT_PPM="${TMPDIR}/cjxlz_input.ppm"
ENCODED_JXL="${TMPDIR}/cjxlz_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_roundtrip.ppm"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/cjxlz" --about >"${ABOUT_STDOUT}" 2>"${ABOUT_STDERR}"; then
	cat "${ABOUT_STDERR}"
	exit 1
fi

if ! grep -Eq '^cjxlz [0-9]+ (macos|linux|windows) (aarch64|x86_64)$' "${ABOUT_STDOUT}"; then
	echo "unexpected --about output"
	cat "${ABOUT_STDOUT}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" @stdin @stdout <"${INPUT_PPM}" >"${ENCODED_JXL}" 2>"${RUN_STDERR}"; then
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
