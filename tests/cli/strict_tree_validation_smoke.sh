#!/usr/bin/env bash
set -u

source ./tests/lib/strict_mutation_matrix.bash || exit 1
package_out=${PACKAGE_OUT_OVERRIDE:-}
if [ -z "$package_out" ]; then
	package_out=$(nix build --no-link --print-out-paths) || exit 1
fi
workdir=$(mktemp -d "${TMPDIR:-/tmp}/strict_tree_validation.XXXXXX") || exit 1
failures=0
while read -r source offset mask finding; do
	"$package_out/bin/jxlz" validate -- "$source" > "$workdir/base.stdout" 2> "$workdir/base.stderr"
	status=$?
	actual=$(strict_mutation_read_result < "$workdir/base.stdout")
	if [ "$status" -ne 0 ] || [ "$actual" != $'valid\tnone' ] || [ -s "$workdir/base.stderr" ]; then
		printf 'clean tree control failed: %s\n' "$source" >&2
		failures=$((failures + 1))
		continue
	fi
	cp "$source" "$workdir/mutant.jxl" || exit 1
	chmod u+w "$workdir/mutant.jxl" || exit 1
	original=$(od -An -tu1 -j "$offset" -N1 "$source" | tr -d ' ') || exit 1
	printf -v replacement '\\x%02x' "$((original ^ mask))"
	printf '%b' "$replacement" | dd of="$workdir/mutant.jxl" bs=1 seek="$offset" count=1 conv=notrunc status=none || exit 1
	"$package_out/bin/jxlz" validate -- "$workdir/mutant.jxl" > "$workdir/mutant.stdout" 2> "$workdir/mutant.stderr"
	status=$?
	actual=$(strict_mutation_read_result < "$workdir/mutant.stdout")
	if [ "$status" -ne 1 ] || [ "$actual" != $'corrupt\t'"$finding" ] || [ -s "$workdir/mutant.stderr" ]; then
		printf 'tree mutation at %s:%s: expected %s, got %s (exit %s)\n' "$source" "$offset" "$finding" "$actual" "$status" >&2
		failures=$((failures + 1))
	fi
done <<'CASES'
src/lib/testdata/lossless_4x4.jxl 15 32 invalid_ma_tree
tests/corpus/labeled/good/grayscale.jxl 265 255 invalid_context_map
CASES
exit "$failures"
