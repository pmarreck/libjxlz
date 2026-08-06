#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

# Declared denominators live here rather than in the manifest so a silently
# truncated or partially-read manifest cannot masquerade as a full sweep.
LABELED_CORPUS_CASES=13
LABELED_CORPUS_DISCRIMINATING=4

# Negative controls over the pure classifier and manifest validators. These run
# first and cost no decode work. Without them a runner that never reports a
# deviation would still print a matrix and exit 0, so the expensive sweep below
# would be vacuous.
control_failures=0

expect_classify() {
	local want="$1" label="$2" oracle_status="$3" ours_status="$4" got
	got="$(
		source ./tests/lib/labeled_corpus_matrix.bash
		labeled_corpus_classify "${label}" "${oracle_status}" "${ours_status}"
	)"
	if [ "${got}" != "${want}" ]; then
		echo "classifier control failed: ${label}/oracle=${oracle_status}/ours=${ours_status} gave ${got}, want ${want}"
		control_failures=$((control_failures + 1))
	fi
}

expect_classify accept              good    0 0
expect_classify unsupported         good    0 1
expect_classify oracle-disagreement good    1 1
expect_classify accept              corrupt 0 0
expect_classify reject              corrupt 0 1
expect_classify reject              corrupt 1 1

expect_manifest_rejected() {
	local why="$1" row="$2" tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/labeled_manifest_control.$$.XXXXXX")"
	printf '%s\n' "${row}" > "${tmp}"
	if bash -c '
		source ./tests/lib/labeled_corpus_matrix.bash
		labeled_corpus_read_manifest "'"${tmp}"'"
	' 2>/dev/null; then
		echo "manifest control failed: ${why} was accepted"
		control_failures=$((control_failures + 1))
	fi
	rm -f "${tmp}"
}

expect_manifest_rejected "a good fixture parked on a bare reject" \
	"$(printf 'a.jxl\tgood\t-\treject')"
expect_manifest_rejected "a corrupt fixture parked in the oracle-justified unsupported bucket" \
	"$(printf 'b.jxl\tcorrupt\ta.jxl\tunsupported')"
expect_manifest_rejected "an unknown label" \
	"$(printf 'c.jxl\tmaybe\t-\taccept')"
expect_manifest_rejected "an unknown expected verdict" \
	"$(printf 'd.jxl\tgood\t-\tprobably')"
expect_manifest_rejected "a short row" \
	"$(printf 'e.jxl\tgood\t-')"

if [ "${control_failures}" -ne 0 ]; then
	echo "labeled corpus gate controls failed; the sweep below would be vacuous"
	exit 1
fi

if bash -c '
	source ./tests/lib/labeled_corpus_matrix.bash
	run_labeled_corpus_matrix \
		tests/corpus/labeled_verdict_manifest.tsv \
		'"${LABELED_CORPUS_CASES}"' \
		'"${LABELED_CORPUS_DISCRIMINATING}"'
'; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 0 ]; then
	echo "expected the labeled valid/corrupt corpus matrix to match its recorded verdicts"
	exit 1
fi
