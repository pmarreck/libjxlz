#!/usr/bin/env bash
set -u
source ./tests/lib/integer_llvm.bash

work="$(mktemp -d "${TMPDIR:-/tmp}/integer-llvm.XXXXXX")"
errors=0
for instruction in fadd fsub fmul fdiv frem fcmp sitofp uitofp fptosi fptoui fptrunc fpext; do
	printf '  %%result = %s float %%input\n' "$instruction" > "$work/input.ll"
	if integer_llvm_check "$work/input.ll" > "$work/output" 2>&1; then
		printf 'failed to reject instruction %s\n' "$instruction"
		errors=$((errors + 1))
	fi
done
for intrinsic in sqrt sin cos log log2 log10 exp exp2 pow powi fma fmuladd floor ceil round roundeven trunc rint nearbyint; do
	printf '  %%result = tail call float @llvm.%s.f32(float %%input)\n' "$intrinsic" > "$work/input.ll"
	if integer_llvm_check "$work/input.ll" > "$work/output" 2>&1; then
		printf 'failed to reject intrinsic %s\n' "$intrinsic"
		errors=$((errors + 1))
	fi
done
for instruction in \
	'  %result = add i32 %input, 1' \
	'  %result = icmp eq i32 %input, 0' \
	'  %result = bitcast float %input to i32' \
	'  %result = call float @llvm.fabs.f32(float %input)' \
	'  %result = call i1 @llvm.is.fpclass.f32(float %input, i32 3)' \
	'  tail call void @llvm.experimental.noalias.scope.decl(metadata !1)'; do
	printf '%s\n' "$instruction" > "$work/input.ll"
	if ! integer_llvm_check "$work/input.ll" > "$work/output" 2>&1; then
		printf 'incorrectly rejected %s\n' "$instruction"
		errors=$((errors + 1))
	fi
done
for path in "$work/empty.ll" "$work/missing.ll"; do
	if [[ "$path" == "$work/empty.ll" ]]; then : > "$path"; fi
	integer_llvm_check "$path" > "$work/output" 2>&1
	if [[ $? != 2 ]]; then
		printf 'expected missing or empty IR to fail with status 2\n'
		errors=$((errors + 1))
	fi
done
exit "$errors"
