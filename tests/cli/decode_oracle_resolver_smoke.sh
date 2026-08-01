#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/decode_oracle_resolver.XXXXXX")"
FAKE_BIN="${WORKDIR}/bin"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/djxl" <<'FAKE'
#!/usr/bin/env bash
set -u
if [ "${1-}" = "--version" ]; then
	printf '%s\n' 'djxl v0.12.0 [fake]'
	exit 0
fi
exit 99
FAKE
chmod +x "${FAKE_BIN}/djxl"

cat >"${FAKE_BIN}/wrong-djxl" <<'FAKE'
#!/usr/bin/env bash
set -u
if [ "${1-}" = "--version" ]; then
	printf '%s\n' 'djxl v9.9.9 [fake]'
	exit 0
fi
exit 99
FAKE
chmod +x "${FAKE_BIN}/wrong-djxl"

if ! PATH="${FAKE_BIN}:$PATH" bash -c '
	source ./tests/lib/decode_ground_truth_corpus.bash
	oracle="$(decode_ground_truth_oracle_djxl)"
	[ "${oracle}" = "'"${FAKE_BIN}"'/djxl" ] || exit 2
	decode_ground_truth_check_oracle "${oracle}"
'; then
	echo "expected PATH djxl v0.12.0 oracle to pass"
	exit 1
fi

if PATH="${FAKE_BIN}:$PATH" JXLZ_ORACLE_DJXL="${FAKE_BIN}/wrong-djxl" bash -c '
	source ./tests/lib/decode_ground_truth_corpus.bash
	oracle="$(decode_ground_truth_oracle_djxl)"
	decode_ground_truth_check_oracle "${oracle}"
' 2>"${WORKDIR}/wrong-version.stderr"; then
	echo "expected wrong oracle version to fail"
	exit 1
fi

if ! grep -Fq 'expected djxl v0.12.0 oracle' "${WORKDIR}/wrong-version.stderr"; then
	echo "missing wrong-version diagnostic"
	cat "${WORKDIR}/wrong-version.stderr"
	exit 1
fi

if ! PATH="${FAKE_BIN}:$PATH" JXLZ_ORACLE_DJXL="${FAKE_BIN}/wrong-djxl" JXLZ_ORACLE_DJXL_VERSION="9.9.9" bash -c '
	source ./tests/lib/decode_ground_truth_corpus.bash
	oracle="$(decode_ground_truth_oracle_djxl)"
	[ "${oracle}" = "'"${FAKE_BIN}"'/wrong-djxl" ] || exit 2
	decode_ground_truth_check_oracle "${oracle}"
'; then
	echo "expected explicit oracle/version override to pass"
	exit 1
fi
