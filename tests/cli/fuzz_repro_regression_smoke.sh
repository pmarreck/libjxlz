#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
#
# Deterministic regression gate for crash inputs previously found by ./fuzz.
#
# This is NOT a fuzz run -- the canonical brief keeps fuzzing out of ./test.
# It replays vendored, minimized mutants and asserts the decoder *rejects* them
# cleanly instead of aborting, hanging, or dying on a signal. Accepting is also
# a failure here: each vendored input is known-corrupt.

set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
REPRO_DIR="${ROOT_DIR}/tests/fuzz/repro"
SYSTEM="${SYSTEM_OVERRIDE:-$(nix eval --impure --raw --expr builtins.currentSystem)}"
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/fuzz_repro_build.XXXXXX")"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	echo "failed to build package" >&2
	cat "${BUILD_LOG}" >&2
	rm -f "${BUILD_LOG}"
	exit 1
fi
rm -f "${BUILD_LOG}"
DJXLZ="${PACKAGE_OUT}/bin/djxlz"

# The vendored set must not be silently emptied: a directory with no repros
# would otherwise pass as a full sweep.
shopt -s nullglob
repros=("${REPRO_DIR}"/*.jxl)
shopt -u nullglob
EXPECTED_REPROS=1
if [ "${#repros[@]}" -ne "${EXPECTED_REPROS}" ]; then
	echo "expected ${EXPECTED_REPROS} vendored fuzz repro(s), found ${#repros[@]}" >&2
	exit 1
fi

failures=0
for repro in "${repros[@]}"; do
	name="$(basename "${repro}")"
	out="$(mktemp "${TMPDIR:-/tmp}/fuzz_repro_out.XXXXXX")"
	timeout 30 "${DJXLZ}" "${repro}" "${out}" >/dev/null 2>&1
	status=$?
	rm -f "${out}"

	case "${status}" in
		1)
			: # cleanly rejected -- the required outcome
			;;
		0)
			echo "${name}: decoder ACCEPTED a known-corrupt repro" >&2
			failures=$((failures + 1))
			;;
		124)
			echo "${name}: decoder HUNG (timeout) -- regression of the fuzz finding" >&2
			failures=$((failures + 1))
			;;
		*)
			if [ "${status}" -gt 128 ]; then
				echo "${name}: decoder died on signal $((status - 128)) -- regression of the fuzz finding" >&2
			else
				echo "${name}: unexpected exit status ${status}" >&2
			fi
			failures=$((failures + 1))
			;;
	esac
done

if [ "${failures}" -ne 0 ]; then
	echo "expected every vendored fuzz repro to be rejected cleanly" >&2
	exit 1
fi
