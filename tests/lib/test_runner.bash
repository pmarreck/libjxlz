#!/usr/bin/env bash

# Runs a directory of shell smokes with explicit per-test progress lines.
# This keeps the top-level runner observable while preserving each smoke's stderr.
run_shell_test_dir() {
	local suite_name="$1"
	local nix_bin="$2"
	local test_dir="$3"
	local failures=0
	local index=0
	local -a tests=()

	shopt -s nullglob
	tests=("${test_dir}"/*.sh)
	shopt -u nullglob

	echo "=== ${suite_name} (${#tests[@]}) ==="
	for t in "${tests[@]}"; do
		index=$((index + 1))
		printf '[%d/%d] %s\n' "${index}" "${#tests[@]}" "${t}"
		if ! "${nix_bin}" develop -c bash "${t}"; then
			failures=$((failures + 1))
		fi
	done

	return "${failures}"
}
