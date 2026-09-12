#!/usr/bin/env bash
set -u

source ./tests/lib/strict_mutation_matrix.bash || exit 1
failures=0
while read -r status verdict finding stderr_present expected; do
	actual=$(strict_mutation_classify "$status" "$verdict" "$finding" "$stderr_present")
	if [ "$actual" != "$expected" ]; then
		printf 'strict classifier %s/%s/%s/%s: expected %s, found %s\n' "$status" "$verdict" "$finding" "$stderr_present" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
done <<'CASES'
0 valid none 0 valid
1 valid none 0 operational_failure
0 corrupt malformed 0 operational_failure
1 corrupt malformed 0 corrupt
1 corrupt nonzero_padding 0 corrupt
1 corrupt invalid_signature 0 corrupt
1 corrupt truncated 0 corrupt
1 corrupt invalid_context_map 0 corrupt
1 corrupt invalid_ma_tree 0 corrupt
0 corrupt invalid_context_map 0 operational_failure
0 corrupt invalid_ma_tree 0 operational_failure
1 indeterminate invalid_context_map 0 operational_failure
1 corrupt invalid_ma_tree 1 operational_failure
1 corrupt none 0 operational_failure
1 unsupported unsupported_feature 0 unsupported
0 unsupported unsupported_feature 0 operational_failure
1 indeterminate out_of_memory 0 resource_failure
1 indeterminate resource_limit 0 resource_failure
1 indeterminate unclassified_decoder_error 0 indeterminate
1 indeterminate invalid_argument 0 operational_failure
1 indeterminate malformed 0 operational_failure
0 indeterminate unclassified_decoder_error 0 operational_failure
0 valid none 1 operational_failure
1 corrupt malformed 1 operational_failure
1 unsupported unsupported_feature 1 operational_failure
1 indeterminate out_of_memory 1 operational_failure
2 corrupt malformed 0 operational_failure
124 corrupt malformed 0 operational_failure
139 corrupt malformed 0 operational_failure
127 valid none 0 operational_failure
0 missing missing 0 operational_failure
1 missing missing 0 operational_failure
1 corrupt unknown_finding 0 operational_failure
1 unknown malformed 0 operational_failure
CASES

# The machine-readable text response has seven distinct tab-separated fields.
response=$'verdict\tvalid\nfinding\tnone\nfeature\tnone\nbyte_offset\t0\nhost_byte_offset\t0\noffset_is_exact\tno\nframes_validated\t1'
actual=$(printf '%s\n' "$response" | strict_mutation_read_result)
[ "$actual" = $'valid\tnone' ] || failures=$((failures + 1))
for malformed in "" "$response
verdict" "$response
$response" "${response/frames_validated/not_a_field}" "${response/byte_offset$'\t'0/byte_offset$'\t'bad}"; do
	actual=$(printf '%s\n' "$malformed" | strict_mutation_read_result)
	[ "$actual" = $'missing\tmissing' ] || failures=$((failures + 1))
done
exit "$failures"
