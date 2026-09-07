# Preview controls

`tests/cli/capi_preview.c` runs unchanged against upstream libjxl and the
installed native C archive. Its inline stream has a 1x1 red preview and a
2x2 main image with RGB components 0, 10, ..., 110. The retained coverage
probe assembled the stream from independently encoded frame bodies and a
header declaring the preview. Upstream decoding verifies both frame bodies,
ordering, dimensions and exact pixels.

The C check covers preview and main events, separate output buffers, a short
preview buffer, rewind/reset, channel counts {0, 1, 2, 3, 4, 5, UINT32_MAX},
row alignment, preserved padding and guard bytes, and rejection of a preview
buffer without a preview subscription. A size query before the basic header
returns NEED_MORE_INPUT; this is observed upstream behavior.

`src/capi/preview_test.zig` also checks strict validation, ordinary main-image
output without preview events, and a 2x2 preview preceding a 1x1 main image.
The larger preview control was decoded through both upstream output buffers;
it prevents the main image's pixel count from bypassing the preview limit.
`src/capi/pixel_format.zig` tests checked row-stride arithmetic independently
of a decoder allocation.

To run the external C control against a retained upstream build:

```bash
# Set preview_oracle_build to the upstream build directory.
nix develop -c clang++ -std=c++17 -O2 \
  -Ilib/include -I"$preview_oracle_build/lib/include" \
  -x c++ tests/cli/capi_preview.c -x none \
  "$preview_oracle_build/lib/libjxl.a" \
  "$preview_oracle_build/lib/libjxl_cms.a" \
  "$preview_oracle_build/third_party/highway/libhwy.a" \
  -lbrotlienc -lbrotlidec -lbrotlicommon -llcms2 \
  -o "$TMPDIR/libjxlz-preview-oracle"
"$TMPDIR/libjxlz-preview-oracle"
```

These fixtures cover small RGB Modular previews. They do not establish
coverage of every preview encoding, color profile or orientation. The upstream
oracle remains useful for expanding those controls.

## Native encoder output

A requested preview now emits a real Modular frame before the main image, or
before the first animation frame. It samples the first source image with
nearest-neighbor scaling, including alpha and subsampled extra planes. The
main images retain their original samples. A preview request previously wrote
only dimensions; the actual-preview decoder exposed that invalid stream.

The encoded-preview unit tests check actual preview pixels, two animation
frames, 16-bit RGB/alpha, subsampled depth, and every encoder allocation failure
on a small preview. The failure sweep found and fixed existing ownership gaps
when growing the source-channel list and partially building ANS reverse maps.

`tests/cli/capi_encode_preview.sh` emits static and animated streams, checks
both outputs, and passes them to `tests/cli/encoded_preview_decode.c`. That
reader also passed when linked to the pinned upstream library. The generator
accepts an output filename and an optional `animation` argument; the reader
accepts the filename and an optional expected frame count (default 1).
