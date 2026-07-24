#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

system="$(nix eval --impure --raw --expr builtins.currentSystem)" || exit 1
package_out="$(nix build --no-link --print-out-paths ".#packages.${system}.default")" || exit 1

if ! about="$("${package_out}/bin/djxlz" --about 2>&1)"; then
	echo "packaged djxlz must execute on the build host" >&2
	printf '%s\n' "${about}" >&2
	exit 1
fi

case "${about}" in
	*"djxlz"*) ;;
	*)
		echo "packaged djxlz --about output is missing its program identity" >&2
		printf '%s\n' "${about}" >&2
		exit 1
		;;
esac
