#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_BUILD_LOG="${TMPDIR}/cjxlz_xmp_package_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_xmp_run_stderr.log"
INPUT_PPM="${TMPDIR}/cjxlz_xmp_input.ppm"
XMP_FILE="${TMPDIR}/cjxlz_xmp.xml"
ENCODED_JXL="${TMPDIR}/cjxlz_xmp_output.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${PACKAGE_BUILD_LOG}")"; then
	cat "${PACKAGE_BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 1\n255\n' >"${INPUT_PPM}"
printf '\x00\x10\x20\x30\x40\x50' >>"${INPUT_PPM}"

printf '%s' '<x:xmpmeta>libjxlz cli</x:xmpmeta>' >"${XMP_FILE}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --xmp "${XMP_FILE}" "${INPUT_PPM}" "${ENCODED_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! LC_ALL=C grep -aFq 'xml ' "${ENCODED_JXL}"; then
	echo "xml box type not found"
	exit 1
fi

if ! LC_ALL=C grep -aFq '<x:xmpmeta>libjxlz cli</x:xmpmeta>' "${ENCODED_JXL}"; then
	echo "xmp payload not found"
	exit 1
fi
