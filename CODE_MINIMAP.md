# Code Minimap

## Build Infrastructure
- `README.md` — top-level project status, current measured wins vs upstream `libjxl`, threading status, build/benchmark entrypoints, encoder scaffold status, attribution note, and links to upstream-facing optimization notes
- `NOTICE` — non-clean-room derivative-work attribution note describing upstream `libjxl` lineage, mixed copyright ownership, and the BSD-3-Clause + PATENTS licensing surface for this fork
- `.github/workflows/libjxlz_ci.yml` — repo-specific GitHub Actions workflow running on pushes to `yolo` and pull requests, with Linux `x86_64` flake/full-suite checks plus native `aarch64` test runs on Linux and macOS; the Linux flake checks also cover `x86_64-windows-gnu` cross-compilation, and this is intentionally the only checked-in GitHub Actions workflow so fork CI reflects `libjxlz`, not upstream `libjxl`
- `build.zig` — Zig build config: core static lib (`lib`), C-FFI static lib (`capi`), ReleaseFast default; `zig build test` now runs the core library tests, both benchmark harness tests, and the C-FFI unit tests
- `build.zig.zon` — Package manifest
- `flake.nix` — Nix dev shell, Garnix CI checks, package definition; Linux `x86_64` flake checks now include a dedicated `windows-x86_64-cross` derivation that reuses the checked-in smoke script so Garnix catches Windows portability regressions too
- `build` — Bash: `nix develop -c zig build` with --test/--debug flags
- `test` — Bash: runs Zig unit tests + CLI tests, including the encoder-prepass smoke compile/run, and accumulates errors
- `bm` — Bash: builds the public-API decode benchmark harness against both `libjxlz_capi` and upstream `libjxl`, builds the synthetic encoder-prepass harness in ReleaseFast, runs `hyperfine` on both decode and encoder scenarios (now both `modular_encode_prep_best` and `modular_encode_prep_minimal`), appends results to the source-controlled history TSVs, and fails loudly on >5% shifts from the previous logged run
- `include/jxl/jxl_export.h` / `include/jxl/version.h` — generated-support compatibility headers so the upstream public `jxl/*.h` headers in `lib/include` can be used directly by external C consumers and tests
- `bench_decode_runtime.zig` — Runtime decode benchmark harness (`--repeat`, `--reader reference|specialized`, preloaded inputs, full frame decode) with sampled image fingerprints plus known-fixture checksum verification (`--no-verify-known`, `--print-checksum`) so benchmarking catches partial/zero decodes instead of timing them
- `bench_weighted_predict.zig` — Synthetic weighted-predictor microbenchmark (`--repeat`, `--width`, `--height`, `--mode generic_null_props|no_props`) that now compares the generic null-properties callsite against the encoder-style `predictNoProps` path, with stable checksums and parity coverage before predictor-only changes are tried in full-frame decode
- `bench_modular_encode_prep.zig` — Synthetic encoder-side modular prepass harness: generates deterministic image planes, sweeps predictors per pixel, picks the minimum-absolute-residual predictor, tokenizes packed residuals with `HybridUintConfig`, now supports `--bookkeeping instrumented|minimal` so `./bm` can compare the checked/profiler-friendly path with a less instrumented fast path before a real modular writer exists
- `tests/cli/capi_decode.c` / `tests/cli/capi_decode.sh` — external C smoke test that compiles against the real upstream `jxl/decode.h`, links `libjxlz_capi.a`, and decodes the 4x4 fixture through the public `JxlDecoder` flow
- `tests/benchmark/decode_public_api.c` — checked-in in-memory public-API benchmark harness in C; loads inputs once, reuses `JxlDecoder` + output storage across repeats, decodes through `JxlDecoder` only, and hashes RGB output for deterministic correctness checks
- `tests/benchmark/public_api_decode_history.tsv` — source-controlled benchmark history for the public-API harness (`./bm`)
- `tests/benchmark/modular_encode_prep_history.tsv` — source-controlled timing history for the synthetic encoder prepass benchmark run by `./bm`, now tracking both the fully instrumented and minimal-bookkeeping scenarios
- `tests/cli/capi_bench_smoke.sh` — checksum smoke test proving the checked-in public-API benchmark harness compiles and decodes deterministically against `libjxlz_capi`
- `tests/cli/encode_prep_bench_smoke.sh` — checksum smoke test proving the encoder prepass harness compiles in ReleaseFast, also cross-compiles cleanly for `x86_64-linux`, and produces the expected deterministic checksums for both the instrumented and minimal bookkeeping modes
- `tests/cli/windows_cross_compile_smoke.sh` — compile-only portability smoke test for `x86_64-windows-gnu`; cross-builds the pure Zig library, C API, `djxlz`, and encoder scaffold so `./test`, Linux Actions, and Garnix all catch Windows regressions before runtime support exists

