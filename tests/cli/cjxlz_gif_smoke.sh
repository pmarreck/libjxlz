#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default")" || exit 1
INFO_BIN="${TMPDIR}/cjxlz_gif_info"
GIF_BIN="${TMPDIR}/make_traffic_light_gif"
BUILD_LOG="${TMPDIR}/cjxlz_gif_info_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_gif_run_stderr.log"
INFO_STDOUT="${TMPDIR}/cjxlz_gif_info_stdout.txt"
INFO_STDERR="${TMPDIR}/cjxlz_gif_info_stderr.txt"
OUTPUT_JXL="${TMPDIR}/cjxlz_traffic_light.jxl"
INPUT_GIF="${TMPDIR}/traffic_light.gif"

if ! zig build-exe cjxlz_gif_info.zig -O ReleaseFast -femit-bin="${INFO_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang -std=c11 -Wall -Wextra -Werror tests/cli/make_traffic_light_gif.c -o "${GIF_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${GIF_BIN}" "${INPUT_GIF}" >"${INFO_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/cjxlz" "${INPUT_GIF}" "${OUTPUT_JXL}" >"${INFO_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${INFO_BIN}" "${OUTPUT_JXL}" >"${INFO_STDOUT}" 2>"${INFO_STDERR}"; then
	cat "${INFO_STDERR}"
	exit 1
fi

if ! grep -Eq '^100 1 0 0 4 300 100 300 100$' "${INFO_STDOUT}"; then
	echo "unexpected gif animation metadata or frame durations"
	cat "${INFO_STDOUT}"
	exit 1
fi
