#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_gif_icc_profile_build.log"
RUN_STDOUT="${TMPDIR}/cjxlz_gif_icc_profile_stdout.txt"
RUN_STDERR="${TMPDIR}/cjxlz_gif_icc_profile_stderr.txt"
INFO_STDOUT="${TMPDIR}/cjxlz_gif_icc_profile_info_stdout.txt"
INFO_STDERR="${TMPDIR}/cjxlz_gif_icc_profile_info_stderr.txt"
CHECK_STDERR="${TMPDIR}/cjxlz_gif_icc_profile_check_stderr.txt"
INFO_BIN="${TMPDIR}/cjxlz_gif_icc_profile_info"
CHECK_BIN="${TMPDIR}/cjxlz_gif_icc_profile_check"
GIF_BIN="${TMPDIR}/make_traffic_light_gif"
INPUT_GIF="${TMPDIR}/cjxlz_gif_icc_profile_input.gif"
INPUT_ICC="${TMPDIR}/cjxlz_gif_icc_profile_input.icc"
OUTPUT_JXL="${TMPDIR}/cjxlz_gif_icc_profile_output.jxl"
OUTPUT_ICC="${TMPDIR}/cjxlz_gif_icc_profile_output.icc"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! nix develop -c zig build-exe cjxlz_gif_info.zig -O ReleaseFast -femit-bin="${INFO_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang -std=c11 -Wall -Wextra -Werror tests/cli/make_traffic_light_gif.c -o "${GIF_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/cjxlz_icc_profile.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${CHECK_BIN}" >"${BUILD_LOG}" 2>&1; then
	cat "${BUILD_LOG}"
	exit 1
fi

if ! "${GIF_BIN}" "${INPUT_GIF}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrRGB XYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${INPUT_ICC}"
head -c 88 /dev/zero >>"${INPUT_ICC}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${INPUT_ICC}" "${INPUT_GIF}" "${OUTPUT_JXL}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
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

if ! "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output "${OUTPUT_ICC}" "${OUTPUT_JXL}" @stderr --output_format gif >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_ICC}" "${OUTPUT_ICC}"; then
	echo "gif embedded icc roundtrip mismatch"
	exit 1
fi

if ! "${CHECK_BIN}" "${OUTPUT_JXL}" "${INPUT_ICC}" >/dev/null 2>"${CHECK_STDERR}"; then
	cat "${CHECK_STDERR}"
	exit 1
fi
