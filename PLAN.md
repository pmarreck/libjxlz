# libjxlz Plan

## Phase 1: Foundation (complete)
- [x] build.zig + build.zig.zon — 2026-03-06 ~3:00 PM EST
- [x] ./build and ./test scripts — 2026-03-06 ~3:00 PM EST
- [x] flake.nix with Zig + Garnix — 2026-03-06 ~3:00 PM EST
- [x] status.zig — 2026-03-06 ~3:30 PM EST
- [x] bits.zig — 2026-03-06 ~3:30 PM EST
- [x] common.zig — 2026-03-06 ~3:30 PM EST
- [x] byte_order.zig — 2026-03-06 ~3:30 PM EST
- [x] random.zig — 2026-03-06 ~3:30 PM EST
- [x] rect.zig — 2026-03-06 ~3:30 PM EST
- [x] float.zig — 2026-03-06 ~3:30 PM EST
- [x] bit_reader.zig — 2026-03-06 ~3:45 PM EST
- [x] Project scaffolding (PLAN.md, IMPROVEMENTS.md, etc.) — 2026-03-06 ~3:50 PM EST
- [x] Final verification and commit

## Phase 2: Entropy Decoding (complete)
- [x] ans_params.zig — ANS/prefix coding constants
- [x] ans_common.zig — AliasTable, InitAliasTable, GetPopulationCountPrecision, CreateFlatHistogram
- [x] huffman.zig — HuffmanCode, BuildHuffmanTable, HuffmanDecodingData, ReadFromBitStream
- [x] hybrid_uint.zig — HybridUintConfig encode/decode with roundtrip tests
- [x] inverse_mtf.zig — Inverse move-to-front transform (scalar, SIMD noted for later)
- [x] dec_ans.zig — ANSCode, ANSSymbolReader, LZ77Params, ReadHistogram, DecodeUintConfig, decodeHistograms
- [x] dec_context_map.zig — DecodeContextMap (simple + ANS-coded non-simple path)
- [ ] Brotli integration (C FFI) — deferred to when needed by frame decoding

