#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/capi_decode_animation_pixels_build.log"
RUN_STDOUT="${TMPDIR}/capi_decode_animation_pixels_stdout.txt"
RUN_STDERR="${TMPDIR}/capi_decode_animation_pixels_stderr.txt"
ENC_STDOUT="${TMPDIR}/capi_decode_animation_pixels_enc_stdout.txt"
ENC_STDERR="${TMPDIR}/capi_decode_animation_pixels_enc_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_decode_animation_pixels"
GIF_BIN="${TMPDIR}/make_traffic_light_gif"
INPUT_GIF="${TMPDIR}/traffic_light_pixels.gif"
OUTPUT_JXL="${TMPDIR}/traffic_light_pixels.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_decode_animation_pixels.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
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

if ! grep -Eq '^[0-9a-f]{16}( [0-9a-f]{16}){9}$' "${RUN_STDOUT}"; then
	echo "unexpected decoder animation pixel hashes"
	cat "${RUN_STDOUT}"
	exit 1
fi

# Generated independently by tests/unit/cropped_animation_oracle.cc linked to
# upstream libjxl. The probe also checks rewind/skip against these full frames.
if ! "${CHECK_BIN}" testdata/jxl/blending/cropped_traffic_light.jxl >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi
expected='9f6c7e0516cb7c89 dbb4ee2e37958d29 e3c7fa45b878c8a2 c4103485f6340d83'
actual="$(awk '{print $1, $2, $3, $4}' "${RUN_STDOUT}")"
if [ "${actual}" != "${expected}" ]; then
	echo "cropped animation frames differ from upstream: ${actual}" >&2
	exit 1
fi
