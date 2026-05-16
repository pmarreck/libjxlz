#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
WORKDIR="${TMPDIR:-/tmp}/djxlz_icc_profile_contract"
mkdir -p "${WORKDIR}"
BUILD_LOG="${WORKDIR}/build.log"
RUN_STDOUT="${WORKDIR}/stdout.bin"
RUN_STDERR="${WORKDIR}/stderr.bin"
INPUT_PPM="${WORKDIR}/input.ppm"
INPUT_ICC="${WORKDIR}/input.icc"
INPUT_JXL="${WORKDIR}/input.jxl"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}"
	exit 1
fi

printf 'P6\n2 2\n255\n' >"${INPUT_PPM}"
printf '\x00\x0A\x14\x1E\x28\x32\x3C\x46\x50\x5A\x64\x6E' >>"${INPUT_PPM}"

printf '\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00mntrRGB XYZ \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00acsp' >"${INPUT_ICC}"
head -c 88 /dev/zero >>"${INPUT_ICC}"

if ! "${PACKAGE_OUT}/bin/cjxlz" --icc-profile "${INPUT_ICC}" "${INPUT_PPM}" "${INPUT_JXL}" >/dev/null 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output @stdout "${INPUT_JXL}" @stderr --output_format ppm >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	cat "${RUN_STDERR}"
	exit 1
fi

if ! cmp -s "${INPUT_ICC}" "${RUN_STDOUT}"; then
	echo "stdout icc output mismatch"
	exit 1
fi

if ! cmp -s "${INPUT_PPM}" "${RUN_STDERR}"; then
	echo "stderr image output mismatch"
	exit 1
fi

if "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	echo "missing icc output value unexpectedly succeeded"
	exit 1
fi

if ! grep -Fqx "missing value for --icc-profile-output" "${RUN_STDERR}"; then
	echo "missing value error mismatch"
	exit 1
fi

if "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output @stdout "${INPUT_JXL}" @stdout --output_format ppm >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	echo "shared stdout stream unexpectedly succeeded"
	exit 1
fi

if ! grep -Fqx "icc output cannot share the same stream as image output" "${RUN_STDERR}"; then
	echo "shared stream error mismatch"
	exit 1
fi

if "${PACKAGE_OUT}/bin/djxlz" --icc-profile-output "${WORKDIR}" "${INPUT_JXL}" "${WORKDIR}/output.ppm" --output_format ppm >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	echo "directory icc output unexpectedly succeeded"
	exit 1
fi

if ! grep -Fqx "failed to open icc output: ${WORKDIR}" "${RUN_STDERR}"; then
	echo "open icc output error mismatch"
	exit 1
fi