## Phase 3: Core Decoder (in progress)
- [x] field_coders.zig — U32Coder, U64Coder, F16Coder, BitsCoder, U32Enc/U32Distr
- [x] frame_dimensions.zig — FrameDimensions with block/group constants
- [x] headers.zig — SizeHeader, PreviewHeader, AnimationHeader readers
- [x] Frame header parsing (FrameHeader, enums, LoopFilter)
- [x] Image metadata (BitDepth, ExtraChannelInfo, ImageMetadata, CodecMetadata)
- [x] pack_signed.zig — PackSigned/UnpackSigned for frame origin encoding
- [x] ColorEncoding reading + ImageMetadata.readFromBitStream
- [x] Integration test: real codestream header parsing (201x251 sRGB lossless)
- [x] OpsinInverseMatrix + CustomTransformData + CodecMetadata wiring
- [x] Modular integer decoding (MA trees): ma_common, options, weighted, dec_ma, context_predict, transform, modular_image, encoding
- [x] Inverse transforms (RCT, Palette, Squeeze) — InvRCT, InvHSqueeze, InvVSqueeze, InvPalette, MetaSqueeze, MetaPalette
- [x] TOC reader + permutation decoding (Lehmer codes)
- [x] Frame-level decoding: FrameDecoder, ModularFrameDecoder, ModularStreamId, section dispatch
- [x] Re-enable strict failing test for `lossless_300x200` (removed temporary `catch return`) — 2026-03-06 ~6:55 PM EST
- [x] Add `PrecomputeReferences` path in `decodeModularChannel` for trees using reference properties — 2026-03-06 ~7:05 PM EST
- [x] Resolve 300x200 ANS final-state divergence in channel 0 (weighted predictor rounding parity via arithmetic right shift) — 2026-03-06 ~9:25 PM EST
- [x] Add strict runtime decode benchmark harness (`bench_decode_runtime.zig`) and baseline-vs-`djxl` corpus benchmark — 2026-03-06 ~8:45 PM EST
- [x] Improve benchmark harness for profiling fidelity (`--repeat`, preload inputs, `c_allocator`) and capture hotspot sample + LLVM IR dump — 2026-03-06 ~8:50 PM EST
- [x] Split modular decode between retained `reference` and compile-time-specialized ANS/LZ77 reader strategies; add parity test, benchmark switch, and `x86_64` compile check; specialized path measured ~2% faster on the 6-file modular corpus — 2026-03-06 ~9:05 PM EST
- [x] Add per-filtered-tree property-use planning so the modular general-case loop only materializes properties that the filtered MA tree can read — 2026-03-06 ~9:45 PM EST
- [x] Benchmark property-use planning against checkpoint `df498e70`; keep it because the 6-file corpus improved from 209.3 ms to 204.6 ms (`~1.02x`) and the large-only subset improved from 287.4 ms to 284.3 ms (`~1.01x`) — 2026-03-06 ~9:45 PM EST
- [x] Re-profile the modular decode hotspot stack and keep a Zig-level weighted predictor loop-unrolling pass because it improved the 6-file corpus from 209.9 ms to 207.5 ms and the large-only subset from 286.4 ms to 284.0 ms (`~1.01x` on both) while preserving `x86_64` ReleaseFast compilation — 2026-03-06 ~10:07 PM EST
- [x] Validate TOC section boundaries, propagate multi-section section-reader errors, and add exact-pixel + truncation regression coverage for a real 3-group grayscale frame (`lossless_600x10_multisection.jxl`) — 2026-03-06 ~11:20 PM EST
- [x] Reject unsupported DC-global patches/splines/noise flags explicitly and size modular YCbCr channels to their chroma-subsampled dimensions before group decode — 2026-03-06 ~11:25 PM EST
- [x] Tighten weak decode/frame/weighted tests to assert exact values instead of conditional/non-asserting behavior, and re-verify `x86_64-macos` compilation — 2026-03-06 ~11:30 PM EST
- [x] Re-benchmark after the multi-section fix and confirm the old large-corpus baseline was invalid because multi-group channels were not actually being decoded (`grad_2048_raw.jxl` old baseline ended at `pLast=0/0/0`) — 2026-03-06 ~11:35 PM EST
- [x] Add a committed large RGB multi-group fixture (`lossless_600x300_multigroup_rgb.jxl`) with exact boundary-pixel regression coverage and include it in reference-vs-specialized decode parity tests — 2026-03-07 ~12:10 AM EST
- [x] Harden `bench_decode_runtime.zig` with sampled image fingerprints, known-fixture checksum verification, and explicit checksum-print/skip-verification switches so benchmarks fail on partial or zero decodes — 2026-03-07 ~12:15 AM EST
- [x] Make `zig build test` run the benchmark harness tests in addition to the library unit/integration suite — 2026-03-07 ~12:20 AM EST
- [x] Re-profile the corrected multi-group modular path, reject three losing weighted-predictor micro-optimizations, and keep a low-risk scanline row-slice hoist in `decodeModularChannelImpl` because stricter benchmarks showed it improving both the 600x300 fixture and the full committed corpus by about `~1%` while preserving `x86_64-macos` compilation — 2026-03-07 ~1:35 AM EST
- [x] Add a dedicated weighted-predictor microbenchmark harness (`bench_weighted_predict.zig`) with a stable synthetic-workload checksum and include its tests in `zig build test` so predictor-only changes can be evaluated without full-frame decode noise — 2026-03-07 ~12:25 AM EST
- [x] Specialize the weighted predictor hot path for trees that do not read the WP error property: add tested `predictNoWPProp`, route the modular decode loop through it when `PropertyUsePlan` says property 15 is unused, and keep it because the checked-in public-API benchmark improved the large multigroup case from about `1.206 s` to `1.188 s` while staying slightly ahead on the full corpus — 2026-03-07 ~8:15 AM EST
- [x] Trim `decodeGroup` scratch/copy overhead by pre-reserving per-group channel storage and hoisting copy extents out of the row loop; keep it because the public-API benchmark stayed slightly ahead on the full corpus while remaining within noise of upstream on the large multigroup case, and re-verify `x86_64-macos` builds — 2026-03-07 ~8:25 AM EST
- [x] Re-profile filtered-tree shapes on the committed corpus, add tests for a no-reference property-mask classifier, and keep a narrow mask-specialized modular decode path for the dominant `WP` property sets because it improved the large multigroup public-API benchmark from about `1.187 s` to `1.155 s` while widening the full-corpus lead to about `1.04x` and preserving `x86_64-macos` compilation — 2026-03-07 ~8:35 AM EST
- [x] Compact the hot no-reference filtered MA trees into tiny local property-slot spaces, add remap regression tests for lookup equivalence and zero-sentinel preservation, and keep it because a direct A/B against checkpoint `9183091c` improved the large multigroup public-API benchmark from `1.162 s` to `1.140 s` (`~1.02x`) while staying slightly ahead on the full corpus (`75.0 ms -> 74.6 ms`) and preserving `x86_64-macos` compilation — 2026-03-07 ~9:50 AM EST
- [x] Re-encode remapped no-reference mask trees into an inline compact node layout, add lookup-equivalence and small-storage fallback tests, and keep it because a direct A/B against checkpoint `9bfc415e` improved the large multigroup public-API benchmark from `1.139 s` to `1.084 s` (`~1.05x`) and the full corpus from `74.4 ms` to `72.1 ms` (`~1.03x`) while preserving `x86_64-macos` compilation — 2026-03-07 ~10:05 AM EST
- [ ] Generalize the MA-tree LUT fast path beyond `gradient_only` / `wp_only`, starting with any filtered tree that reads exactly one non-reference property
- [x] End-to-end lossless decode test (real JXL → exact pixel data) — 2026-03-06 ~11:20 PM EST
- [x] Multi-group frame decoding verification — 2026-03-06 ~11:20 PM EST

