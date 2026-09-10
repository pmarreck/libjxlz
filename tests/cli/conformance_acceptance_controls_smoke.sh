#!/usr/bin/env bash
set -u

source tests/lib/strict_mutation_matrix.bash || exit 1
source tests/lib/conformance_acceptance.bash || exit 1
workdir=$(mktemp -d "${TMPDIR:-/tmp}/conformance-controls.XXXXXX") || exit 1
mkdir -p "$workdir/corpus/a" "$workdir/corpus/b" || exit 1
printf 'a\nb\n' > "$workdir/corpus/main_level5.txt"
printf 'b\n' > "$workdir/corpus/main_level10.txt"
printf 'same input\n' > "$workdir/corpus/a/input.jxl"
cp "$workdir/corpus/a/input.jxl" "$workdir/corpus/b/input.jxl" || exit 1
{
	printf '#!%s\n' "$BASH"
	cat <<'VALIDATOR'
printf '%s\n' "${!#}" >> "$CONFORMANCE_FAKE_LOG"
verdict=valid finding=none status=0
case "$CONFORMANCE_FAKE_MODE" in
	correct) case "${!#}" in */invalid-signature.jxl) verdict=corrupt finding=invalid_signature status=1 ;; esac ;;
	accept_all) ;;
	reject_all) verdict=corrupt finding=malformed status=1 ;;
	unsupported) verdict=unsupported finding=unsupported_feature status=1 ;;
	indeterminate) verdict=indeterminate finding=unclassified_decoder_error status=1 ;;
	resource) verdict=indeterminate finding=out_of_memory status=1 ;;
	wrong_status) status=1 ;;
	stderr) printf 'unexpected diagnostic\n' >&2 ;;
	malformed) printf 'valid\n'; exit 0 ;;
	crash) exit 139 ;;
esac
printf 'verdict\t%s\nfinding\t%s\nfeature\tnone\nbyte_offset\t0\nhost_byte_offset\t0\noffset_is_exact\tno\nframes_validated\t1\n' "$verdict" "$finding"
exit "$status"
VALIDATOR
} > "$workdir/validator"
chmod +x "$workdir/validator" || exit 1
failures=0
export CONFORMANCE_FAKE_LOG="$workdir/calls.txt"
export CONFORMANCE_FAKE_MODE=correct
if ! run_conformance_acceptance "$workdir/corpus" "$workdir/validator" "$workdir/correct" 2 1 > "$workdir/correct.stdout" 2> "$workdir/correct.stderr"; then
	printf 'conformance gate rejected correct validator\n' >&2
	failures=$((failures + 1))
fi
calls=0
[ ! -f "$CONFORMANCE_FAKE_LOG" ] || calls=$(wc -l < "$CONFORMANCE_FAKE_LOG")
if [ "$calls" -ne 2 ]; then
	printf 'expected one distinct input and one invalid control, found %s calls\n' "$calls" >&2
	failures=$((failures + 1))
fi
for mode in accept_all reject_all unsupported indeterminate resource wrong_status stderr malformed crash; do
	export CONFORMANCE_FAKE_MODE="$mode"
	if run_conformance_acceptance "$workdir/corpus" "$workdir/validator" "$workdir/$mode" 2 1 > "$workdir/$mode.stdout" 2> "$workdir/$mode.stderr"; then
		printf 'conformance gate accepted broken validator: %s\n' "$mode" >&2
		failures=$((failures + 1))
	fi
done
export CONFORMANCE_FAKE_MODE=correct
for counts in '3 1' '2 2'; do
	read -r expected_cases expected_inputs <<< "$counts"
	if run_conformance_acceptance "$workdir/corpus" "$workdir/validator" "$workdir/counts-$expected_cases-$expected_inputs" "$expected_cases" "$expected_inputs" > "$workdir/counts.stdout" 2> "$workdir/counts.stderr"; then
		printf 'conformance gate accepted incorrect corpus counts\n' >&2
		failures=$((failures + 1))
	fi
done
mv "$workdir/corpus/b/input.jxl" "$workdir/corpus/b/saved-input.jxl" || exit 1
if run_conformance_acceptance "$workdir/corpus" "$workdir/validator" "$workdir/missing" 2 1 > "$workdir/missing.stdout" 2> "$workdir/missing.stderr"; then
	printf 'conformance gate ignored missing named input\n' >&2
	failures=$((failures + 1))
fi
exit "$failures"
