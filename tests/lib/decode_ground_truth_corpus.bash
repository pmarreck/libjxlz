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

decode_ground_truth_oracle_version() {
	printf '%s\n' "${JXLZ_ORACLE_DJXL_VERSION:-0.12.0}"
}

decode_ground_truth_oracle_djxl() {
	if [ -n "${JXLZ_ORACLE_DJXL:-}" ]; then
		printf '%s\n' "${JXLZ_ORACLE_DJXL}"
		return 0
	fi
	command -v djxl
}

decode_ground_truth_check_oracle() {
	local oracle_djxl="$1"
	local expected_version actual_version
	expected_version="$(decode_ground_truth_oracle_version)" || return 1
	if ! actual_version="$("${oracle_djxl}" --version 2>&1 | sed -n '1p')"; then
		echo "failed to execute djxl oracle: ${oracle_djxl}" >&2
		return 1
	fi
	case "${actual_version}" in
		*"v${expected_version}"*)
			return 0
			;;
		*)
			echo "expected djxl v${expected_version} oracle, got: ${actual_version}" >&2
			echo "set JXLZ_ORACLE_DJXL and JXLZ_ORACLE_DJXL_VERSION to change the pinned oracle intentionally" >&2
			return 1
			;;
	esac
}

# Runs a checked-in still-image JXL corpus against upstream `djxl` and the
# packaged `djxlz`, comparing exact decoded PAM bytes to lock down decoder
# parity on real upstream-produced fixtures before broader corpus expansion.
run_decode_ground_truth_manifest() {
	local manifest_path="$1"
	local root_dir package_out workdir build_log total index line relpath
	local system upstream_out our_out oracle_djxl

	root_dir="$(decode_ground_truth_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/decode_ground_truth.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"
	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	total="$(decode_ground_truth_case_count "${manifest_path}")" || return 1
	index=0
	oracle_djxl="$(decode_ground_truth_oracle_djxl)" || return 1
	decode_ground_truth_check_oracle "${oracle_djxl}" || return 1

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

		if ! "${oracle_djxl}" "${root_dir}/${relpath}" "${upstream_out}" >/dev/null 2>"${workdir}/upstream.stderr"; then
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

assert_pam_known_diff_is_byte_close() {
	local upstream_out="$1"
	local our_out="$2"
	local relpath="$3"

	perl - "$upstream_out" "$our_out" "$relpath" <<'PERL'
use strict;
use warnings;
my ($upstream_path, $ours_path, $relpath) = @ARGV;
open my $ufh, '<:raw', $upstream_path or die "open upstream: $!\n";
open my $ofh, '<:raw', $ours_path or die "open ours: $!\n";
local $/;
my $u = <$ufh>;
my $o = <$ofh>;
my $marker = "ENDHDR\n";
my $uh = index($u, $marker);
my $oh = index($o, $marker);
if ($uh < 0 || $oh < 0) {
	print STDERR "known-diff case ${relpath} did not produce PAM headers\n";
	exit 1;
}
$uh += length($marker);
$oh += length($marker);
my $u_header = substr($u, 0, $uh);
my $o_header = substr($o, 0, $oh);
if ($u_header ne $o_header) {
	print STDERR "known-diff case ${relpath} changed PAM header shape\n";
	exit 1;
}
my $u_payload = substr($u, $uh);
my $o_payload = substr($o, $oh);
if (length($u_payload) != length($o_payload)) {
	print STDERR "known-diff case ${relpath} changed payload size\n";
	exit 1;
}
my $mismatches = 0;
my $max_delta = 0;
for (my $i = 0; $i < length($u_payload); $i++) {
	my $delta = abs(ord(substr($u_payload, $i, 1)) - ord(substr($o_payload, $i, 1)));
	next if $delta == 0;
	$mismatches++;
	$max_delta = $delta if $delta > $max_delta;
}
if ($mismatches == 0) {
	print STDERR "known-diff case ${relpath} unexpectedly matched upstream\n";
	exit 1;
}
if ($max_delta > 1) {
	print STDERR "known-diff case ${relpath} widened beyond +/-1 byte deltas (max ${max_delta})\n";
	exit 1;
}
PERL
}

# Records known decoder-parity gaps where upstream `djxl` succeeds and packaged
# `djxlz` also emits pixels, but the decoded PAM bytes still differ. This keeps
# real-oracle coverage on current mismatches without pretending they are fixed.
run_decode_ground_truth_manifest_expect_diff() {
	local manifest_path="$1"
	local root_dir package_out workdir build_log total index line relpath
	local system upstream_out our_out oracle_djxl

	root_dir="$(decode_ground_truth_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/decode_ground_truth_diff.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"
	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	total="$(decode_ground_truth_case_count "${manifest_path}")" || return 1
	index=0
	oracle_djxl="$(decode_ground_truth_oracle_djxl)" || return 1
	decode_ground_truth_check_oracle "${oracle_djxl}" || return 1

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

		if ! "${oracle_djxl}" "${root_dir}/${relpath}" "${upstream_out}" >/dev/null 2>"${workdir}/upstream.stderr"; then
			echo "upstream djxl failed for known-diff case ${relpath} (${index}/${total})" >&2
			cat "${workdir}/upstream.stderr" >&2
			return 1
		fi

		if ! "${package_out}/bin/djxlz" "${root_dir}/${relpath}" "${our_out}" --output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
			echo "djxlz unexpectedly failed for known-diff case ${relpath} (${index}/${total})" >&2
			cat "${workdir}/ours.stderr" >&2
			return 1
		fi

		if cmp -s "${upstream_out}" "${our_out}"; then
			echo "known-diff case unexpectedly matched upstream for ${relpath} (${index}/${total})" >&2
			return 1
		fi
		assert_pam_known_diff_is_byte_close "${upstream_out}" "${our_out}" "${relpath}" || return 1
	done < "${manifest_path}"
}

# Records known unsupported decoder cases where upstream `djxl` succeeds but the
# packaged `djxlz` still rejects the codestream. This keeps the unsupported
# surface explicit until those features are implemented.
run_decode_ground_truth_manifest_expect_djxlz_fail() {
	local manifest_path="$1"
	local root_dir package_out workdir build_log total index line relpath
	local system upstream_out our_out oracle_djxl

	root_dir="$(decode_ground_truth_root_dir)" || return 1
	workdir="$(mktemp -d "${TMPDIR:-/tmp}/decode_ground_truth_fail.XXXXXX")" || return 1
	build_log="${workdir}/package_build.log"
	system="$(nix eval --impure --raw --expr builtins.currentSystem)" || return 1
	total="$(decode_ground_truth_case_count "${manifest_path}")" || return 1
	index=0
	oracle_djxl="$(decode_ground_truth_oracle_djxl)" || return 1
	decode_ground_truth_check_oracle "${oracle_djxl}" || return 1

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

		if ! "${oracle_djxl}" "${root_dir}/${relpath}" "${upstream_out}" >/dev/null 2>"${workdir}/upstream.stderr"; then
			echo "upstream djxl failed for known-unsupported case ${relpath} (${index}/${total})" >&2
			cat "${workdir}/upstream.stderr" >&2
			return 1
		fi

		if "${package_out}/bin/djxlz" "${root_dir}/${relpath}" "${our_out}" --output_format pam >/dev/null 2>"${workdir}/ours.stderr"; then
			echo "djxlz unexpectedly succeeded for known-unsupported case ${relpath} (${index}/${total})" >&2
			return 1
		fi
	done < "${manifest_path}"
}