## Phase 4: Render Pipeline
- [ ] Inverse DCT (SIMD)
- [ ] Color transforms (XYB)
- [ ] Upsampling, noise, blending
- [ ] Pipeline assembly

## Phase 5: Decode API + CLI
- [x] Migrate the repo’s working/default branch from `main` to `yolo` in the safe two-branch form: create and push `yolo`, switch GitHub’s default branch, and retarget the checked-in GitHub Actions workflow + README badge so CI follows `yolo` instead of the old branch name — 2026-03-07 ~2:25 PM EST
- [x] First `libjxl`-shaped decoder C FFI compatibility slice: `JxlSignatureCheck`, `JxlDecoder{Create,Reset,Destroy,SubscribeEvents,SetInput,ReleaseInput,CloseInput,GetBasicInfo,ImageOutBufferSize,SetImageOutBuffer,ProcessInput}` with real external C smoke decode of `lossless_4x4.jxl` via upstream `jxl/decode.h` — 2026-03-07 ~11:10 AM EST
- [x] Add `djxlz`, a C CLI that dogfoods only the public C FFI, with `--help`, `--about`, `--output_format`, stdin/stdout path aliases, debug-build warning, and PPM/PGM/PAM output verified by CLI smoke tests — 2026-03-07 ~7:15 AM EST
- [x] Check in a permanent public-API decode benchmark harness (`tests/benchmark/decode_public_api.c`) plus `./bm`, compile it against both `libjxlz_capi` and upstream `libjxl`, log benchmark history, and add a deterministic checksum smoke test — 2026-03-07 ~7:30 AM EST
- [x] Optimize the common C-API `UINT8` output path (RGB and grayscale expansion) and fix correct 8-bit scaling for high-bit-depth input; public-API benchmarks improved from `80.8 ms -> 76.2 ms` on the full corpus and `1.294 s -> 1.206 s` on the large multigroup case, reaching parity/slight lead vs upstream in the checked-in harness — 2026-03-07 ~7:40 AM EST
- [x] Add a repo-specific GitHub Actions workflow (`libjxlz_ci.yml`), keep Garnix on the existing flake checks, and update the README with repo-owned CI badges plus an upstream-facing optimization note and honest current project status — 2026-03-07 ~10:20 AM EST
- [x] Remove inherited upstream GitHub workflows so Actions only reports repo-owned `libjxlz CI` plus Garnix for this fork, instead of unrelated upstream C++/Pages/CodeQL jobs failing on every push — 2026-03-07 ~11:15 AM EST
- [x] Add a `NOTICE` file plus README attribution note clarifying that `libjxlz` is a derived Zig rewrite of `libjxl`, not a clean-room implementation, and that upstream/new material keep their respective credit — 2026-03-07 ~11:20 AM EST
- [x] Add the first encoder-side benchmark/profiling scaffold (`bench_modular_encode_prep.zig`) for modular predictor selection plus hybrid-uint tokenization, wire it into `zig build test`, `./test`, and `./bm`, and log the initial baseline (`1024x768x3`, repeat `24`: `1.1987 s`) — 2026-03-07 ~11:20 AM EST
- [x] Fix Linux CI for the encoder scaffold by keeping it pure-library (no `capi_root` import leak) and adding an `x86_64-linux` compile-only smoke check so `./test` catches libc-linkage regressions before push — 2026-03-07 ~11:30 AM EST
- [x] Add `x86_64-windows-gnu` compile-only coverage via a checked-in smoke test, wire it into `./test`, and expose it through the Linux flake checks so both GitHub Actions and Garnix catch Windows portability regressions early — 2026-03-07 ~12:05 PM EST
- [x] Investigate `bad_conversion_samples/*` producing apparently black JPEG XL outputs via the external `jpegxl` wrapper / `cjxl`; confirm the files are valid, `djxl`/`sips`/Preview decode them correctly, and narrow the black-screen issue to Finder Quick Look on grayscale JXL rather than a core encoder/decoder bug — 2026-03-07 ~12:35 PM EST
- [ ] Conformance tests

