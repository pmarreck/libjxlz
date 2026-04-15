#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_BUILD_LOG="${TMPDIR}/cjxlz_multi_box_package_build.log"
RUN_STDERR="${TMPDIR}/cjxlz_multi_box_run_stderr.log"
INPUT_PPM="${TMPDIR}/cjxlz_multi_box_input.ppm"
XMP_FILE="${TMPDIR}/cjxlz_multi_box.xml"
EXIF_FILE="${TMPDIR}/cjxlz_multi_box.exif"
ENCODED_JXL="${TMPDIR}/cjxlz_multi_box_output.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${PACKAGE_BUILD_LOG}")"; then
	cat "${PACKAGE_BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 1\n255\n' >"${INPUT_PPM}"
printf '\x00\x10\x20\x30\x40\x50' >>"${INPUT_PPM}"

printf '%s' '<x:xmpmeta>libjxlz multi box</x:xmpmeta>' >"${XMP_FILE}"
printf '%s' 'Exif payload from cjxlz' >"${EXIF_FILE}"

if ! "${PACKAGE_OUT}/bin/cjxlz" \
	--xmp "${XMP_FILE}" \
	--box Exif "${EXIF_FILE}" \
	"${INPUT_PPM}" \
	"${ENCODED_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! LC_ALL=C grep -aFq 'xml ' "${ENCODED_JXL}"; then
	echo "xml box type not found"
	exit 1
fi

if ! LC_ALL=C grep -aFq '<x:xmpmeta>libjxlz multi box</x:xmpmeta>' "${ENCODED_JXL}"; then
	echo "xmp payload not found"
	exit 1
fi

if ! LC_ALL=C grep -aFq 'Exif' "${ENCODED_JXL}"; then
	echo "Exif box type not found"
	exit 1
fi

if ! LC_ALL=C grep -aFq 'Exif payload from cjxlz' "${ENCODED_JXL}"; then
	echo "Exif payload not found"
	exit 1
fi
