#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
#
# Surface gate for `jxlz validate`: the durable replacement for the throwaway
# C probes that every coverage measurement has been rebuilt from. Asserts
# verdict/finding/feature output, JSON, stdin aliases, spaced paths, and a
# classifier over the labeled-good set so an unknown feature cannot hide.

set -u

SYSTEM="${SYSTEM_OVERRIDE:-$(nix eval --impure --raw --expr builtins.currentSystem)}"
BUILD_LOG="${TMPDIR:-/tmp}/jxlz_validate_build.log"
OUT="${TMPDIR:-/tmp}/jxlz_validate_stdout.txt"
ERR="${TMPDIR:-/tmp}/jxlz_validate_stderr.txt"

failures=0
fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${BUILD_LOG}")"; then
	cat "${BUILD_LOG}" >&2
	exit 1
fi
JXLZ="${PACKAGE_OUT}/bin/jxlz"

if [ ! -x "${JXLZ}" ]; then
	echo "expected the unified CLI at ${JXLZ}" >&2
	exit 1
fi

run_validate() {
	"${JXLZ}" validate "$@" >"${OUT}" 2>"${ERR}"
}

# --help names the subcommand; per-subcommand help describes the fields.
if ! "${JXLZ}" --help >"${OUT}" 2>"${ERR}"; then
	fail "--help exited non-zero: $(cat "${ERR}")"
fi
grep -q "  validate" "${OUT}" || fail "--help does not list the 'validate' subcommand"

if ! "${JXLZ}" validate --help >"${OUT}" 2>"${ERR}"; then
	fail "validate --help exited non-zero: $(cat "${ERR}")"
fi
grep -qi 'verdict' "${OUT}" || fail "validate --help should mention verdict"
grep -qi 'json' "${OUT}" || fail "validate --help should mention --json"

# Bare subcommand is a usage error, not a silent success.
run_validate
[ $? -eq 2 ] || fail "validate with no input should exit 2"
[ -s "${ERR}" ] || fail "validate with no input should explain itself on stderr"

# A known-valid modular file must exit 0 and name no feature.
run_validate src/lib/testdata/lossless_4x4.jxl
status=$?
[ "${status}" -eq 0 ] || fail "valid modular should exit 0, got ${status}: $(cat "${ERR}") $(cat "${OUT}")"
grep -Eq '^verdict[[:space:]]+valid$' "${OUT}" || fail "valid modular should report verdict valid, got: $(cat "${OUT}")"
grep -Eq '^feature[[:space:]]+none$' "${OUT}" || fail "valid modular should report feature none, got: $(cat "${OUT}")"
grep -Eq '^frames_validated[[:space:]]+[1-9]' "${OUT}" || fail "valid modular should validate at least one frame, got: $(cat "${OUT}")"

# Discriminating named features: a single hardcoded answer would pass one
# of these and fail the other.
run_validate tests/corpus/labeled/good/patches_lossless.jxl
status=$?
[ "${status}" -eq 1 ] || fail "patches_lossless should exit 1 (unsupported), got ${status}"
grep -Eq '^verdict[[:space:]]+unsupported$' "${OUT}" || fail "patches_lossless should report unsupported, got: $(cat "${OUT}")"
grep -Eq '^feature[[:space:]]+patches$' "${OUT}" || fail "patches_lossless should name patches, got: $(cat "${OUT}")"

run_validate tests/corpus/labeled/good/grayscale.jxl
status=$?
[ "${status}" -eq 1 ] || fail "grayscale should exit 1 (unsupported), got ${status}"
grep -Eq '^verdict[[:space:]]+unsupported$' "${OUT}" || fail "grayscale should report unsupported, got: $(cat "${OUT}")"
grep -Eq '^feature[[:space:]]+vardct_frame$' "${OUT}" || fail "grayscale should name vardct_frame, got: $(cat "${OUT}")"

