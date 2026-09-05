#!/usr/bin/env bash
set -u
scratch="$(mktemp -d "${TMPDIR}/libjxlz-benchmark-reference.XXXXXX")" || exit 1
mkdir -p "$scratch/bin" "$scratch/ignored repository" || exit 1
git -c init.defaultBranch=yolo -C "$scratch/ignored repository" init -q || exit 1
printf '*\n' > "$scratch/ignored repository/.gitignore"
cat > "$scratch/bin/clang" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cp "$scratch/bin/clang" "$scratch/bin/pkg-config"
cat > "$scratch/bin/cmake" <<'MOCK'
#!/usr/bin/env bash
printf 'called\n' >> "$BENCH_CMAKE"
MOCK
chmod +x "$scratch/bin/clang" "$scratch/bin/pkg-config" "$scratch/bin/cmake"
# Execute the actual benchmark function without starting its timing workloads.
source <(awk '/^compile_ref\(\) \{/ {inside=1} inside {print} inside && /^}/ {exit}' bm)
failed=0
for kind in linux macos static mixed rejected; do
	REF_BUILD_DIR="$scratch/ignored repository/$kind build"
	mkdir -p "$REF_BUILD_DIR/lib" || exit 1
	case "$kind" in
		linux|mixed)
			: > "$REF_BUILD_DIR/lib/libjxl.so.0.12.0"
			ln -s libjxl.so.0.12.0 "$REF_BUILD_DIR/lib/libjxl.so"
			expected="$REF_BUILD_DIR/lib/libjxl.so"
			if [ "$kind" = mixed ]; then : > "$REF_BUILD_DIR/lib/libjxl.a"; fi;;
		macos)
			: > "$REF_BUILD_DIR/lib/libjxl.0.12.dylib"
			ln -s libjxl.0.12.dylib "$REF_BUILD_DIR/lib/libjxl.dylib"
			expected="$REF_BUILD_DIR/lib/libjxl.dylib";;
		static) : > "$REF_BUILD_DIR/lib/libjxl.a"; expected="$REF_BUILD_DIR/lib/libjxl.a";;
		rejected)
			mkdir "$REF_BUILD_DIR/lib/libjxl.so" "$REF_BUILD_DIR/lib/libjxl.a"
			ln -s absent "$REF_BUILD_DIR/lib/libjxl.dylib"
			: > "$REF_BUILD_DIR/lib/libjxl_cms.a"
			: > "$REF_BUILD_DIR/lib/libjxl.so.debug";;
	esac
	REF_COMPILE_LOG="$scratch/$kind.compile"
	REF_BIN="$scratch/$kind.binary"
	export BENCH_CMAKE="$scratch/$kind.cmake"
	actual="$( { PATH="$scratch/bin:$PATH"; compile_ref; printf '%s' "$REF_LIB"; } 2>&1)"
	status=$?
	if [ "$kind" = rejected ]; then
		if [ "$status" -eq 1 ] && [ -s "$BENCH_CMAKE" ] && [ "$actual" = "reference libjxl build not found under $REF_BUILD_DIR/lib" ]; then continue; fi
	elif [ "$status" -eq 0 ] && [ "$actual" = "$expected" ] && [ ! -e "$BENCH_CMAKE" ]; then
		continue
	fi
	printf 'Reference-library classification failed for %s (status %s): %s\n' "$kind" "$status" "$actual" >&2
	failed=$((failed + 1))
done
exit "$failed"
