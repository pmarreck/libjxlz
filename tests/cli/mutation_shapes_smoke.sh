#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

workdir="$(mktemp -d "${TMPDIR:-/tmp}/mutation_shapes.XXXXXX")" || exit 1
trap 'rm -rf "${workdir}"' EXIT

mapfile -t emitted < <(
	source ./tests/lib/mutation_detection.bash
	mutation_detection_emit_mutants tests/corpus/generated/base/01_28th_of_november.jxl "${workdir}"
)

failures=0
expect_count() {
	local kind="$1" expected="$2" observed
	observed="$(printf '%s\n' "${emitted[@]}" | awk -F '\t' -v kind="${kind}" '$1 == kind { count++ } END { print count + 0 }')"
	if [ "${observed}" -ne "${expected}" ]; then
		echo "${kind}: expected ${expected} deterministic mutants, observed ${observed}" >&2
		failures=$((failures + 1))
	fi
}

expect_count truncate 4
expect_count sniper 5
expect_count boltgun 5
expect_count shotgun 3
expect_count signature 1

if [ "${#emitted[@]}" -ne 18 ]; then
	echo "expected 18 total mutants, observed ${#emitted[@]}" >&2
	failures=$((failures + 1))
fi

exit "${failures}"
