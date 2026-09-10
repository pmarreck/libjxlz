#!/usr/bin/env bash

run_conformance_acceptance() {
	local corpus="$1" validator="$2" workdir="$3" expected_cases="$4" expected_inputs="$5"
	local case_name path digest hash observation status verdict finding class
	local cases inputs=0 failures=0
	local -A observations=()
	mkdir -p "$workdir" || return 1
	cat "$corpus/main_level5.txt" "$corpus/main_level10.txt" > "$workdir/list.txt" || return 1
	LC_ALL=C sort -u "$workdir/list.txt" > "$workdir/cases.txt" || return 1
	cases=$(wc -l < "$workdir/cases.txt") || return 1
	[ "$cases" -eq "$expected_cases" ] || { printf 'unexpected conformance case count: %s\n' "$cases" >&2; return 1; }
	printf 'case\tinput_sha256\tstatus\tverdict\tfinding\tclass\n' > "$workdir/results.tsv" || return 1
	while IFS= read -r case_name; do
		[[ "$case_name" =~ ^[a-z0-9_]+$ ]] || return 1
		path="$corpus/$case_name/input.jxl"
		digest=$(sha256sum "$path") || return 1
		hash=${digest%% *}
		[[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
		if [ -z "${observations[$hash]+present}" ]; then
			observation=$(conformance_observation "$validator" "$path" "$workdir/$hash") || return 1
			observations[$hash]=$observation
			inputs=$((inputs + 1))
		fi
		observation=${observations[$hash]}
		IFS=$'\t' read -r status verdict finding class <<< "$observation"
		printf '%s\t%s\t%s\n' "$case_name" "$hash" "$observation" >> "$workdir/results.tsv" || return 1
		[ "$class" = valid ] || failures=$((failures + 1))
	done < "$workdir/cases.txt"
	[ "$inputs" -eq "$expected_inputs" ] || { printf 'unexpected distinct input count: %s\n' "$inputs" >&2; return 1; }
	# An always-accepting validator must fail this gate. Twelve zero bytes have
	# neither a raw codestream signature nor the JPEG XL container signature.
	printf '\0\0\0\0\0\0\0\0\0\0\0\0' > "$workdir/invalid-signature.jxl" || return 1
	digest=$(sha256sum "$workdir/invalid-signature.jxl") || return 1
	hash=${digest%% *}
	observation=$(conformance_observation "$validator" "$workdir/invalid-signature.jxl" "$workdir/invalid-signature") || return 1
	IFS=$'\t' read -r status verdict finding class <<< "$observation"
	printf 'invalid_signature_control\t%s\t%s\n' "$hash" "$observation" >> "$workdir/results.tsv" || return 1
	[ "$class:$finding" = corrupt:invalid_signature ] || failures=$((failures + 1))
	printf 'conformance acceptance: %s cases, %s distinct inputs, %s failed expectations\n' "$cases" "$inputs" "$failures"
	[ "$failures" -eq 0 ]
}

conformance_observation() {
	local validator="$1" input="$2" log_prefix="$3"
	local status verdict finding class stderr_present=0
	timeout --kill-after=5s 180s "$validator" validate -- "$input" > "$log_prefix.stdout" 2> "$log_prefix.stderr"
	status=$?
	[ ! -s "$log_prefix.stderr" ] || stderr_present=1
	IFS=$'\t' read -r verdict finding < <(strict_mutation_read_result < "$log_prefix.stdout") || return 1
	class=$(strict_mutation_classify "$status" "$verdict" "$finding" "$stderr_present") || return 1
	printf '%s\t%s\t%s\t%s\n' "$status" "$verdict" "$finding" "$class"
}