## src/
- `root.zig` — package root for the pure Zig library, re-exporting the core `src/lib` modules plus the C-FFI module for test discovery
- `capi_root.zig` — `libjxl`-shaped decoder compatibility layer exporting the first public C decoder slice (`JxlSignatureCheck`, `JxlDecoder*` create/input/basic-info/output/decode flow) by reusing the existing Zig decode pipeline and converting into caller-owned interleaved buffers; now includes tested `UINT8` fast paths for RGB/gray output and correct 8-bit scaling from higher source bit depths
- `src/cli/djxlz_root.zig` / `src/cli/djxlz.c` — C CLI entrypoint and implementation for `djxlz`, which dogfoods the public `JxlDecoder` API exclusively and writes PPM/PGM/PAM to files or stdio targets

## src/lib/
- `lib/root.zig` — core module root, re-exports all submodules via refAllDecls
- `testdata/` — Committed raw codestream fixtures used by decode integration tests, including a real 3-group grayscale frame (`lossless_600x10_multisection.jxl`) for validated multi-section dispatch/truncation coverage and a real 6-group RGB frame (`lossless_600x300_multigroup_rgb.jxl`) for large multi-group boundary/pixel coverage

### src/lib/base/
- `status.zig` — StatusCode enum, JxlError error set, Status struct for FFI bridging
- `bits.zig` — CLZ, CTZ, floorLog2, ceilLog2 via @clz/@ctz builtins
- `common.zig` — Constants (pi, bits_per_byte), divCeil, roundUp, clamp, safeAdd
- `byte_order.zig` — Endian load/store for 16/32/64-bit ints and floats via std.mem
- `random.zig` — Xorshift128+ PRNG matching C++ jxl::Rng exactly
- `rect.zig` — Rect type for rectangular image regions with intersection/translate/shift
- `float.zig` — IEEE 754 float16 to f32 conversion
- `bit_reader.zig` — 64-bit buffered bitstream reader with deferred refill, bounds checking
- `bit_writer.zig` — first encoder-side writable primitive: LSB-first bit packing with byte-padding semantics matching `BitReader`, proven by direct roundtrip tests and intended as the foundation for upcoming ANS/modular writer work
- `pack_signed.zig` — PackSigned/UnpackSigned for zigzag encoding of signed frame offsets

