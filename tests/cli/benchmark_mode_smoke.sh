#!/usr/bin/env bash
set -u

scratch="$(mktemp -d "${TMPDIR}/libjxlz-benchmark-mode.XXXXXX")" || exit 1
mkdir "$scratch/bin" || exit 1
cat > "$scratch/bin/nix" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
	eval) printf 'x86_64-linux';;
	build) printf '%s\n' "$@" > "$BENCH_ARGS"; exit 42;;
	*) exit 43;;
esac
MOCK
chmod +x "$scratch/bin/nix"
BENCH_ARGS="$scratch/args" PATH="$scratch/bin:$PATH" IN_NIX_SHELL=1 bash ./bm > "$scratch/output" 2>&1
status=$?
expected=$'build\n--no-link\n--print-out-paths\n.#packages.x86_64-linux.releasefast'
if [ "$status" -ne 1 ] || [ "$(cat "$scratch/args")" != "$expected" ]; then
	printf 'Benchmark must request the ReleaseFast package; actual request:\n' >&2
	cat "$scratch/args" >&2
	exit 1
fi
