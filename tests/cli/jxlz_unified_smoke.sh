#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
#
# Surface gate for the unified `jxlz` subcommand CLI: dispatch, help, about,
# unknown-subcommand handling, `--` separation, and paths containing spaces.
# The per-subcommand behaviour of decode/encode is already covered by
# djxlz_smoke.sh and cjxlz_smoke.sh; this asserts the dispatcher itself.

set -u

SYSTEM="${SYSTEM_OVERRIDE:-$(nix eval --impure --raw --expr builtins.currentSystem)}"
BUILD_LOG="${TMPDIR:-/tmp}/jxlz_build.log"
OUT="${TMPDIR:-/tmp}/jxlz_stdout.txt"
ERR="${TMPDIR:-/tmp}/jxlz_stderr.txt"

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

# --about: exactly one line, name + version + platform + arch.
if ! "${JXLZ}" --about >"${OUT}" 2>"${ERR}"; then
	fail "--about exited non-zero: $(cat "${ERR}")"
fi
if [ "$(wc -l <"${OUT}")" -ne 1 ]; then
	fail "--about must be exactly one line, got $(wc -l <"${OUT}")"
fi
if ! grep -Eq '^jxlz [0-9]+ (macos|linux|windows) (aarch64|x86_64)$' "${OUT}"; then
	fail "unexpected --about output: $(cat "${OUT}")"
fi

# --help names every subcommand and exits 0.
if ! "${JXLZ}" --help >"${OUT}" 2>"${ERR}"; then
	fail "--help exited non-zero: $(cat "${ERR}")"
fi
for sub in decode encode info; do
	grep -q "  ${sub}" "${OUT}" || fail "--help does not list the '${sub}' subcommand"
done

# A bare invocation is a usage error, not a silent success.
"${JXLZ}" >"${OUT}" 2>"${ERR}"
[ $? -eq 2 ] || fail "bare invocation should exit 2"
[ -s "${ERR}" ] || fail "bare invocation should explain itself on stderr"

# Unknown subcommands must be rejected rather than treated as a path.
"${JXLZ}" definitely-not-a-subcommand >"${OUT}" 2>"${ERR}"
[ $? -eq 2 ] || fail "unknown subcommand should exit 2"
grep -q 'definitely-not-a-subcommand' "${ERR}" || fail "unknown subcommand should be named on stderr"

# Per-subcommand help works and is distinguishable from the top-level help.
if ! "${JXLZ}" decode --help >"${OUT}" 2>"${ERR}"; then
	fail "decode --help exited non-zero: $(cat "${ERR}")"
fi
grep -qi 'decode' "${OUT}" || fail "decode --help should describe decoding"

# decode dispatches to the same implementation djxlz uses.
if ! "${JXLZ}" decode src/lib/testdata/lossless_4x4.jxl - --output_format ppm >"${OUT}" 2>"${ERR}"; then
	fail "decode dispatch failed: $(cat "${ERR}")"
fi
head -c2 "${OUT}" | grep -q 'P6' || fail "decode did not emit a PPM stream"

# info reports dimensions through the C FFI.
if ! "${JXLZ}" info src/lib/testdata/lossless_4x4.jxl >"${OUT}" 2>"${ERR}"; then
	fail "info exited non-zero: $(cat "${ERR}")"
fi
grep -Eq '^dimensions[[:space:]]+4x4$' "${OUT}" || fail "info should report 4x4 dimensions, got: $(cat "${OUT}")"

# info --json emits structured output for tooling.
if ! "${JXLZ}" info --json src/lib/testdata/lossless_4x4.jxl >"${OUT}" 2>"${ERR}"; then
	fail "info --json exited non-zero: $(cat "${ERR}")"
fi
grep -q '"width": *4' "${OUT}" || fail "info --json should carry width, got: $(cat "${OUT}")"
grep -q '"height": *4' "${OUT}" || fail "info --json should carry height"

# Paths containing spaces must survive argument handling.
SPACED_DIR="${TMPDIR:-/tmp}/jxlz spaced dir"
mkdir -p "${SPACED_DIR}"
cp src/lib/testdata/lossless_4x4.jxl "${SPACED_DIR}/a file.jxl"
if ! "${JXLZ}" info "${SPACED_DIR}/a file.jxl" >"${OUT}" 2>"${ERR}"; then
	fail "info failed on a path containing spaces: $(cat "${ERR}")"
fi
grep -Eq '^dimensions[[:space:]]+4x4$' "${OUT}" || fail "spaced-path info should report 4x4"

# Everything after `--` is positional, never a subcommand or switch.
if ! "${JXLZ}" info -- "${SPACED_DIR}/a file.jxl" >"${OUT}" 2>"${ERR}"; then
	fail "info failed with a '--' separator: $(cat "${ERR}")"
fi
grep -Eq '^dimensions[[:space:]]+4x4$' "${OUT}" || fail "'--' separated path should still be read"

rm -rf "${SPACED_DIR}"

if [ "${failures}" -ne 0 ]; then
	echo "expected the unified jxlz CLI surface to hold (${failures} failure(s))" >&2
	exit 1
fi
