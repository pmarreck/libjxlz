#!/usr/bin/env bash
set -u

TASK_TMP="$(mktemp -d "${TMPDIR}/flake_platforms.XXXXXXXX")" || exit 1
if ! ACTUAL="$(nix eval --json --apply builtins.attrNames .#devShells 2>"${TASK_TMP}/stderr")"; then
	cat "${TASK_TMP}/stderr" >&2
	exit 1
fi
EXPECTED='["aarch64-darwin","aarch64-linux","x86_64-linux"]'
if [[ "${ACTUAL}" != "${EXPECTED}" ]]; then
	printf 'Expected flake hosts %s; got %s\n' "${EXPECTED}" "${ACTUAL}" >&2
	exit 1
fi
