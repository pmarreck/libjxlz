#!/usr/bin/env bash
# Check emitted implementation IR; native test oracles belong in separate modules.
# Bit storage, sign masking and classification are permitted.
integer_llvm_check() {
	[[ -s "${1:-}" ]] || return 2
	if grep -En ' = (fadd|fsub|fmul|fdiv|frem|fcmp|sitofp|uitofp|fptosi|fptoui|fptrunc|fpext)[[:space:]]' "$1"; then return 1; fi
	if grep -En 'call .*@llvm\.(sqrt|sin|cos|log|log2|log10|exp|exp2|pow|powi|fma|fmuladd|floor|ceil|round|roundeven|trunc|rint|nearbyint)\.' "$1"; then return 1; fi
	return 0
}
