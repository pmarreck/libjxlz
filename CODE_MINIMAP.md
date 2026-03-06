# Code Minimap

## Build Infrastructure
- `build.zig` — Zig build config: static lib + test step, ReleaseFast default
- `build.zig.zon` — Package manifest
- `flake.nix` — Nix dev shell, Garnix CI checks, package definition
- `build` — Bash: `nix develop -c zig build` with --test/--debug flags
- `test` — Bash: runs Zig unit tests + CLI tests, accumulates errors

## src/lib/
- `root.zig` — Module root, re-exports all submodules via refAllDecls

### src/lib/base/
- `status.zig` — StatusCode enum, JxlError error set, Status struct for FFI bridging
- `bits.zig` — CLZ, CTZ, floorLog2, ceilLog2 via @clz/@ctz builtins
- `common.zig` — Constants (pi, bits_per_byte), divCeil, roundUp, clamp, safeAdd
- `byte_order.zig` — Endian load/store for 16/32/64-bit ints and floats via std.mem
- `random.zig` — Xorshift128+ PRNG matching C++ jxl::Rng exactly
- `rect.zig` — Rect type for rectangular image regions with intersection/translate/shift
- `float.zig` — IEEE 754 float16 to f32 conversion
- `bit_reader.zig` — 64-bit buffered bitstream reader with deferred refill, bounds checking
- `pack_signed.zig` — PackSigned/UnpackSigned for zigzag encoding of signed frame offsets

### src/lib/entropy/
- `ans_params.zig` — ANS/prefix coding constants (tab size, max alphabet, signature)
- `ans_common.zig` — AliasTable struct with packed Entry, branchless Lookup, InitAliasTable, GetPopulationCountPrecision, CreateFlatHistogram
- `huffman.zig` — HuffmanCode struct, BuildHuffmanTable (2-level), HuffmanDecodingData with ReadFromBitStream/ReadSymbol, ReadSimpleCode
- `hybrid_uint.zig` — HybridUintConfig: split-exponent scheme for variable-length integers, encode/decode
- `inverse_mtf.zig` — Inverse move-to-front transform (scalar implementation)
- `dec_ans.zig` — ANSCode, ANSSymbolReader (ANS + Huffman + LZ77 + hybrid uint), LZ77Params, ReadHistogram, DecodeUintConfig, special distance table
- `dec_context_map.zig` — DecodeContextMap (simple path), VerifyContextMap

### src/lib/codec/
- `field_coders.zig` — U32Distr, U32Enc, U32Coder, U64Coder, F16Coder, BitsCoder read functions, readEnum, readExtensions, readAllDefault
- `frame_dimensions.zig` — Block/group constants (kBlockDim=8, kGroupDim=256), FrameDimensions struct with Set, GroupRect, BlockGroupRect, DCGroupRect
- `headers.zig` — SizeHeader (compact image dimensions), PreviewHeader, AnimationHeader readers; aspect ratio table
- `loop_filter.zig` — LoopFilter (Gaborish + EPF parameters) with full readFromBitStream, extension support
- `image_metadata.zig` — BitDepth, ExtraChannel enum, ExtraChannelInfo, ToneMapping, Orientation, ImageMetadata, CodecMetadata (ColorEncoding reading deferred)
- `color_encoding.zig` — ColorSpace, WhitePoint, Primaries, TransferFunction, RenderingIntent, Customxy, CustomTransferFunction, ColorEncoding with full readFromBitStream
- `frame_header.zig` — FrameEncoding, ColorTransform, FrameType, BlendMode, BlendingInfo, YCbCrChromaSubsampling, Passes, AnimationFrame, FrameHeader with full readFromBitStream
- `codestream_test.zig` — Integration test: parses real JXL codestream (SizeHeader + ImageMetadata + FrameHeader)

## docs/plans/
- `2026-03-06-libjxlz-design.md` — Overall project design document
- `2026-03-06-phase1-foundation.md` — Phase 1 implementation plan
