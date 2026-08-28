#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TEST_TMPDIR="$(mktemp -d "${TMPDIR}/libjxlz-package-fetch.XXXXXX")" || exit 1
GLOBAL_CACHE_DIR="${TEST_TMPDIR}/zig-cache"
FETCH_OUT="${TEST_TMPDIR}/fetch.out"
FETCH_ERR="${TEST_TMPDIR}/fetch.err"
PKG_DIR="${TEST_TMPDIR}/pkg"

source "${ROOT_DIR}/tests/lib/capture.bash"

# Fetch a copy of build.zig.zon `.paths` only. The GitHub worktree is ~1.3G
# with submodules; `zig fetch` of the repo root on linux-x86_64 did not
# finish in 60s. The package content itself is under 1M.
mkdir -p "${PKG_DIR}/lib"
cp -a "${ROOT_DIR}/build.zig" "${ROOT_DIR}/build.zig.zon" "${PKG_DIR}/"
cp -a "${ROOT_DIR}/include" "${ROOT_DIR}/src" "${PKG_DIR}/"
cp -a "${ROOT_DIR}/lib/include" "${PKG_DIR}/lib/"

# Files, not `capture`: its FD-juggle stalled `zig fetch` on GitHub x86_64.
if command -v timeout >/dev/null 2>&1; then
	timeout 60 zig fetch --global-cache-dir "${GLOBAL_CACHE_DIR}" "${PKG_DIR}" >"${FETCH_OUT}" 2>"${FETCH_ERR}"
	rc=$?
elif command -v gtimeout >/dev/null 2>&1; then
	gtimeout 60 zig fetch --global-cache-dir "${GLOBAL_CACHE_DIR}" "${PKG_DIR}" >"${FETCH_OUT}" 2>"${FETCH_ERR}"
	rc=$?
else
	zig fetch --global-cache-dir "${GLOBAL_CACHE_DIR}" "${PKG_DIR}" >"${FETCH_OUT}" 2>"${FETCH_ERR}"
	rc=$?
fi
out="$(cat "${FETCH_OUT}")"
err="$(cat "${FETCH_ERR}")"
if [ "${rc}" -ne 0 ]; then
	printf '%s\n' "${err}" >&2
	if [ "${rc}" -eq 124 ]; then
		printf 'zig fetch timed out after 60s\n' >&2
	fi
	exit "${rc}"
fi

PACKAGE_HASH="${out##*$'\n'}"
PACKAGE_ARCHIVE="${GLOBAL_CACHE_DIR}/p/${PACKAGE_HASH}.tar.gz"

if [ ! -f "${PACKAGE_ARCHIVE}" ]; then
	printf 'Zig fetch did not create package archive %s\n' "${PACKAGE_ARCHIVE}" >&2
	exit 1
fi

out=''
err=''
rc=0
capture tar -tzf "${PACKAGE_ARCHIVE}"
if [ "${rc}" -ne 0 ]; then
	printf '%s\n' "${err}" >&2
	exit "${rc}"
fi

for header in include/jxl/version.h lib/include/jxl/validate.h; do
	case "${out}" in
		*"/${header}" | *"/${header}"$'\n'*) ;;
		*)
		printf 'fetched Zig package is missing %s\n' "${header}" >&2
		exit 1
			;;
	esac
done
