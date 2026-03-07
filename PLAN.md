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
- [ ] Generalize the MA-tree LUT fast path beyond `gradient_only` / `wp_only`, starting with any filtered tree that reads exactly one non-reference property
- [x] End-to-end lossless decode test (real JXL → exact pixel data) — 2026-03-06 ~11:20 PM EST
- [x] Multi-group frame decoding verification — 2026-03-06 ~11:20 PM EST

## Phase 4: Render Pipeline
- [ ] Inverse DCT (SIMD)
- [ ] Color transforms (XYB)
- [ ] Upsampling, noise, blending
- [ ] Pipeline assembly

## Phase 5: Decode API + CLI
- [ ] C FFI decode API
- [ ] djxlz CLI
- [ ] Conformance tests

## Phase 6: Encoder
- [ ] Forward DCT + quantization
- [ ] ANS encoder
- [ ] Modular encoder
- [ ] Frame encoder
- [ ] Fast lossless encoder
- [ ] C FFI encode API
- [ ] cjxlz CLI

## Phase 7: Extras
- [ ] JPEG recompression (jpegli)
- [ ] jxltranz transcoder
- [ ] Butteraugli / SSIMULACRA metrics
