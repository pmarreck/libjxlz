#!/usr/bin/env bash

decode_ground_truth_root_dir() {
	CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd
}

decode_ground_truth_case_count() {
	local manifest_path="$1"
	local total=0
	local line
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
			''|\#*)
				continue
				;;
		esac
		total=$((total + 1))
	done < "${manifest_path}"
	printf '%s\n' "${total}"
}

# Runs a checked-in still-image JXL corpus against upstream `djxl` and the
# packaged `djxlz`, comparing exact decoded PAM bytes to lock down decoder
# parity on real upstream-produced fixtures before broader corpus expansion.
run_decode_ground_truth_manifest() {
	local manifest_path="$1"
	local root_dir package_out workdir build_log total index line relpath
	local system upstream_out our_out

	root_dir="$(decode_ground_truth_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/decode_ground_truth.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"
	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	total="$(decode_ground_truth_case_count "${manifest_path}")" || return 1
	index=0

	if ! package_out="$(nix build --no-link --print-out-paths ".#packages.${system}.default" 2>"${build_log}")"; then
		cat "${build_log}" >&2
		return 1
	fi

	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
			''|\#*)
				continue
				;;
		esac

		index=$((index + 1))
		relpath="${line}"
		upstream_out="${workdir}/$(printf '%03d' "${index}").upstream.pam"
		our_out="${workdir}/$(printf '%03d' "${index}").ours.pam"

		if ! djxl "${root_dir}/${relpath}" "${upstream_out}" >/dev/null 2>"${workdir}/upstream.stderr"; then
			echo "upstream djxl failed for ${relpath} (${index}/${total})" >&2
			cat "${workdir}/upstream.stderr" >&2
			return 1
		fi

		if ! "${package_out}/bin/djxlz" "${root_dir}/${relpath}" "${our_out}" --output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
			echo "djxlz failed for ${relpath} (${index}/${total})" >&2
			cat "${workdir}/ours.stderr" >&2
			return 1
		fi

		if ! cmp -s "${upstream_out}" "${our_out}"; then
			echo "ground-truth decode mismatch for ${relpath} (${index}/${total})" >&2
			cmp -l "${upstream_out}" "${our_out}" | sed -n '1,20p' >&2
			return 1
		fi
	done < "${manifest_path}"
}
