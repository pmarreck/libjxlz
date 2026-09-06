#!/usr/bin/env bash
set -u
source ./tests/lib/zig_runner.bash
source ./tests/lib/integer_llvm.bash

work="$(mktemp -d "${TMPDIR:-/tmp}/spline-codegen.XXXXXX")"
errors=0
for target in x86_64-linux-musl aarch64-linux-musl aarch64-macos x86_64-windows-gnu aarch64-windows-gnu; do
	if ! run_project_zig build-lib src/spline_abi_probe.zig -O ReleaseFast \
		-target "$target" -static -fcompiler-rt \
		-femit-llvm-ir="$work/$target.ll" -femit-bin="$work/$target.a" > "$work/build.log" 2>&1; then
		cat "$work/build.log"
		errors=$((errors + 1))
		continue
	fi
	if ! integer_llvm_check "$work/$target.ll" > "$work/check.log" 2>&1; then
		printf 'native floating operations in spline implementation for %s\n' "$target"
		cat "$work/check.log"
		errors=$((errors + 1))
	fi
done
exit "$errors"
