#!/usr/bin/env bash
set -u

SYSTEM="$(nix eval --impure --raw --expr builtins.currentSystem)"
PACKAGE_BUILD_LOG="${TMPDIR}/capi_compressed_icc_cross_oracle_package.log"
OURS_BUILD_LOG="${TMPDIR}/capi_compressed_icc_cross_oracle_ours_build.log"
UPSTREAM_BUILD_LOG="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream_build.log"
UPSTREAM_CMAKE_LOG="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream_cmake.log"
UPSTREAM_LIB_BUILD_LOG="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream_lib_build.log"
OURS_BIN="${TMPDIR}/capi_compressed_icc_cross_oracle_ours"
UPSTREAM_BIN="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream"
OURS_PROFILE="${TMPDIR}/capi_compressed_icc_cross_oracle_ours.icc"
UPSTREAM_PROFILE="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream.icc"
OURS_COMPRESSED="${TMPDIR}/capi_compressed_icc_cross_oracle_ours.cicc"
UPSTREAM_COMPRESSED="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream.cicc"
OURS_DECODED_UPSTREAM="${TMPDIR}/capi_compressed_icc_cross_oracle_ours_decoded_upstream.icc"
UPSTREAM_DECODED_OURS="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream_decoded_ours.icc"
UPSTREAM_BUILD_DIR="${TMPDIR}/capi_compressed_icc_cross_oracle_upstream_build"

if ! PACKAGE_OUT="$(nix build --no-link --print-out-paths ".#packages.${SYSTEM}.default" 2>"${PACKAGE_BUILD_LOG}")"; then
	cat "${PACKAGE_BUILD_LOG}"
	exit 1
fi

if ! clang \
	-std=c11 \
	-Wall -Wextra -Werror \
	-Iinclude \
	-Ilib/include \
	tests/cli/capi_compressed_icc_cross_oracle.c \
	"${PACKAGE_OUT}/lib/libjxlz_capi.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon) \
	-o "${OURS_BIN}" >"${OURS_BUILD_LOG}" 2>&1; then
	cat "${OURS_BUILD_LOG}"
	exit 1
fi

if [ ! -f "${UPSTREAM_BUILD_DIR}/lib/libjxl_extras_codec.a" ]; then
	rm -rf "${UPSTREAM_BUILD_DIR}"
	if ! cmake \
		-S . \
		-B "${UPSTREAM_BUILD_DIR}" \
		-G Ninja \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_TESTING=OFF \
		-DJPEGXL_ENABLE_TOOLS=ON \
		-DJPEGXL_ENABLE_DEVTOOLS=OFF \
		-DJPEGXL_ENABLE_BENCHMARK=OFF \
		-DJPEGXL_ENABLE_JPEGLI=OFF >"${UPSTREAM_CMAKE_LOG}" 2>&1; then
		cat "${UPSTREAM_CMAKE_LOG}"
		exit 1
	fi

	if ! cmake --build "${UPSTREAM_BUILD_DIR}" --target jxl_extras_codec -j2 >"${UPSTREAM_LIB_BUILD_LOG}" 2>&1; then
		cat "${UPSTREAM_LIB_BUILD_LOG}"
		exit 1
	fi
fi

if ! clang++ \
	-std=c++17 \
	-Wall -Wextra -Werror \
	-I"${UPSTREAM_BUILD_DIR}/lib/include" \
	-Ilib/include \
	-x c++ \
	tests/cli/capi_compressed_icc_cross_oracle.c \
	-x none \
	"${UPSTREAM_BUILD_DIR}/lib/libjxl_extras_codec.a" \
	"${UPSTREAM_BUILD_DIR}/lib/libjxl.a" \
	"${UPSTREAM_BUILD_DIR}/lib/libjxl_cms.a" \
	"${UPSTREAM_BUILD_DIR}/third_party/highway/libhwy.a" \
	$(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon lcms2 libpng zlib) \
	-o "${UPSTREAM_BIN}" >"${UPSTREAM_BUILD_LOG}" 2>&1; then
	cat "${UPSTREAM_BUILD_LOG}"
	exit 1
fi

if ! "${OURS_BIN}" profile >"${OURS_PROFILE}"; then
	exit 1
fi

if ! "${UPSTREAM_BIN}" profile >"${UPSTREAM_PROFILE}"; then
	exit 1
fi

if ! "${OURS_BIN}" compress >"${OURS_COMPRESSED}"; then
	exit 1
fi

if ! "${UPSTREAM_BIN}" compress >"${UPSTREAM_COMPRESSED}"; then
	exit 1
fi

if [ "$(wc -c <"${OURS_COMPRESSED}")" -ge "$(wc -c <"${OURS_PROFILE}")" ]; then
	echo "ours compressed ICC was not smaller than its source profile" >&2
	exit 1
fi

if [ "$(wc -c <"${UPSTREAM_COMPRESSED}")" -ge "$(wc -c <"${UPSTREAM_PROFILE}")" ]; then
	echo "upstream compressed ICC was not smaller than its source profile" >&2
	exit 1
fi

if ! "${OURS_BIN}" decompress <"${UPSTREAM_COMPRESSED}" >"${OURS_DECODED_UPSTREAM}"; then
	exit 1
fi

if ! "${UPSTREAM_BIN}" decompress <"${OURS_COMPRESSED}" >"${UPSTREAM_DECODED_OURS}"; then
	exit 1
fi

if ! cmp -s "${UPSTREAM_PROFILE}" "${OURS_DECODED_UPSTREAM}"; then
	echo "libjxlz failed to decode upstream compressed ICC stream" >&2
	exit 1
fi

if ! cmp -s "${OURS_PROFILE}" "${UPSTREAM_DECODED_OURS}"; then
	echo "upstream libjxl failed to decode libjxlz compressed ICC stream" >&2
	exit 1
fi
