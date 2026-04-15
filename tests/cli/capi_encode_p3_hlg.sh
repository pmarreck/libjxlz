#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/capi_encode_p3_hlg_build.log"
RUN_STDOUT="${TMPDIR}/capi_encode_p3_hlg_stdout.txt"
RUN_STDERR="${TMPDIR}/capi_encode_p3_hlg_stderr.txt"
CHECK_BIN="${TMPDIR}/capi_encode_p3_hlg"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_encode_p3_hlg.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${CHECK_BIN}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! grep -Eq '^0 1 11 18 0\.000000 1$' "${RUN_STDOUT}"; then
	echo "unexpected encoded color profile"
	cat "${RUN_STDOUT}"
	exit 1
fi
