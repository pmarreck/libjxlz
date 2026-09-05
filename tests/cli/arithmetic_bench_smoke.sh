#!/usr/bin/env bash
set -u
scratch="$(mktemp -d "${TMPDIR}/libjxlz-arithmetic-smoke.XXXXXX")" || exit 1
bench="${ARITHMETIC_BENCH:-}"
if [ -z "$bench" ]; then
	if ! package="$(nix build --no-link --print-out-paths .#default 2> "$scratch/build")"; then
		cat "$scratch/build" >&2
		exit 1
	fi
	bench="$package/bin/bench_fixed_arithmetic"
fi
# Shared redirected stdout must append each process's records, even on Zig 0.16.
{
	for numeric in Fixed f32 f64; do
		"$bench" "$numeric" 16 1 || exit 1
	done
} > "$scratch/output" 2> "$scratch/error"
if [ "$?" -ne 0 ] || [ -s "$scratch/error" ]; then cat "$scratch/error" >&2; exit 1; fi
if ! awk '
{
	if ($0 !~ /"count":16,"repeat":1/) exit 1
	if ($0 ~ /"type":"Fixed"/) fixed++
	if ($0 ~ /"type":"f32"/) f32++
	if ($0 ~ /"type":"f64"/) f64++
	if ($0 ~ /"operation":"add"/) add++
	if ($0 ~ /"operation":"multiply"/) multiply++
	if ($0 ~ /"operation":"divide"/) divide++
	if ($0 ~ /"operation":"stencil"/) stencil++
}
END { exit !(NR == 12 && fixed == 4 && f32 == 4 && f64 == 4 && add == 3 && multiply == 3 && divide == 3 && stencil == 3) }
' "$scratch/output"; then
	printf 'Arithmetic benchmark output lost or misclassified records\n' >&2
	cat "$scratch/output" >&2
	exit 1
fi
"$bench" --vardct-fixture > "$scratch/fixture" || exit 1
if [ "$(sha256sum "$scratch/fixture" | cut -d ' ' -f 1)" != 2273fa147066a016cbbeb0847acaad941396f860c7c9c41fb7022b1e3b06cf49 ]; then
	printf 'VarDCT benchmark fixture differs from the upstream control\n' >&2
	exit 1
fi
