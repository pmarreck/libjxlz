#!/usr/bin/env bash

strict_mutation_read_result() {
	awk -F '\t' '
		NF != 2 || seen[$1]++ { bad = 1 }
		$1 == "verdict" || $1 == "finding" || $1 == "feature" {
			if ($2 !~ /^[a-z_]+$/) bad = 1
			value[$1] = $2; next
		}
		$1 == "byte_offset" || $1 == "host_byte_offset" || $1 == "frames_validated" {
			if ($2 !~ /^[0-9]+$/) bad = 1
			next
		}
		$1 == "offset_is_exact" { if ($2 != "yes" && $2 != "no") bad = 1; next }
		{ bad = 1 }
		END {
			if (bad || NR != 7) print "missing\tmissing"
			else print value["verdict"] "\t" value["finding"]
		}'
}

# Process failure cannot establish a corruption finding.
strict_mutation_classify() {
	case "$1:$2:$3:$4" in
		0:valid:none:0) printf 'valid\n' ;;
		1:corrupt:malformed:0|1:corrupt:nonzero_padding:0|1:corrupt:invalid_signature:0|1:corrupt:truncated:0) printf 'corrupt\n' ;;
		1:corrupt:invalid_context_map:0|1:corrupt:invalid_ma_tree:0) printf 'corrupt\n' ;;
		1:unsupported:unsupported_feature:0) printf 'unsupported\n' ;;
		1:indeterminate:out_of_memory:0|1:indeterminate:resource_limit:0) printf 'resource_failure\n' ;;
		1:indeterminate:unclassified_decoder_error:0) printf 'indeterminate\n' ;;
		*) printf 'operational_failure\n' ;;
	esac
}

run_strict_mutation_matrix() {
	local base_dir="$1" validator="$2" oracle="$3" workdir="$4"
	local base_path kind mutant_path
	rg --files "$base_dir" -g '*.jxl' | LC_ALL=C sort > "$workdir/bases.txt"
	printf 'case\tkind\toracle_status\tvalidator_status\tverdict\tfinding\tclass\n'
	while IFS= read -r base_path; do
		strict_mutation_row "$base_path" base "$validator" "$oracle" "$workdir" || return 1
		mutation_detection_emit_mutants "$base_path" "$workdir" > "$workdir/mutants.tsv" || return 1
		while IFS=$'\t' read -r kind mutant_path; do
			mutation_shape_matches "$kind" "$base_path" "$mutant_path" "$workdir" || {
				printf 'mutation bytes do not match the declared shape: %s\n' "$mutant_path" >&2
				return 1
			}
			strict_mutation_row "$mutant_path" "$kind" "$validator" "$oracle" "$workdir" || return 1
		done < "$workdir/mutants.tsv"
	done < "$workdir/bases.txt"
}

strict_mutation_row() {
	local path="$1" kind="$2" validator="$3" oracle="$4" workdir="$5"
	local case_id oracle_status validator_status verdict finding class stderr_present=0
	case_id=$(basename "$path") || return 1
	case "$case_id" in *$'\t'*|*$'\n'*) return 1 ;; esac
	# Retain each tool's raw status and diagnostics. A timeout is operational failure.
	timeout --kill-after=5s 30s "$oracle" "$path" "$workdir/oracle.pam" > "$workdir/$case_id.oracle.stdout" 2> "$workdir/$case_id.oracle.stderr"
	oracle_status=$?
	timeout --kill-after=5s 30s "$validator" validate -- "$path" > "$workdir/$case_id.validator.stdout" 2> "$workdir/$case_id.validator.stderr"
	validator_status=$?
	[ ! -s "$workdir/$case_id.validator.stderr" ] || stderr_present=1
	IFS=$'\t' read -r verdict finding < <(strict_mutation_read_result < "$workdir/$case_id.validator.stdout") || return 1
	class=$(strict_mutation_classify "$validator_status" "$verdict" "$finding" "$stderr_present") || return 1
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$case_id" "$kind" "$oracle_status" "$validator_status" "$verdict" "$finding" "$class"
}
