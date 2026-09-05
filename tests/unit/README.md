# Upstream fixture generators

The C++ programs here use the retained upstream libjxl implementation as an
independent oracle. The generated Zig fixtures let `./test` run without building
upstream C++ or accessing the network.

Compile private API generators with the same build definitions as the upstream
static libraries. For the retained Release build, this includes `-DNDEBUG` and
`-fno-rtti`. `Fields` has a Debug-only virtual method; mismatched definitions
change its vtable layout and invalidate comparisons involving copied fields.

For example, inside `nix develop -c bash`, with `jxl_oracle_build` pointing to the
upstream Release build directory:

```bash
clang++ -std=c++17 -O2 -DNDEBUG -fno-rtti \
  -DJXL_INTERNAL_LIBRARY_BUILD -DJPEGXL_ENABLE_SKCMS=1 \
  -DJPEGXL_ENABLE_TRANSCODE_JPEG=1 -DJPEGXL_ENABLE_BOXES=1 \
  -I. -Ilib/include -Ithird_party/highway \
  -I"$jxl_oracle_build/lib/include" \
  tests/unit/reference_oracle.cc \
  "$jxl_oracle_build/lib/libjxl.a" \
  "$jxl_oracle_build/lib/libjxl_cms.a" \
  "$jxl_oracle_build/third_party/highway/libhwy.a" \
  $(pkg-config --libs libbrotlienc libbrotlidec libbrotlicommon lcms2) \
  -o "$TMPDIR/reference-oracle"
```

Run the generator separately after checking compilation succeeded. Capture its
output to a temporary file, verify its exit status and compare the fixture
before replacing the checked-in copy.

Assert that the encoder emitted the feature a fixture claims to cover. In
particular, the `ImageBundle` overload of `EncodeFrame` takes blend mode, origin,
duration and timecode from the bundle, overwriting those fields in `FrameInfo`.
The layer generators set the bundle fields and read back the encoded headers.
Requesting LZ77 also does not prove the encoder selected LZ77; the AC generator
asserts the actual emitted mode.

The Huffman generator compares every lookup-table entry and every possible
15-bit lookahead across nine trees. The blending, patch and reference generators
compare upstream pixels, with complete-frame checks through the public API.

`progressive_dc_oracle.cc` checks frame offsets, DC levels and dependency flags
before comparing displayed pixels. The public encoder produces levels 1/2.
For levels 3/4, the generator repeats 1x1 DC sections with rewritten headers;
the upstream decoder validates and renders the resulting complete streams.
It also verifies that all four missing-higher-reference variants are rejected.

`noise_oracle.cc` records eight upstream random-number seed cases and eight
noise-stage geometries, including narrow and partial groups. The complete
streams from `noise_frame_oracle.cc` cover modular/VarDCT, cropped layers,
all five blend modes, RGB/RGBA, 2x/8x upsampling and four-frame animations.
The generator inserts the 80-bit noise payload into otherwise upstream-encoded
frames, then reads their headers back and decodes every displayed frame with
upstream libjxl. Public tests compare all frames after rewind, reset and skip.
