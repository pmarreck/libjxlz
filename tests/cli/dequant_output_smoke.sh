#!/usr/bin/env bash
set -u
scratch="$(mktemp -d "${TMPDIR}/libjxlz-dequant-output.XXXXXX")" || exit 1
bench="${DEQUANT_BENCH:-}"
if [ -z "$bench" ]; then
	if ! package="$(nix build --no-link --print-out-paths .#default 2> "$scratch/build")"; then
		cat "$scratch/build" >&2
		exit 1
	fi
	bench="$package/bin/bench_dequant_ensure_computed"
fi
# Separate processes must preserve records on an inherited redirected descriptor.
{
	printf 'prior benchmark record\n'
	"$bench" --print-checksum || exit 1
	"$bench" --print-checksum || exit 1
	printf 'later benchmark record\n'
} > "$scratch/output" 2> "$scratch/error"
status=$?
expected=$'prior benchmark record\n82731ce8a23584ec\n82731ce8a23584ec\nlater benchmark record'
if [ "$status" -ne 0 ] || [ -s "$scratch/error" ] || [ "$(cat "$scratch/output")" != "$expected" ]; then
	printf 'Dequant benchmark overwrote shared output records\n' >&2
	cat "$scratch/output" "$scratch/error" >&2
	exit 1
fi
