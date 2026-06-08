#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_staged_alpha_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_staged_alpha_run_stderr.log"
CHECK_STDOUT="${TMPDIR}/cjxlz_staged_alpha_check_stdout.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_staged_alpha_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_staged_alpha_info"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_staged_alpha_check_build.log"
INPUT_PPM="${TMPDIR}/cjxlz_staged_alpha_input.ppm"
ALPHA_PGM="${TMPDIR}/cjxlz_staged_alpha_alpha.pgm"
EXPECTED_PAM="${TMPDIR}/cjxlz_staged_alpha_expected.pam"
ENCODED_JXL="${TMPDIR}/cjxlz_staged_alpha_output.jxl"
ROUNDTRIP_PAM="${TMPDIR}/cjxlz_staged_alpha_roundtrip.pam"
INPUT_U16_PPM="${TMPDIR}/cjxlz_staged_alpha_u16_input.ppm"
ALPHA_U16_PGM="${TMPDIR}/cjxlz_staged_alpha_u16_alpha.pgm"
EXPECTED_U16_PAM="${TMPDIR}/cjxlz_staged_alpha_u16_expected.pam"
ENCODED_U16_JXL="${TMPDIR}/cjxlz_staged_alpha_u16_output.jxl"
ROUNDTRIP_U16_PAM="${TMPDIR}/cjxlz_staged_alpha_u16_roundtrip.pam"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"
printf 'P5\n2 2\n255\n' >"${ALPHA_PGM}"
printf '\xFF\x80\x40\x00' >>"${ALPHA_PGM}"
printf 'P7\nWIDTH 2\nHEIGHT 2\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n' >"${EXPECTED_PAM}"
printf '\x00\x0A\x14\xFF\x1E\x28\x32\x80\x3C\x46\x50\x40\x5A\x64\x6E\x00' >>"${EXPECTED_PAM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --extra alpha "${ALPHA_PGM}" "${INPUT_PPM}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_JXL}" @stdout --output_format pam >"${ROUNDTRIP_PAM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${EXPECTED_PAM}" "${ROUNDTRIP_PAM}"; then
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

if ! grep -Eq '^2 2 3 1 8$' "${CHECK_STDOUT}"; then
	echo "unexpected decoded basic info"
	cat "${CHECK_STDOUT}"
	exit 1
fi

printf 'P6\n2 1\n65535\n' >"${INPUT_U16_PPM}"
printf '\x00\x00\x12\x34\xff\xff\x01\x00\x80\x00\xab\xcd' >>"${INPUT_U16_PPM}"
printf 'P5\n2 1\n65535\n' >"${ALPHA_U16_PGM}"
printf '\x80\x00\x40\x00' >>"${ALPHA_U16_PGM}"
printf 'P7\nWIDTH 2\nHEIGHT 1\nDEPTH 4\nMAXVAL 65535\nTUPLTYPE RGB_ALPHA\nENDHDR\n' >"${EXPECTED_U16_PAM}"
printf '\x00\x00\x12\x34\xff\xff\x80\x00\x01\x00\x80\x00\xab\xcd\x40\x00' >>"${EXPECTED_U16_PAM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --extra alpha "${ALPHA_U16_PGM}" "${INPUT_U16_PPM}" "${ENCODED_U16_JXL}" >"${CHECK_STDOUT}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_U16_JXL}" @stdout --output_format pam >"${ROUNDTRIP_U16_PAM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${EXPECTED_U16_PAM}" "${ROUNDTRIP_U16_PAM}"; then
	echo "16-bit staged-alpha pam roundtrip mismatch"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_U16_JXL}" >"${CHECK_STDOUT}" 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! grep -Eq '^2 1 3 1 16$' "${CHECK_STDOUT}"; then
	echo "unexpected decoded 16-bit basic info"
	cat "${CHECK_STDOUT}"
	exit 1
fi
