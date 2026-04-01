#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
BUILD_LOG="${TMPDIR}/cjxlz_png_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_png_run_stderr.log"
INPUT_PNG="${TMPDIR}/cjxlz_input.png"
ENCODED_JXL="${TMPDIR}/cjxlz_png_output.jxl"
ROUNDTRIP_PPM="${TMPDIR}/cjxlz_png_roundtrip.ppm"
EXPECTED_PPM="${TMPDIR}/cjxlz_png_expected.ppm"

base64_decode() {
	if base64 --decode </dev/null >/dev/null 2>&1; then
		base64 --decode
	else
		base64 -D
	fi
}

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

cat <<'PNG' | base64_decode >"${INPUT_PNG}"
iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAAXNSR0IArs4c6QAAAERlWElmTU0A
KgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAAB
AAAAAgAAAADtGLyqAAAAFElEQVQIHWNk4BKRk5NjsbGxAVIACO4BjMX2jV4AAAAASUVORK5CYII=
PNG

printf 'P6\n2 2\n255\n' >"${EXPECTED_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${EXPECTED_PPM}"

if ! "${PACKAGE_OUT}/bin/cjxlz" @stdin @stdout <"${INPUT_PNG}" >"${ENCODED_JXL}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${ENCODED_JXL}" @stdout --output_format ppm >"${ROUNDTRIP_PPM}" 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${EXPECTED_PPM}" "${ROUNDTRIP_PPM}"; then
	echo "png ppm roundtrip mismatch"
	exit 1
fi
