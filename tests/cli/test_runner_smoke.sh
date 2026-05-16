#!/usr/bin/env bash
set -u

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test_runner_smoke.XXXXXX")"
RUN_STDOUT="${WORKDIR}/stdout.txt"
RUN_STDERR="${WORKDIR}/stderr.txt"
FAKE_ROOT="${WORKDIR}/root"
FAKE_BIN="${FAKE_ROOT}/bin"
FAKE_TESTS="${FAKE_ROOT}/cli"
mkdir -p "${FAKE_BIN}" "${FAKE_TESTS}"

cat >"${FAKE_BIN}/nix" <<'FAKE'
#!/usr/bin/env bash
set -u
case "${1-}" in
	eval)
		echo fake-system
		exit 0
		;;
	build)
		exit 0
		;;
	develop)
		shift
		if [ "${1-}" != "-c" ] || [ "${2-}" != "bash" ]; then
			echo "unexpected develop invocation" >&2
			exit 99
		fi
		if [ ! -d "${TMPDIR-}" ]; then
			echo "tmpdir missing: ${TMPDIR-}" >&2
			exit 97
		fi
		shift 2
		exec bash "$@"
		;;
	*)
		echo "unexpected nix subcommand: ${1-}" >&2
		exit 98
		;;
esac
FAKE
chmod +x "${FAKE_BIN}/nix"

cat >"${FAKE_TESTS}/pass.sh" <<'PASS'
#!/usr/bin/env bash
set -u
exit 0
PASS
chmod +x "${FAKE_TESTS}/pass.sh"

cat >"${FAKE_TESTS}/fail.sh" <<'FAIL'
#!/usr/bin/env bash
set -u
echo intentional-failure >&2
exit 1
FAIL
chmod +x "${FAKE_TESTS}/fail.sh"

BAD_TMPDIR="${WORKDIR}/missing/tmpdir"
if TMPDIR="${BAD_TMPDIR}" PATH="${FAKE_BIN}:$PATH" bash -c '
	source ./tests/lib/test_runner.bash
	run_shell_test_dir "CLI tests" nix "$1"
' bash "${FAKE_TESTS}" >"${RUN_STDOUT}" 2>"${RUN_STDERR}"; then
	status=0
else
	status=$?
fi

if [ "${status}" -ne 1 ]; then
	echo "expected exit status 1, got ${status}"
	cat "${RUN_STDOUT}"
	cat "${RUN_STDERR}"
	exit 1
fi

if ! grep -Fqx '=== CLI tests (2) ===' "${RUN_STDOUT}"; then
	echo "missing suite header"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Eq '^\[1/2\] .*/fail\.sh$' "${RUN_STDOUT}"; then
	echo "missing first progress line"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Eq '^\[2/2\] .*/pass\.sh$' "${RUN_STDOUT}"; then
	echo "missing second progress line"
	cat "${RUN_STDOUT}"
	exit 1
fi

if ! grep -Fqx 'intentional-failure' "${RUN_STDERR}"; then
	echo "missing failing test stderr"
	cat "${RUN_STDERR}"
	exit 1
fi
