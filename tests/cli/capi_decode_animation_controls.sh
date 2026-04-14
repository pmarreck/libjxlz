#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/capi_decode_animation_controls_build.log"
RUN_STDOUT="${TMPDIR}/capi_decode_animation_controls_stdout.txt"
RUN_STDERR="${TMPDIR}/capi_decode_animation_controls_stderr.txt"
ENC_STDOUT="${TMPDIR}/capi_decode_animation_controls_enc_stdout.txt"
ENC_STDERR="${TMPDIR}/capi_decode_animation_controls_enc_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_decode_animation_controls"
GIF_BIN="${TMPDIR}/make_traffic_light_gif"
INPUT_GIF="${TMPDIR}/traffic_light_controls.gif"
OUTPUT_JXL="${TMPDIR}/traffic_light_controls.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_decode_animation_controls.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang -std=c11 -Wall -Wextra -Werror tests/cli/make_traffic_light_gif.c -o "${GIF_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${GIF_BIN}" "${INPUT_GIF}" >"${ENC_STDOUT}" 2>"${ENC_STDERR}"; then
	cat "${ENC_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/cjxlz" "${INPUT_GIF}" "${OUTPUT_JXL}" >"${ENC_STDOUT}" 2>"${ENC_STDERR}"; then
	cat "${ENC_STDERR}"
	exit 1
fi

if ! "${CHECK_BIN}" "${OUTPUT_JXL}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! grep -Eq '^100 300 100 100 300 100$' "${RUN_STDOUT}"; then
	echo "unexpected decoder animation control behavior"
	cat "${RUN_STDOUT}"
	exit 1
fi
