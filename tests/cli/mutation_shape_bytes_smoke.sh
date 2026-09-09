#!/usr/bin/env bash
set -u
source ./tests/lib/mutation_detection.bash || exit 1
source ./tests/lib/mutation_shape.bash || exit 1
workdir=$(mktemp -d "${TMPDIR:-/tmp}/mutation_shape_bytes.XXXXXX") || exit 1
printf '%128s' '' | tr ' ' A > "$workdir/base.jxl"
mutation_detection_emit_mutants "$workdir/base.jxl" "$workdir" > "$workdir/manifest.tsv" || exit 1
failures=0
while IFS=$'\t' read -r kind path; do
	if ! mutation_shape_matches "$kind" "$workdir/base.jxl" "$path" "$workdir"; then
		printf 'valid mutation shape rejected: %s\n' "$path" >&2
		failures=$((failures + 1))
	fi
done < "$workdir/manifest.tsv"

cp "$workdir/base.jxl" "$workdir/unchanged.flip13.jxl"
cp "$workdir/base.jxl" "$workdir/twobits.flip13.jxl"
printf B | dd of="$workdir/twobits.flip13.jxl" bs=1 seek=16 conv=notrunc status=none
cp "$workdir/base.jxl" "$workdir/wrongoffset.flip13.jxl"
printf @ | dd of="$workdir/wrongoffset.flip13.jxl" bs=1 seek=17 conv=notrunc status=none
head -c 33 "$workdir/base.jxl" > "$workdir/wronglength.truncate25.jxl"
cp "$workdir/base.shotgun23x8.jxl" "$workdir/outside.shotgun23x8.jxl"
printf B | dd of="$workdir/outside.shotgun23x8.jxl" bs=1 seek=0 conv=notrunc status=none
cp "$workdir/base.shotgun23x8.jxl" "$workdir/wrongfill.shotgun23x8.jxl"
printf B | dd of="$workdir/wrongfill.shotgun23x8.jxl" bs=1 seek=30 conv=notrunc status=none
while read -r kind name; do
	if mutation_shape_matches "$kind" "$workdir/base.jxl" "$workdir/$name" "$workdir"; then
		printf 'invalid mutation shape accepted: %s\n' "$name" >&2
		failures=$((failures + 1))
	fi
done <<'CASES'
sniper unchanged.flip13.jxl
sniper twobits.flip13.jxl
sniper wrongoffset.flip13.jxl
truncate wronglength.truncate25.jxl
shotgun outside.shotgun23x8.jxl
shotgun wrongfill.shotgun23x8.jxl
unknown base.flip13.jxl
CASES

# A broken producer must also stop the matrix before its mutant is scored.
mkdir "$workdir/onlybase" || exit 1
cp "$workdir/base.jxl" "$workdir/onlybase/base.jxl" || exit 1
if (
	source ./tests/lib/strict_mutation_matrix.bash || exit 1
	strict_mutation_row() { return 0; }
	mutation_detection_emit_mutants() { printf 'sniper\t%s/unchanged.flip13.jxl\n' "$2"; }
	run_strict_mutation_matrix "$workdir/onlybase" unused unused "$workdir"
) > "$workdir/broken-producer.stdout" 2> "$workdir/broken-producer.stderr"; then
	printf 'matrix accepted a producer that emitted unchanged bytes as a sniper mutation\n' >&2
	failures=$((failures + 1))
fi
exit "$failures"
