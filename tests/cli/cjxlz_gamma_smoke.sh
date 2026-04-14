#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_gamma_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_gamma_run_stderr.log"
FAIL_STDERR="${TMPDIR}/cjxlz_gamma_fail_stderr.log"
CHECK_STDOUT="${TMPDIR}/cjxlz_gamma_check_stdout.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_gamma_check_stderr.txt"
CHECK_BIN="${TMPDIR}/cjxlz_gamma_check"
CHECK_BUILD_LOG="${TMPDIR}/cjxlz_gamma_check_build.log"
INPUT_PPM="${TMPDIR}/cjxlz_gamma_input.ppm"
ENCODED_JXL="${TMPDIR}/cjxlz_gamma_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_gamma_roundtrip.ppm"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --gamma 0.454545 "${INPUT_PPM}" "${ENCODED_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
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
	tests/cli/cjxlz_color_encoding.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${CHECK_BIN}" >"${CHECK_BUILD_LOG}" 2>&1; then
	cat "${CHECK_BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi

if ! grep -Eq '^0 1 1 65535 0\.454545 1$' "${CHECK_STDOUT}"; then
	echo "unexpected encoded color profile"
	cat "${CHECK_STDOUT}"
	exit 1
fi

if "${PACKAGE_OUT}/bin/cjxlz" --transfer-function gamma "${INPUT_PPM}" "${ENCODED_JXL}" >"${CHECK_STDOUT}" 2>"${FAIL_STDERR}"; then
	echo "gamma transfer unexpectedly succeeded without --gamma"
	exit 1
fi

if ! grep -Eq '^--transfer-function gamma requires --gamma VALUE$' "${FAIL_STDERR}"; then
	echo "unexpected missing-gamma error"
	cat "${FAIL_STDERR}"
	exit 1
fi
