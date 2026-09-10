#!/usr/bin/env bash
set -u

source ./tests/lib/strict_mutation_matrix.bash || exit 1
source ./tests/lib/mutation_detection.bash || exit 1
source ./tests/lib/mutation_shape.bash || exit 1
source ./tests/lib/decode_ground_truth_corpus.bash || exit 1

workdir=$(mktemp -d "${TMPDIR:-/tmp}/strict_mutation_matrix.XXXXXX") || exit 1
if [ -n "${PACKAGE_OUT_OVERRIDE:-}" ]; then
	package_out=$PACKAGE_OUT_OVERRIDE
else
	system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 1
	package_out=$(nix build --no-link --print-out-paths ".#packages.${system}.default" 2>"$workdir/build.log") || { cat "$workdir/build.log" >&2; exit 1; }
fi
oracle=$(decode_ground_truth_oracle_djxl) || exit 1
decode_ground_truth_check_oracle "$oracle" || exit 1

run_strict_mutation_matrix tests/corpus/generated/base "$package_out/bin/jxlz" "$oracle" "$workdir" > "$workdir/results.tsv"
matrix_status=$?
if [ "$matrix_status" -ne 0 ]; then
	printf 'strict mutation matrix failed; evidence: %s\n' "$workdir" >&2
	exit "$matrix_status"
fi
rows=$(wc -l < "$workdir/results.tsv")
[ "$rows" -eq 286 ] || { printf 'expected header + 15 bases + 270 mutants, found %s rows\n' "$rows" >&2; exit 1; }
awk -F '\t' '
	NR == 1 { next }
	$2 == "base" { bases++; if ($7 != "valid" || $3 != 0) bad++ ; next }
	{ mutants++; counts[$7]++ }
	($2 == "signature" || $2 == "truncate") && $7 != "corrupt" { bad++ }
	$7 == "operational_failure" || $7 == "resource_failure" { bad++ }
	$3 != 0 && $3 != 1 { bad++ }
	END {
		printf "strict validation matrix: %d bases, %d mutants; corrupt=%d valid=%d unsupported=%d indeterminate=%d resource=%d operational=%d\n", bases, mutants, counts["corrupt"], counts["valid"], counts["unsupported"], counts["indeterminate"], counts["resource_failure"], counts["operational_failure"]
		exit bad > 0 || bases != 15 || mutants != 270
	}' "$workdir/results.tsv" || exit 1
if [ -f tests/corpus/strict_mutation_verdicts.tsv ]; then
	cmp tests/corpus/strict_mutation_verdicts.tsv "$workdir/results.tsv" || { printf 'strict verdicts changed; review %s\n' "$workdir/results.tsv" >&2; exit 1; }
else
	printf 'strict verdict baseline missing; review %s\n' "$workdir/results.tsv" >&2
	exit 1
fi
