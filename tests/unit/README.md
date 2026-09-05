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

`chroma_frame_oracle.cc` transcodes twelve JPEG inputs and asserts the actual
YCbCr mode and each component's sampling shifts before recording upstream RGB.
The six layouts are 4:4:4, 4:2:0, 4:2:2, 4:4:0, subsampled luma and asymmetric
chroma. The first six inputs are 13x9; the next are 257x17, 273x33, 2056x9,
17x273, 519x17 and 17x1. Inputs were encoded with ImageMagick 7.1.2-29 Q16-HDRI
(b919b37fd:20260727), JPEG quality 85. The pattern is `(13*x+3*y, 2*x+17*y,
7*x+11*y) mod 256`; sampling factors in JPEG component order are respectively
`1x1,1x1,1x1`, `2x2,1x1,1x1`, `2x1,1x1,1x1`, `1x2,1x1,1x1`,
`1x1,2x2,2x2`, `2x2,2x1,1x2`. Pass all twelve JPEG paths in order to the oracle.
It also emits an independently rejected subsampling/adaptive-DC-smoothing case.

`modular_chroma_oracle.cc` constructs the same six sampling layouts, explicitly
encodes their modular groups and reads back the emitted headers. Its final
geometry is 1x1. Both generators compare complete decoded output, with public
reset/rewind/uncoalesced checks, truncated prefixes and allocation sweeps.
`existing_chroma_oracle.cc` takes the existing small transcode and 1x1 metadata
container paths and records their upstream pixels for regression tests.

`spline_frame_oracle.cc` adds an upstream-encoded spline payload to independent
modular/VarDCT frames, preserving TOC permutation and byte alignment. The
generator reads back and asserts encoding, Gaborish, EPF, upsampling, spline
and noise flags, blend mode, crop origin and animation duration. It compares
all displayed pixels in 32 streams, including 2x/8x sampling and four-frame
animations. The 8x case uses a 65x65 canvas so both layers satisfy the spline
control-point limit after downsampling.
