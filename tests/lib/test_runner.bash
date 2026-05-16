#!/usr/bin/env bash

# Ensures shell smokes inherit a writable temp root even when the parent shell
# points TMPDIR at a stale session-specific path that no longer exists.
ensure_valid_tmpdir() {
	local candidate="${TMPDIR:-/tmp}"
	if [ -d "${candidate}" ]; then
		printf '%s\n' "${candidate}"
		return 0
	fi
	if mkdir -p "${candidate}" 2>/dev/null; then
		printf '%s\n' "${candidate}"
		return 0
	fi
	mktemp -d "/tmp/libjxlz-test.XXXXXX"
}

# Runs a directory of shell smokes with explicit per-test progress lines.
# This keeps the top-level runner observable while preserving each smoke's stderr.
run_shell_test_dir() {
	local suite_name="$1"
	local nix_bin="$2"
	local test_dir="$3"
	local failures=0
	local index=0
	local tmpdir
	local -a tests=()

	tmpdir="$(ensure_valid_tmpdir)" || return 1

	shopt -s nullglob
	tests=("${test_dir}"/*.sh)
	shopt -u nullglob

	echo "=== ${suite_name} (${#tests[@]}) ==="
	for t in "${tests[@]}"; do
		index=$((index + 1))
		printf '[%d/%d] %s\n' "${index}" "${#tests[@]}" "${t}"
		if ! TMPDIR="${tmpdir}" "${nix_bin}" develop -c bash "${t}"; then
			failures=$((failures + 1))
		fi
	done

	return "${failures}"
}
