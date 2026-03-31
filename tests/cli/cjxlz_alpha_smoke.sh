#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_alpha_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_alpha_run_stderr.log"
INPUT_PAM="${TMPDIR}/cjxlz_alpha_input.pam"
ENCODED_JXL="${TMPDIR}/cjxlz_alpha_output.jxl"
ROUNDTRIP_PAM="${TMPDIR}/cjxlz_alpha_roundtrip.pam"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P7\nWIDTH 2\nHEIGHT 2\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n' >"${INPUT_PAM}"
printf '\x00\x0A\x14\xFF\x1E\x28\x32\x80\x3C\x46\x50\x40\x5A\x64\x6E\x00' >>"${INPUT_PAM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" @stdin @stdout <"${INPUT_PAM}" >"${ENCODED_JXL}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_JXL}" @stdout --output_format pam >"${ROUNDTRIP_PAM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_PAM}" "${ROUNDTRIP_PAM}"; then
	echo "pam roundtrip mismatch"
	exit 1
fi
