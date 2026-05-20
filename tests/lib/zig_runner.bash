#!/usr/bin/env bash

# Runs project Zig commands through the flake shell unless we are already inside
# a Nix-provided Zig environment. This keeps scripts on the pinned toolchain
# without nesting `nix develop` during tests or sandboxed builds.
run_project_zig() {
	local zig_bin="${PROJECT_ZIG_BIN:-zig}"
	local nix_bin="${PROJECT_NIX_BIN:-nix}"

	if [ -n "${NIX_BUILD_TOP:-}" ] || [ -n "${IN_NIX_SHELL:-}" ]; then
		"${zig_bin}" "$@"
		return
	fi

	if command -v "${nix_bin}" >/dev/null 2>&1; then
		"${nix_bin}" develop -c "${zig_bin}" "$@"
		return
	fi

	"${zig_bin}" "$@"
}