## Phase 6: Encoder
- [ ] Forward DCT + quantization
- [ ] ANS encoder
- [x] ANS encoder slice: add `encodeUintConfig(s)` using the new `BitWriter`, with mixed and exhaustive roundtrip coverage against `dec_ans.decodeUintConfigs`, so the entropy writer can emit real HybridUint metadata before full histogram/token support exists — 2026-03-07 ~2:10 PM EST
- [x] ANS encoder slice: add `storeVarLenUint8/16` with exhaustive roundtrip coverage against the decoder-side varlen readers, so histogram-header metadata can be written and unit-tested independently before larger ANS assembly work — 2026-03-07 ~2:20 PM EST
- [ ] Modular encoder
- [x] Encoder bit-writer foundation: add `src/lib/base/bit_writer.zig` with LSB-first write + byte-pad semantics and roundtrip it against the existing `BitReader`, so future ANS/modular writer work has a real writable primitive instead of the synthetic prepass scaffold alone — 2026-03-07 ~1:55 PM EST
- [ ] Replace synthetic encoder-prepass scaffold with real modular encoder profiling once the first writable bitstream slice exists
- [ ] Frame encoder
- [ ] Fast lossless encoder
- [ ] C FFI encode API
- [ ] cjxlz CLI
- [x] Encoder perf follow-up option 1: extend `bench_weighted_predict.zig` with explicit `generic_null_props` vs `no_props` modes, add parity + stable-checksum coverage for the encoder-side `predictNoProps` path, and benchmark the two callsites; the longer `600x300 repeat=256` run came out essentially at parity, so the real win here is cleaner measurement rather than a kept speedup — 2026-03-07 ~12:45 PM EST
- [x] Encoder perf follow-up option 2: add `instrumented|minimal` bookkeeping modes to `bench_modular_encode_prep.zig`, keep the fully checked path for regression tests, log both scenarios in `./bm`, and keep it because the new `modular_encode_prep_minimal` scenario measured about `1.20x` faster than the instrumented path on `1024x768x3 repeat=24` while preserving identical sample and bit-count totals — 2026-03-07 ~1:30 PM EST
- [ ] Encoder perf follow-up option 3: start the first real modular writer slice and shift future optimization work from the synthetic scaffold to true bitstream-writing hot paths

## Phase 7: Extras
- [ ] JPEG recompression (jpegli)
- [ ] jxltranz transcoder
- [ ] Butteraugli / SSIMULACRA metrics
