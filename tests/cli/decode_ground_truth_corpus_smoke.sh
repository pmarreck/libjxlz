#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

if bash -c '
	source ./tests/lib/decode_ground_truth_corpus.bash
	run_decode_ground_truth_manifest tests/corpus/decode_ground_truth_manifest.tsv
'; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 0 ]; then
	echo "expected checked-in ground-truth corpus compare to succeed"
	exit 1
fi
