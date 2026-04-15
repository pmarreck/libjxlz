#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_alpha_extra_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_alpha_extra_run_stderr.log"
CHECK_STDOUT="${TMPDIR}/cjxlz_alpha_extra_check_stdout.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_alpha_extra_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_alpha_extra_info"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_alpha_extra_check_build.log"
INPUT_PAM="${TMPDIR}/cjxlz_alpha_extra_input.pam"
MASK_PGM="${TMPDIR}/cjxlz_alpha_extra_mask.pgm"
ENCODED_JXL="${TMPDIR}/cjxlz_alpha_extra_output.jxl"
ROUNDTRIP_PAM="${TMPDIR}/cjxlz_alpha_extra_roundtrip.pam"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P7\nWIDTH 2\nHEIGHT 2\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n' >"${INPUT_PAM}"
printf '\x00\x0A\x14\xFF\x1E\x28\x32\x80\x3C\x46\x50\x40\x5A\x64\x6E\x00' >>"${INPUT_PAM}"
printf 'P5\n2 2\n255\n' >"${MASK_PGM}"
printf '\x00\xFF\xFF\x00' >>"${MASK_PGM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --extra selection_mask "${MASK_PGM}" "${INPUT_PAM}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${RUN_STDERR}"; then
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

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/cjxlz_extra_info.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${CHECK_BUILD_LOG}" 2>&1; then
	cat "${CHECK_BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! grep -Eq '^2 2 3 2 8$' "${CHECK_STDOUT}"; then
	echo "unexpected decoded basic info"
	cat "${CHECK_STDOUT}"
	exit 1
fi
