#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
#
# Labeled valid/corrupt JXL corpus runner: produces a real confusion matrix with
# denominators for libjxlz itself, rather than reusing stock-libjxl baseline
# scores measured through Validate.
#
# The central control this file exists to enforce is a specificity check. A
# classifier that rejects every input scores 100% on any corrupt corpus, so a
# corrupt-detection count alone is not evidence of strictness. Each corrupt
# fixture therefore declares the clean base fixture it was derived from, and a
# rejection only counts as *discriminating* when libjxlz accepts that base.

labeled_corpus_root_dir() {
	CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}

# Reads a manifest into the parallel arrays the matrix pass consumes. Comment and
# blank lines are skipped; every other line must carry four tab-separated fields.
labeled_corpus_read_manifest() {
	local manifest_path="$1"
	local line relpath label base expected

	LABELED_RELPATH=()
	LABELED_LABEL=()
	LABELED_BASE=()
	LABELED_EXPECTED=()

	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
			''|\#*)
				continue
				;;
		esac

		IFS=$'\t' read -r relpath label base expected <<<"${line}"

		if [ -z "${relpath}" ] || [ -z "${label}" ] || [ -z "${base}" ] || [ -z "${expected}" ]; then
			echo "malformed manifest row (need relpath, label, base, expected): ${line}" >&2
			return 1
		fi

		case "${label}" in
			good|corrupt) ;;
			*)
				echo "unknown label '${label}' for ${relpath}" >&2
				return 1
				;;
		esac

		case "${expected}" in
			accept|reject|unsupported) ;;
			*)
				echo "unknown expected verdict '${expected}' for ${relpath}" >&2
				return 1
				;;
		esac

		if [ "${label}" = "good" ] && [ "${expected}" = "reject" ]; then
			echo "a good fixture may not expect a bare 'reject'; use 'unsupported' so the pinned oracle must justify it: ${relpath}" >&2
			return 1
		fi

		if [ "${label}" = "corrupt" ] && [ "${expected}" = "unsupported" ]; then
			echo "a corrupt fixture may not be parked in the oracle-justified unsupported bucket: ${relpath}" >&2
			return 1
		fi

		LABELED_RELPATH+=("${relpath}")
		LABELED_LABEL+=("${label}")
		LABELED_BASE+=("${base}")
		LABELED_EXPECTED+=("${expected}")
	done < "${manifest_path}"
}

# Classifies one fixture from the two independent runs. `unsupported` is only
# reachable when the pinned djxl oracle accepts the stream, which is what keeps a
# genuinely invalid file from being parked there.
labeled_corpus_classify() {
	local label="$1" oracle_status="$2" ours_status="$3"

	if [ "${ours_status}" -eq 0 ]; then
		printf 'accept\n'
		return 0
	fi

	if [ "${label}" = "good" ] && [ "${oracle_status}" -eq 0 ]; then
		printf 'unsupported\n'
		return 0
	fi

	if [ "${label}" = "good" ]; then
		printf 'oracle-disagreement\n'
		return 0
	fi

	printf 'reject\n'
}

