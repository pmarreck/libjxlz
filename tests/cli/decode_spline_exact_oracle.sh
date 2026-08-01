#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

source ./tests/lib/decode_ground_truth_corpus.bash

manifest="tests/corpus/decode_spline_exact_manifest.tsv"
case_count="$(decode_ground_truth_case_count "${manifest}")" || exit 1
if [ "${case_count}" -ne 1 ]; then
	echo "expected exactly one spline fixture in the exact-oracle manifest, found ${case_count}" >&2
	exit 1
fi

run_decode_ground_truth_manifest "${manifest}"
status=$?
if [ "${status}" -ne 0 ]; then
	echo "expected byte-exact spline output against the pinned djxl oracle" >&2
	exit "${status}"
fi
