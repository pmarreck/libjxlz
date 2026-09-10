#!/usr/bin/env bash
set -u

workdir=$(mktemp -d "${TMPDIR:-/tmp}/conformance-acceptance.XXXXXX") || exit 1
system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 1
if ! check_out=$(nix build --no-link --print-out-paths ".#checks.$system.conformance-acceptance" 2> "$workdir/build.log"); then
	cat "$workdir/build.log" >&2
	exit 1
fi
[ -s "$check_out/results.tsv" ] && [ -s "$check_out/provenance.txt" ]
