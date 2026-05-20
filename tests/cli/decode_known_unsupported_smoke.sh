#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

if bash -c '
	source ./tests/lib/decode_ground_truth_corpus.bash
	run_decode_ground_truth_manifest_expect_djxlz_fail tests/corpus/decode_known_unsupported_manifest.tsv
'; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 0 ]; then
	echo "expected known-unsupported oracle manifest to characterize current failures"
	exit 1
fi
