#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
#
# Mutation-detection gate over streams libjxlz actually accepts.
#
# The labeled corpus in tests/corpus/labeled/ cannot measure detection at all:
# every corrupt fixture there derives from a VarDCT image libjxlz does not
# implement, so its rejections are indistinguishable from unsupported-feature
# failures. This gate fixes that by starting from vendored lossless-modular
# bases that libjxlz decodes successfully, which establishes specificity by
# construction, and only then corrupting them.
#
# Ground truth here is definitional rather than labeled: we know exactly which
# byte was changed. The pinned djxl oracle supplies the must-detect/may-ignore
# split, because a mutation landing in entropy-coded data can still decode to a
# different but perfectly valid image. Requiring rejection there would be wrong,
# so a mutant is only must-detect when the oracle itself rejects it.

mutation_detection_root_dir() {
	CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}

# Truncation offsets as percentages of file size. Exercises the shallow
# codestream-completion blocker: reporting success without proving the final
# payload was validated.
MUTATION_TRUNCATE_PERCENTS=(25 50 75 90)

# Sniper offsets flip exactly one bit. Fixed percentages keep the corpus
# reproducible on every machine without seeding a PRNG.
MUTATION_FLIP_PERCENTS=(13 29 47 61 83)

# Boltgun offsets replace exactly one byte. They differ from sniper offsets so
# the two classifiers sample distinct portions of each stream.
MUTATION_BOLTGUN_PERCENTS=(17 37 53 71 89)

# Shotgun damage overwrites bounded regions while preserving file length. The
# first byte is always complemented, so every generated mutant differs even if
# the rest of a source region already contains the fill pattern.
MUTATION_SHOTGUN_PERCENTS=(23 57 77)
MUTATION_SHOTGUN_LENGTHS=(8 32 128)

