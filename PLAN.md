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