### src/lib/entropy/
- `ans_params.zig` — ANS/prefix coding constants (tab size, max alphabet, signature)
- `ans_common.zig` — AliasTable struct with packed Entry, branchless Lookup, InitAliasTable, GetPopulationCountPrecision, CreateFlatHistogram
- `huffman.zig` — HuffmanCode struct, BuildHuffmanTable (2-level), HuffmanDecodingData with ReadFromBitStream/ReadSymbol, ReadSimpleCode
- `hybrid_uint.zig` — HybridUintConfig: split-exponent scheme for variable-length integers, encode/decode
- `inverse_mtf.zig` — Inverse move-to-front transform (scalar implementation)
- `dec_ans.zig` — ANSCode, ANSSymbolReader (ANS + Huffman + LZ77 + hybrid uint), LZ77Params, ReadHistogram, public decoder-side varlen uint helpers for histogram metadata, DecodeUintConfig, special distance table, retained generic read path plus compile-time-specialized clustered uint readers, decodeHistograms (top-level)
- `enc_ans.zig` — first encoder-side entropy-writing foundations: generic `encodeUintConfig(s)` and `storeVarLenUint8/16`, `SizeWriter`, `Token`, `ANSEncSymbolInfo`, an alias-table-backed ANS info-table builder, `ANSCoder.putSymbol`, minimal one-context degenerate/two-symbol/flat histogram metadata writers for `decodeHistograms`, and a minimal single-histogram token-stream writer; tests prove metadata roundtrips, exact bit-count agreement, ANS state-update correctness, recovered histogram frequencies via alias tables, and decoder roundtrip of both histogram metadata and direct/extra-bit token streams
- `enc_context_map.zig` — first encoder-side multi-context metadata helper, currently just the simple all-zero context-map writer (`is_simple=1`, `bits_per_entry=0`) with a decoder roundtrip test through `decodeContextMap`; intended as the smallest stepping stone toward MA-tree histogram/context-map emission
- `dec_context_map.zig` — DecodeContextMap (simple + ANS-coded non-simple path), VerifyContextMap

### src/lib/codec/
- `field_coders.zig` — U32Distr, U32Enc, U32Coder, U64Coder, F16Coder, BitsCoder read functions, readEnum, readExtensions, readAllDefault
- `frame_dimensions.zig` — Block/group constants (kBlockDim=8, kGroupDim=256), FrameDimensions struct with Set, GroupRect, BlockGroupRect, DCGroupRect
- `headers.zig` — SizeHeader (compact image dimensions), PreviewHeader, AnimationHeader readers; aspect ratio table
- `loop_filter.zig` — LoopFilter (Gaborish + EPF parameters) with full readFromBitStream, extension support
- `image_metadata.zig` — BitDepth, ExtraChannel enum, ExtraChannelInfo, ToneMapping, Orientation, ImageMetadata, CodecMetadata, OpsinInverseMatrix, CustomTransformData
- `color_encoding.zig` — ColorSpace, WhitePoint, Primaries, TransferFunction, RenderingIntent, Customxy, CustomTransferFunction, ColorEncoding with full readFromBitStream
- `frame_header.zig` — FrameEncoding, ColorTransform, FrameType, BlendMode, BlendingInfo, YCbCrChromaSubsampling, Passes, AnimationFrame, FrameHeader with full readFromBitStream
- `toc.zig` — TOC reading (section sizes + Lehmer-coded permutation via ANS), numTocEntries, acGroupIndex, `computeGroupOffsets` for validated section-layout construction
- `enc_toc.zig` — first encoder-side frame-shell helper, currently just the no-permutation TOC writer with roundtrip coverage through `toc.readToc`; intended as the size/section-layout foundation for minimal frame wrappers
- `enc_frame.zig` — encoder-side frame-shell helpers: exact-bit-tested native `writeFrameHeader` for the current simple modular grayscale/RGB surface, `writeFrame` for native frame assembly, and the older borrowed-header helper retained while broader header coverage is still incomplete
- `enc_codestream.zig` — first encoder-side full codestream wrapper, currently built around a real raw `SizeHeader` writer plus borrowed metadata bits and the native `enc_frame.writeFrame` path; includes full borrowed-metadata codestream roundtrips through header parsing and `FrameDecoder.decodeFrame` for both grayscale and RGB
- `dec_frame.zig` — FrameDecoder (frame header + validated TOC section layout + exact section slicing + error-propagating dispatch in `decodeFrameWithReaderStrategy`), ModularFrameDecoder (`decodeGlobalInfoWithReaderStrategy`, explicit unsupported-feature rejection, YCbCr chroma-channel sizing, global tree + per-group decode with pre-reserved scratch channel storage and copy-width/copy-height hoisted out of the row loop in `decodeGroup`), ModularStreamId
- `codestream_test.zig` — Integration test: parses real JXL codestream (SizeHeader + ImageMetadata + FrameHeader)
- `decode_test.zig` — End-to-end lossless decode tests for small/single-section and real multi-section codestreams, including exact sampled-pixel coverage for the committed 600x300 RGB multi-group fixture, truncated-frame failure coverage, and reference-vs-specialized parity over the committed corpus

