#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default")" || exit 1
BUILD_LOG="${TMPDIR}/capi_decode_brob_box_build.log"
RUN_STDERR="${TMPDIR}/capi_decode_brob_box_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_decode_brob_box"
MAKE_BIN="${TMPDIR}/make_brob_container"
INPUT_PPM="${TMPDIR}/capi_decode_brob_box_input.ppm"
RAW_CODESTREAM="${TMPDIR}/capi_decode_brob_box_raw.jxl"
XML_FILE="${TMPDIR}/capi_decode_brob_box.xml"
COMPRESSED_FILE="${TMPDIR}/capi_decode_brob_box.xml.br"
CONTAINER_FILE="${TMPDIR}/capi_decode_brob_box_container.jxl"

printf 'P6\n2 1\n255\n\x00\x10\x20\x30\x40\x50' >"${INPUT_PPM}"
printf '%s' '<x:xmpmeta>brob decode smoke</x:xmpmeta>' >"${XML_FILE}"

if ! "${PACKAGE_OUT}/bin/cjxlz" "${INPUT_PPM}" "${RAW_CODESTREAM}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! brotli -f -q 5 -o "${COMPRESSED_FILE}" "${XML_FILE}" >"${RUN_STDERR}" 2>&1; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	tests/cli/make_brob_container.c \
	-o "${MAKE_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${MAKE_BIN}" "${CONTAINER_FILE}" "${RAW_CODESTREAM}" "xml " "${COMPRESSED_FILE}" >"${RUN_STDERR}" 2>&1; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_decode_brob_box.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" "${CONTAINER_FILE}" "${XML_FILE}" "${COMPRESSED_FILE}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi
