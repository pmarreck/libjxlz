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
- [ ] Generalize the MA-tree LUT fast path beyond `gradient_only` / `wp_only`, starting with any filtered tree that reads exactly one non-reference property
- [ ] End-to-end lossless decode test (real JXL → pixel data)
- [ ] Multi-group frame decoding verification

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
