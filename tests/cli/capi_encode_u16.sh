#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/capi_encode_u16_build.log"
COMPILE_LOG="${TMPDIR}/capi_encode_u16_compile.log"
RUN_STDERR="${TMPDIR}/capi_encode_u16_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_encode_u16"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}" >&2
	exit 1
fi

if ! nix develop -c bash -c '
	clang \
		-std=c11 \
		-Wall -Wextra -Werror \
		-Iinclude \
		-Ilib/include \
		tests/cli/capi_encode_u16.c \
		"${0}/lib/libjxlz_capi.a" \
		$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
		-o "${1}"
' "${PACKAGE_OUT}" "${CHECK_BIN}" >"${COMPILE_LOG}" 2>&1; then
	cat "${COMPILE_LOG}" >&2
	exit 1
fi

if ! "${CHECK_BIN}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}" >&2
	exit 1
fi

if [ -s "${RUN_STDERR}" ]; then
	cat "${RUN_STDERR}" >&2
	exit 1
fi
