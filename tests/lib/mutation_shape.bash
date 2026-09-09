#!/usr/bin/env bash

mutation_shape_matches() {
	local kind="$1" base="$2" mutant="$3" workdir="$4"
	local name size mutated_size percent start span=1 expected_xor=255
	local position before after differences=0 status
	name=$(basename "$mutant") || return 1
	size=$(stat -c%s "$base") || return 1
	mutated_size=$(stat -c%s "$mutant") || return 1
	case "$kind" in
		truncate)
			[[ "$name" =~ \.truncate([0-9]+)\.jxl$ ]] || return 1
			percent=$((10#${BASH_REMATCH[1]}))
			((percent > 0 && percent < 100)) || return 1
			[ "$mutated_size" -eq "$((size * percent / 100))" ] || return 1
			cmp -n "$mutated_size" "$base" "$mutant" >/dev/null 2>&1
			return $?
			;;
		sniper|boltgun)
			[[ "$name" =~ \.(flip|boltgun)([0-9]+)\.jxl$ ]] || return 1
			if [ "$kind" = sniper ]; then
				[ "${BASH_REMATCH[1]}" = flip ] || return 1
				expected_xor=1
			else
				[ "${BASH_REMATCH[1]}" = boltgun ] || return 1
			fi
			percent=$((10#${BASH_REMATCH[2]}))
			((percent > 0 && percent < 100)) || return 1
			start=$((size * percent / 100))
			;;
		shotgun)
			[[ "$name" =~ \.shotgun([0-9]+)x([0-9]+)\.jxl$ ]] || return 1
			percent=$((10#${BASH_REMATCH[1]}))
			span=$((10#${BASH_REMATCH[2]}))
			((percent > 0 && percent < 100)) || return 1
			start=$((size * percent / 100))
			((span > 0 && span <= size - start)) || return 1
			;;
		signature)
			[[ "$name" =~ \.signature\.jxl$ ]] || return 1
			start=0
			;;
		*) return 1 ;;
	esac
	[ "$mutated_size" -eq "$size" ] || return 1
	cmp -l "$base" "$mutant" > "$workdir/shape-differences.txt" 2> "$workdir/shape-cmp.stderr"
	status=$?
	[ "$status" -eq 1 ] || return 1
	while read -r position before after; do
		differences=$((differences + 1))
		((position > start && position <= start + span)) || return 1
		if [ "$kind" != shotgun ]; then
			[ "$((8#$before ^ 8#$after))" -eq "$expected_xor" ] || return 1
		fi
	done < "$workdir/shape-differences.txt"
	[ "$differences" -gt 0 ] || return 1
	if [ "$kind" != shotgun ]; then
		[ "$differences" -eq 1 ]
		return $?
	fi
	before=$(od -An -tu1 -j "$start" -N1 "$base" | tr -d ' ') || return 1
	od -An -v -tu1 -j "$start" -N "$span" "$mutant" > "$workdir/shape-region.txt" || return 1
	local index=0 byte expected
	local -a bytes=()
	while read -r -a bytes; do
		for byte in "${bytes[@]}"; do
			expected=165
			[ "$index" -ne 0 ] || expected=$((before ^ 255))
			[ "$byte" -eq "$expected" ] || return 1
			index=$((index + 1))
		done
	done < "$workdir/shape-region.txt"
	[ "$index" -eq "$span" ]
}