# Classifier over the labeled-good set: every unsupported file must name a
# real feature, and the set of names must not collapse to one answer.
unsupported_count=0
unknown_count=0
saw_patches=0
saw_vardct=0
while IFS= read -r fixture; do
	run_validate "${fixture}"
	status=$?
	verdict="$(awk '$1=="verdict"{print $2}' "${OUT}")"
	feature="$(awk '$1=="feature"{print $2}' "${OUT}")"
	if [ "${verdict}" = "unsupported" ]; then
		unsupported_count=$((unsupported_count + 1))
		[ "${status}" -eq 1 ] || fail "${fixture}: unsupported should exit 1, got ${status}"
		if [ "${feature}" = "unknown" ] || [ -z "${feature}" ]; then
			unknown_count=$((unknown_count + 1))
			fail "${fixture}: unsupported with unnamed feature (${feature:-empty})"
		fi
		[ "${feature}" = "patches" ] && saw_patches=1
		[ "${feature}" = "vardct_frame" ] && saw_vardct=1
	elif [ "${verdict}" = "valid" ]; then
		[ "${status}" -eq 0 ] || fail "${fixture}: valid should exit 0, got ${status}"
		[ "${feature}" = "none" ] || fail "${fixture}: valid must report feature none, got ${feature}"
	fi
done < <(find tests/corpus/labeled/good -type f -name '*.jxl' | sort)

[ "${unsupported_count}" -ge 2 ] || fail "classifier saw ${unsupported_count} unsupported files; need at least 2"
[ "${unknown_count}" -eq 0 ] || fail "classifier saw ${unknown_count} unknown features; want 0"
[ "${saw_patches}" -eq 1 ] || fail "classifier never saw feature=patches over labeled-good"
[ "${saw_vardct}" -eq 1 ] || fail "classifier never saw feature=vardct_frame over labeled-good"

# --json for tooling. Later --json must still win if it follows the path.
run_validate tests/corpus/labeled/good/patches_lossless.jxl --json
[ $? -eq 1 ] || fail "json unsupported should still exit 1"
grep -q '"verdict": "unsupported"' "${OUT}" || fail "json should carry verdict, got: $(cat "${OUT}")"
grep -q '"feature": "patches"' "${OUT}" || fail "json should carry feature patches, got: $(cat "${OUT}")"

# stdin aliases and an invalid signature (corrupt, not unsupported).
invalid_sig="${TMPDIR:-/tmp}/jxlz_validate_invalid.bin"
printf '0123456789ab' > "${invalid_sig}"
run_validate - --json < "${invalid_sig}"
status=$?
[ "${status}" -eq 1 ] || fail "invalid signature on stdin should exit 1, got ${status}: $(cat "${ERR}") $(cat "${OUT}")"
grep -q '"verdict": "corrupt"' "${OUT}" || fail "invalid signature should be corrupt, got: $(cat "${OUT}")"

run_validate @stdin --json < "${invalid_sig}"
status=$?
[ "${status}" -eq 1 ] || fail "@stdin invalid signature should exit 1, got ${status}"
grep -q '"verdict": "corrupt"' "${OUT}" || fail "@stdin should be corrupt, got: $(cat "${OUT}")"

# Paths containing spaces.
SPACED_DIR="${TMPDIR:-/tmp}/jxlz validate spaced"
mkdir -p "${SPACED_DIR}"
cp src/lib/testdata/lossless_4x4.jxl "${SPACED_DIR}/a file.jxl"
run_validate "${SPACED_DIR}/a file.jxl"
status=$?
[ "${status}" -eq 0 ] || fail "validate failed on a path containing spaces: $(cat "${ERR}")"
grep -Eq '^verdict[[:space:]]+valid$' "${OUT}" || fail "spaced-path validate should be valid, got: $(cat "${OUT}")"

run_validate -- "${SPACED_DIR}/a file.jxl"
status=$?
[ "${status}" -eq 0 ] || fail "validate failed with a '--' separator: $(cat "${ERR}")"

# Restore is not rm; tests may run with rm hooked. mkdir -p workspace is TMPDIR.
# Leave the spaced dir in TMPDIR; it is RAM-backed and session-scoped.

if [ "${failures}" -ne 0 ]; then
	echo "expected jxlz validate to report verdict/finding/feature (${failures} failure(s))" >&2
	exit 1
fi