# Sweeps the labeled corpus, prints the confusion matrix with denominators, and
# fails on any per-fixture deviation, any case-count drift, or any change in the
# discriminating-detection count.
run_labeled_corpus_matrix() {
	local manifest_path="$1"
	local expected_total="$2"
	local expected_discriminating="$3"

	local root_dir workdir build_log system package_out oracle_djxl
	local index total relpath label base expected observed
	local oracle_status ours_status failures

	root_dir="$(labeled_corpus_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/labeled_corpus_matrix.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"

	source "${root_dir}/tests/lib/decode_ground_truth_corpus.bash" || return 1
	oracle_djxl="$(decode_ground_truth_oracle_djxl)" || return 1
	decode_ground_truth_check_oracle "${oracle_djxl}" || return 1

	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	if ! package_out="$(nix build --no-link --print-out-paths ".#packages.${system}.default" 2>"${build_log}")"; then
		cat "${build_log}" >&2
		return 1
	fi

	labeled_corpus_read_manifest "${manifest_path}" || return 1
	total="${#LABELED_RELPATH[@]}"

	if [ "${total}" -ne "${expected_total}" ]; then
		echo "labeled corpus case count drifted: manifest has ${total}, gate declares ${expected_total}" >&2
		return 1
	fi

	local -a observed_verdict=()
	failures=0

	for ((index = 0; index < total; index++)); do
		relpath="${LABELED_RELPATH[index]}"
		label="${LABELED_LABEL[index]}"
		expected="${LABELED_EXPECTED[index]}"

		if [ ! -f "${root_dir}/${relpath}" ]; then
			echo "labeled corpus fixture missing: ${relpath}" >&2
			return 1
		fi

		if "${oracle_djxl}" "${root_dir}/${relpath}" "${workdir}/oracle.pam" \
			>/dev/null 2>"${workdir}/oracle.stderr"; then
			oracle_status=0
		else
			oracle_status=1
		fi

		if "${package_out}/bin/djxlz" "${root_dir}/${relpath}" "${workdir}/ours.pam" \
			--output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
			ours_status=0
		else
			ours_status=1
		fi

		observed="$(labeled_corpus_classify "${label}" "${oracle_status}" "${ours_status}")"
		observed_verdict+=("${observed}")

		if [ "${observed}" != "${expected}" ]; then
			echo "labeled corpus verdict deviation for ${relpath} (${label}): expected ${expected}, observed ${observed}" >&2
			failures=$((failures + 1))
		fi
	done

	local good_total=0 good_accept=0 good_unsupported=0 good_disagree=0
	local corrupt_total=0 corrupt_reject=0 corrupt_accept=0
	local discriminating=0

	for ((index = 0; index < total; index++)); do
		label="${LABELED_LABEL[index]}"
		observed="${observed_verdict[index]}"

		if [ "${label}" = "good" ]; then
			good_total=$((good_total + 1))
			case "${observed}" in
				accept) good_accept=$((good_accept + 1)) ;;
				unsupported) good_unsupported=$((good_unsupported + 1)) ;;
				*) good_disagree=$((good_disagree + 1)) ;;
			esac
			continue
		fi

		corrupt_total=$((corrupt_total + 1))
		if [ "${observed}" = "accept" ]; then
			corrupt_accept=$((corrupt_accept + 1))
			continue
		fi

		corrupt_reject=$((corrupt_reject + 1))
		base="${LABELED_BASE[index]}"
		if [ "${base}" = "-" ]; then
			continue
		fi

		local base_index
		for ((base_index = 0; base_index < total; base_index++)); do
			if [ "${LABELED_RELPATH[base_index]}" != "${base}" ]; then
				continue
			fi
			if [ "${observed_verdict[base_index]}" = "accept" ]; then
				discriminating=$((discriminating + 1))
			fi
			break
		done
	done

	printf 'labeled corpus confusion matrix (libjxlz djxlz, oracle djxl v%s)\n' \
		"$(decode_ground_truth_oracle_version)"
	printf '  labeled-good     n=%d  accepted=%d  unsupported-valid=%d  oracle-disagreement=%d\n' \
		"${good_total}" "${good_accept}" "${good_unsupported}" "${good_disagree}"
	printf '  labeled-corrupt  n=%d  rejected=%d  falsely-accepted=%d\n' \
		"${corrupt_total}" "${corrupt_reject}" "${corrupt_accept}"
	printf '  discriminating detections=%d of %d rejections (a rejection counts only when the clean base fixture is accepted)\n' \
		"${discriminating}" "${corrupt_reject}"

	if [ "${corrupt_reject}" -gt 0 ] && [ "${discriminating}" -eq 0 ]; then
		printf '  NOT YET DISCRIMINATING: every corrupt rejection above is unproven. libjxlz also rejects\n'
		printf '  the clean base fixture, so these rejections are indistinguishable from unsupported-feature\n'
		printf '  failures and are NOT evidence of corruption detection.\n'
	fi

	if [ "${discriminating}" -ne "${expected_discriminating}" ]; then
		echo "discriminating-detection count changed: expected ${expected_discriminating}, observed ${discriminating}" >&2
		failures=$((failures + 1))
	fi

	if [ "${failures}" -ne 0 ]; then
		echo "labeled corpus matrix failed with ${failures} deviation(s)" >&2
		return 1
	fi
}
