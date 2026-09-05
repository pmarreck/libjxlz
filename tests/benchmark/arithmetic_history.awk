# Input is the benchmark's flat JSON schema. Compare CPU nanoseconds per
# element only within the same machine, target, operation and input size.
{
	delete field
	line = $0
	while (match(line, /"[^"]*":("[^"]*"|[-+.0-9eE]+)/)) {
		pair = substr(line, RSTART, RLENGTH)
		colon = index(pair, ":")
		name = substr(pair, 2, colon - 3)
		value = substr(pair, colon + 1)
		gsub(/^"|"$/, "", value)
		field[name] = value
		line = substr(line, RSTART + RLENGTH)
	}
	if (field["count"] <= 0 || field["repeat"] <= 0 || field["cpu_ns"] <= 0) {
		print "Invalid arithmetic measurement"
		invalid = 1
		next
	}
	key = field["machine"] SUBSEP field["target"] SUBSEP field["type"] SUBSEP field["operation"] SUBSEP field["count"]
	current = field["cpu_ns"] / field["count"] / field["repeat"]
	if (FILENAME == ARGV[1]) { previous[key] = current; next }
	if (key in previous) {
		delta = 100 * (current / previous[key] - 1)
		if (delta > 5 || delta < -5) {
			printf "PERF SHIFT: %s/%s CPU %+.2f%%\n", field["type"], field["operation"], delta
			shifted = 1
		}
	}
}
END { exit (invalid ? 2 : shifted ? 1 : 0) }
