#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

# Denominators live here, not in the corpus directory, so a partially populated
# or silently truncated corpus cannot pass as a full sweep. 15 bases x 10
# mutants (4 truncations, 5 bit flips, 1 signature corruption).
MUTATION_BASES=15
MUTATION_MUTANTS=150
MUTATION_MUST_DETECT=144
MUTATION_OVER_REJECTIONS=0

if bash -c '
	source ./tests/lib/mutation_detection.bash
	run_mutation_detection \
		tests/corpus/generated/base \
		'"${MUTATION_BASES}"' \
		'"${MUTATION_MUTANTS}"' \
		'"${MUTATION_MUST_DETECT}"' \
		'"${MUTATION_OVER_REJECTIONS}"'
'; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 0 ]; then
	echo "expected libjxlz to detect every mutation the pinned oracle rejects, with specificity intact"
	exit 1
fi
