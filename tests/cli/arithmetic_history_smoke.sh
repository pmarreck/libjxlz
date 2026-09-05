#!/usr/bin/env bash
set -u
scratch="$(mktemp -d "${TMPDIR}/libjxlz-arithmetic-history.XXXXXX")" || exit 1
cat > "$scratch/old" <<'ROWS'
{"machine":"a","target":"baseline","type":"Fixed","operation":"add","count":4,"repeat":10,"cpu_ns":400,"wall_ns":500}
{"machine":"a","target":"baseline","type":"Fixed","operation":"divide","count":4,"repeat":10,"cpu_ns":400,"wall_ns":500}
{"machine":"b","target":"baseline","type":"Fixed","operation":"multiply","count":4,"repeat":10,"cpu_ns":40,"wall_ns":50}
ROWS
cat > "$scratch/new" <<'ROWS'
{"machine":"a","target":"baseline","type":"Fixed","operation":"add","count":4,"repeat":20,"cpu_ns":1000,"wall_ns":1100}
{"machine":"a","target":"baseline","type":"Fixed","operation":"divide","count":4,"repeat":20,"cpu_ns":400,"wall_ns":500}
{"machine":"a","target":"baseline","type":"Fixed","operation":"multiply","count":4,"repeat":10,"cpu_ns":400,"wall_ns":500}
ROWS
for file in old new; do
	awk '{ sub(/^\{/, "{\"timestamp\":\"2026-09-05T13:00:00Z\","); print }' "$scratch/$file" > "$scratch/dated-$file"
done
awk -f tests/benchmark/arithmetic_history.awk "$scratch/dated-old" "$scratch/dated-new" > "$scratch/out" 2>&1
status=$?
expected=$'PERF SHIFT: Fixed/add CPU +25.00%\nPERF SHIFT: Fixed/divide CPU -50.00%'
if [ "$status" -ne 1 ] || [ "$(cat "$scratch/out")" != "$expected" ]; then
	printf 'Arithmetic history must detect both shifts and ignore other machines\n' >&2
	cat "$scratch/out" >&2
	exit 1
fi
cp "$scratch/new" "$scratch/repeat"
awk -f tests/benchmark/arithmetic_history.awk "$scratch/new" "$scratch/repeat" > "$scratch/out" 2>&1
if [ "$?" -ne 0 ] || [ -s "$scratch/out" ]; then
	printf 'A repeated measurement must accept the recorded baseline\n' >&2
	exit 1
fi
printf '%s\n' '{"count":4,"repeat":0,"cpu_ns":100}' > "$scratch/invalid"
awk -f tests/benchmark/arithmetic_history.awk "$scratch/old" "$scratch/invalid" > "$scratch/out" 2>&1
if [ "$?" -ne 2 ] || [ "$(cat "$scratch/out")" != 'Invalid arithmetic measurement' ]; then
	printf 'Invalid timing records must be rejected before history append\n' >&2
	exit 1
fi
