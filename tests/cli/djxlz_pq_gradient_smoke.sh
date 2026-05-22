#!/usr/bin/env bash
set -u

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${system}.default")"
INPUT_JXL="testdata/jxl/pq_gradient.jxl"
EXPECTED_PGM="${TMPDIR}/djxlz_pq_gradient_expected.pgm"
ROUNDTRIP_PGM="${TMPDIR}/djxlz_pq_gradient_roundtrip.pgm"
RUN_STDERR="${TMPDIR}/djxlz_pq_gradient.stderr"

if ! djxl "${INPUT_JXL}" "${EXPECTED_PGM}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" "${INPUT_JXL}" "${ROUNDTRIP_PGM}" --output_format pgm >/dev/null 2>>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${EXPECTED_PGM}" "${ROUNDTRIP_PGM}"; then
	echo "pq_gradient decode mismatch against upstream djxl" >&2
	cmp -l "${EXPECTED_PGM}" "${ROUNDTRIP_PGM}" | sed -n '1,20p' >&2
	exit 1
fi