# Emits deterministic mutants of one base into workdir, printing `kind<TAB>path`
# per mutant. Byte manipulation only, so results are identical everywhere
# regardless of the local cjxl/magick versions that minted the bases.
mutation_detection_emit_mutants() {
	local base_path="$1" workdir="$2"
	local stem size percent offset original mutated out

	stem="$(basename "${base_path}" .jxl)"
	size="$(stat -c%s "${base_path}")" || return 1

	if [ "${size}" -lt 64 ]; then
		echo "base fixture is implausibly small for mutation: ${base_path}" >&2
		return 1
	fi

	for percent in "${MUTATION_TRUNCATE_PERCENTS[@]}"; do
		offset=$((size * percent / 100))
		out="${workdir}/${stem}.truncate${percent}.jxl"
		head -c "${offset}" "${base_path}" > "${out}" || return 1
		printf 'truncate\t%s\n' "${out}"
	done

	for percent in "${MUTATION_FLIP_PERCENTS[@]}"; do
		offset=$((size * percent / 100))
		out="${workdir}/${stem}.flip${percent}.jxl"
		cp "${base_path}" "${out}" || return 1
		original="$(od -An -tu1 -j "${offset}" -N1 "${base_path}" | tr -d ' ')"
		mutated=$((original ^ 1))
		printf "$(printf '\\x%02x' "${mutated}")" \
			| dd of="${out}" bs=1 seek="${offset}" count=1 conv=notrunc status=none || return 1
		printf 'sniper\t%s\n' "${out}"
	done

	for percent in "${MUTATION_BOLTGUN_PERCENTS[@]}"; do
		offset=$((size * percent / 100))
		out="${workdir}/${stem}.boltgun${percent}.jxl"
		cp "${base_path}" "${out}" || return 1
		original="$(od -An -tu1 -j "${offset}" -N1 "${base_path}" | tr -d ' ')"
		mutated=$((original ^ 255))
		printf "$(printf '\\x%02x' "${mutated}")" \
			| dd of="${out}" bs=1 seek="${offset}" count=1 conv=notrunc status=none || return 1
		printf 'boltgun\t%s\n' "${out}"
	done

	local index length available
	for ((index = 0; index < ${#MUTATION_SHOTGUN_PERCENTS[@]}; index++)); do
		percent="${MUTATION_SHOTGUN_PERCENTS[index]}"
		length="${MUTATION_SHOTGUN_LENGTHS[index]}"
		offset=$((size * percent / 100))
		available=$((size - offset))
		if [ "${length}" -gt "${available}" ]; then
			length="${available}"
		fi
		[ "${length}" -gt 0 ] || return 1
		out="${workdir}/${stem}.shotgun${percent}x${length}.jxl"
		cp "${base_path}" "${out}" || return 1
		head -c "${length}" /dev/zero | tr '\000' '\245' \
			| dd of="${out}" bs=1 seek="${offset}" count="${length}" conv=notrunc status=none || return 1
		original="$(od -An -tu1 -j "${offset}" -N1 "${base_path}" | tr -d ' ')"
		mutated=$((original ^ 255))
		printf "$(printf '\\x%02x' "${mutated}")" \
			| dd of="${out}" bs=1 seek="${offset}" count=1 conv=notrunc status=none || return 1
		printf 'shotgun\t%s\n' "${out}"
	done

	# The codestream signature is the one structural field no valid stream may
	# alter, so this mutant must be detected by any parser worth the name.
	out="${workdir}/${stem}.signature.jxl"
	cp "${base_path}" "${out}" || return 1
	original="$(od -An -tu1 -j 0 -N1 "${base_path}" | tr -d ' ')"
	mutated=$((original ^ 0xff))
	printf "$(printf '\\x%02x' "${mutated}")" \
		| dd of="${out}" bs=1 seek=0 count=1 conv=notrunc status=none || return 1
	printf 'signature\t%s\n' "${out}"
}

# Sweeps every vendored base and its mutants, then reports the detection matrix.
# Fails on any false accept, on any drift in the declared denominators, or if a
# base stops decoding, which would silently turn this into a vacuous gate.
run_mutation_detection() {
	local base_dir="$1"
	local expected_bases="$2"
	local expected_mutants="$3"
	local expected_must_detect="$4"
	local expected_over_rejections="$5"

	local root_dir workdir build_log system package_out oracle_djxl
	local base_path mutant_line kind mutant_path
	local bases=0 mutants=0 must_detect=0 detected=0 may_ignore=0
	local over_rejections=0 false_accepts=0 base_rejected=0
	local oracle_status ours_status

	root_dir="$(mutation_detection_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/mutation_detection.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"

	source "${root_dir}/tests/lib/decode_ground_truth_corpus.bash" || return 1
	oracle_djxl="$(decode_ground_truth_oracle_djxl)" || return 1
	decode_ground_truth_check_oracle "${oracle_djxl}" || return 1

	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	if ! package_out="$(nix build --no-link --print-out-paths ".#packages.${system}.default" 2>"${build_log}")"; then
		cat "${build_log}" >&2
		return 1
	fi

	while IFS= read -r base_path; do
		bases=$((bases + 1))

		if ! "${oracle_djxl}" "${base_path}" "${workdir}/oracle.pam" \
			>/dev/null 2>"${workdir}/oracle.stderr"; then
			echo "vendored base is not decodable by the pinned oracle: ${base_path}" >&2
			return 1
		fi

		if ! "${package_out}/bin/djxlz" "${base_path}" "${workdir}/ours.pam" \
			--output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
			echo "libjxlz no longer accepts vendored base ${base_path}; specificity is lost and every detection below would be vacuous" >&2
			base_rejected=$((base_rejected + 1))
			continue
		fi

		while IFS=$'\t' read -r kind mutant_path; do
			mutants=$((mutants + 1))

			if "${oracle_djxl}" "${mutant_path}" "${workdir}/oracle.pam" \
				>/dev/null 2>"${workdir}/oracle.stderr"; then
				oracle_status=0
			else
				oracle_status=1
			fi

			if "${package_out}/bin/djxlz" "${mutant_path}" "${workdir}/ours.pam" \
				--output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
				ours_status=0
			else
				ours_status=1
			fi

			if [ "${oracle_status}" -eq 1 ]; then
				must_detect=$((must_detect + 1))
				if [ "${ours_status}" -eq 1 ]; then
					detected=$((detected + 1))
				else
					false_accepts=$((false_accepts + 1))
					echo "FALSE ACCEPT: ${kind} mutant accepted by libjxlz but rejected by the oracle: ${mutant_path}" >&2
				fi
				continue
			fi

			may_ignore=$((may_ignore + 1))
			if [ "${ours_status}" -eq 1 ]; then
				over_rejections=$((over_rejections + 1))
			fi
		done < <(mutation_detection_emit_mutants "${base_path}" "${workdir}")
	done < <(find "${base_dir}" -type f -name '*.jxl' | sort)

	printf 'mutation detection over accepted lossless-modular bases (oracle djxl v%s)\n' \
		"$(decode_ground_truth_oracle_version)"
	printf '  bases             n=%d  accepted-by-libjxlz=%d  (specificity: a reject-everything build fails here)\n' \
		"${bases}" "$((bases - base_rejected))"
	printf '  mutants           n=%d  must-detect=%d  may-ignore=%d\n' \
		"${mutants}" "${must_detect}" "${may_ignore}"
	printf '  must-detect       detected=%d  FALSE ACCEPTS=%d\n' \
		"${detected}" "${false_accepts}"
	printf '  may-ignore        over-rejected=%d (oracle still decodes these; rejecting them is stricter than the oracle, not necessarily wrong)\n' \
		"${over_rejections}"

	local failures=0

	if [ "${base_rejected}" -ne 0 ]; then
		echo "${base_rejected} vendored base(s) stopped decoding" >&2
		failures=$((failures + 1))
	fi
	if [ "${bases}" -ne "${expected_bases}" ]; then
		echo "base count drifted: expected ${expected_bases}, observed ${bases}" >&2
		failures=$((failures + 1))
	fi
	if [ "${mutants}" -ne "${expected_mutants}" ]; then
		echo "mutant count drifted: expected ${expected_mutants}, observed ${mutants}" >&2
		failures=$((failures + 1))
	fi
	if [ "${must_detect}" -ne "${expected_must_detect}" ]; then
		echo "must-detect count drifted: expected ${expected_must_detect}, observed ${must_detect}" >&2
		failures=$((failures + 1))
	fi
	if [ "${false_accepts}" -ne 0 ]; then
		echo "libjxlz accepted ${false_accepts} mutant(s) the pinned oracle rejects" >&2
		failures=$((failures + 1))
	fi
	if [ "${over_rejections}" -ne "${expected_over_rejections}" ]; then
		echo "over-rejection count changed: expected ${expected_over_rejections}, observed ${over_rejections}" >&2
		failures=$((failures + 1))
	fi

	if [ "${failures}" -ne 0 ]; then
		echo "mutation detection failed with ${failures} deviation(s)" >&2
		return 1
	fi
}
