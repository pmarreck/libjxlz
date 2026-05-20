#!/usr/bin/env bash
# Copyright (c) Peter Marreck and libjxlz contributors.
# SPDX-License-Identifier: BSD-3-Clause
set -u

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/zig_runner_smoke.XXXXXX")"
RUN_STDOUT="${WORKDIR}/stdout.txt"
RUN_STDERR="${WORKDIR}/stderr.txt"
FAKE_BIN="${WORKDIR}/bin"
mkdir -p "${FAKE_BIN}"

cat >"${FAKE_BIN}/zig" <<'ZIG'
#!/usr/bin/env bash
set -u
printf 'zig:%s\n' "$*"
ZIG
chmod +x "${FAKE_BIN}/zig"

cat >"${FAKE_BIN}/nix" <<'NIX'
#!/usr/bin/env bash
set -u
if [ "${1-}" != "develop" ] || [ "${2-}" != "-c" ] || [ "${3-}" != "zig" ]; then
	echo "unexpected nix invocation: $*" >&2
	exit 99
fi
shift 3
printf 'nix:%s\n' "$*"
exec zig "$@"
NIX
chmod +x "${FAKE_BIN}/nix"

if env -u IN_NIX_SHELL -u NIX_BUILD_TOP PATH="${FAKE_BIN}:$PATH" bash -c '
	source ./tests/lib/zig_runner.bash
	run_project_zig build -Doptimize=ReleaseFast
' >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 0 ]; then
	echo "expected outside-Nix zig launch to succeed"
	cat "${RUN_STDOUT}"
	cat "${RUN_STDERR}"
	exit 1
fi

if ! grep -Fqx 'nix:build -Doptimize=ReleaseFast' "${RUN_STDOUT}"; then
	echo "missing nix-develop launch"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Fqx 'zig:build -Doptimize=ReleaseFast' "${RUN_STDOUT}"; then
	echo "missing zig invocation after nix develop"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! PATH="${FAKE_BIN}:$PATH" IN_NIX_SHELL=impure bash -c '
	source ./tests/lib/zig_runner.bash
	run_project_zig test src/lib/root.zig
' >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	echo "expected in-Nix zig launch to succeed"
	cat "${RUN_STDOUT}"
	cat "${RUN_STDERR}"
	exit 1
fi

if grep -q '^nix:' "${RUN_STDOUT}"; then
	echo "did not expect nix develop inside nix shell"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Fqx 'zig:test src/lib/root.zig' "${RUN_STDOUT}"; then
	echo "missing direct zig invocation inside nix shell"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! PATH="${FAKE_BIN}:$PATH" NIX_BUILD_TOP="${WORKDIR}/nix-build" bash -c '
	source ./tests/lib/zig_runner.bash
	run_project_zig build-exe bench_modular_encode_prep.zig
' >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	echo "expected nix-build-context zig launch to succeed"
	cat "${RUN_STDOUT}"
	cat "${RUN_STDERR}"
	exit 1
fi

if grep -q '^nix:' "${RUN_STDOUT}"; then
	echo "did not expect nix develop inside nix build"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Fqx 'zig:build-exe bench_modular_encode_prep.zig' "${RUN_STDOUT}"; then
	echo "missing direct zig invocation inside nix build"
	cat "${RUN_STDOUT}"
	exit 1
fi