### src/lib/modular/
- `ma_common.zig` — MATreeContext enum (6 contexts), kMaxTreeSize, kNumTreeContexts
- `options.zig` — Predictor enum (14 decoders + 2 encoder-only), pixel_type, PropertyVal, ModularOptions
- `weighted.zig` — Weighted predictor Header (7 coefficients + 4 weights) reading, State (predict + updateErrors with division-free approximation, fixed-4 loops forced to `inline for` after hotspot profiling, plus tested `predictNoProps` / `predictNoWPProp` specializations so decode can skip dead WP-property work)
- `dec_ma.zig` — PropertyDecisionNode, Tree, DecodeTree (reads own ANS histograms, decodes nodes, validates height/ranges)
- `enc_ma.zig` — first encoder-side MA-tree writer, currently just the smallest single-leaf tree surface (shared histogram, zero offset, multiplier 1) with a roundtrip test through `dec_ma.decodeTree`; intended as the bridge from histogram/context primitives to real local-tree modular groups
- `context_predict.zig` — ClampedGradient, Select, PredictOne (14 predictors), FlatDecisionNode, MATreeLookup, FilterTree (static property elimination + tree flattening), `PropertyUsePlan` (tracks exactly which dynamic properties survive filtering so decode can skip unused per-pixel materialization)
- `transform.zig` — TransformId (RCT/Palette/Squeeze), SqueezeParams, Transform reading; InvRCT (42 variants), InvHSqueeze, InvVSqueeze, InvPalette, SmoothTendency; MetaSqueeze, MetaPalette, DefaultSqueezeParameters; undoTransforms, metaApply
- `modular_image.zig` — Channel (2D pixel storage with row/shrink access), Image (multi-channel container with transforms)
- `enc_encoding.zig` — first modular encoder tokenization/writing slice: converts single-node non-weighted predictor channels into packed residual `Token`s, feeds them into the encoder-side ANS writer, can emit the smallest real global-tree group plus fully local-tree groups for both single-channel grayscale and small multi-channel RGB images using flat one-context channel histograms, and includes exact token assertions plus `modularDecode`-level roundtrip tests for `.zero` and `.gradient` local-tree paths
- `encoding.zig` — GroupHeader reading, ModularDecode/ModularGenericDecompress with retained `ReaderStrategy.reference` path and compile-time-specialized hot-path dispatch for per-channel decoding with WP/reference properties + sparse property/reference materialization driven by `PropertyUsePlan` + narrow no-reference property-mask specializations for the dominant filtered-tree `WP` masks, now with filtered-tree property IDs remapped into tiny local slot spaces and optional inline compact-node MA-tree lookup for the hot no-reference trees + scanline-hoisted top-row slices in the inner pixel loop + `predictNoWPProp` routing when the filtered tree does not consume WP property 15 + MetaApply + transform undo

## docs/plans/
- `doc/upstream_optimization_notes.md` — upstream-facing summary of kept decode optimizations, including which wins are portable back to C/C++, where Zig aided specialization/layout work, and where Zig still has tradeoffs
- `2026-03-06-libjxlz-design.md` — Overall project design document
- `2026-03-06-phase1-foundation.md` — Phase 1 implementation plan
