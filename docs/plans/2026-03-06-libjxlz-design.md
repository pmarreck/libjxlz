# libjxlz Design Document

**Date:** 2026-03-06
**Status:** Approved

## Goal

Rewrite the libjxl JPEG XL reference implementation in Zig (`libjxlz`), producing a faster, cleaner implementation that:

- Passes all existing libjxl conformance and interop tests
- Maintains a C FFI as the public API surface
- Provides C CLI tools (`cjxlz`, `djxlz`, `jxltranz`) that dogfood the FFI
- Includes benchmarks proving performance improvements over the original

## Approach

**Transliterative port** — translate the existing C++ module-by-module into idiomatic Zig, preserving proven algorithms but restructuring for Zig's strengths. Do NOT optimize inline during translation; instead log improvement opportunities in `IMPROVEMENTS.md` for a later pass.

## Architecture

```
cjxlz / djxlz (C CLI)
        |
    C FFI boundary (lib/include/jxl/*.h — same API surface as original)
        |
    Zig core (pure logic, no I/O)
        |
    Zig @Vector SIMD (replaces Highway)
```

Key architectural principles:
- All business logic in Zig core, no I/O
- C FFI is the real public API — CLI dogfoods it
- Zig CLI does NOT import Zig core directly (C FFI must be exercised)
- `@Vector` + comptime replaces Highway's runtime SIMD dispatch
- `std.testing` replaces googletest
- Arena/page allocators where C++ used RAII

## SIMD Strategy

Translate Highway `*-inl.h` files to Zig `@Vector` operations during the port (faithful translation of the same algorithms). Note comptime dispatch optimization opportunities for later.

15 Highway inline headers to translate:
- `convolve-inl.h`, `dct-inl.h`, `dct_block-inl.h`
- `dec_transforms-inl.h`, `dec_xyb-inl.h`
- `enc_transforms-inl.h`
- `fast_math-inl.h`, `rational_polynomial-inl.h`
- `inverse_mtf-inl.h`, `quantizer-inl.h`
- `simd_util-inl.h`, `tone_mapping-inl.h`
- `transfer_functions-inl.h`, `transpose-inl.h`
- `xorshift128plus-inl.h`

## Dependencies

| Dependency | Initial Strategy | Source | Later |
|---|---|---|---|
| Brotli | C via build.zig | `zig-pkg/brotli` | Evaluate pure Zig |
| Highway | Replace with `@Vector` | Inline translation | Comptime dispatch opt |
| lcms2/skcms | C FFI | Fork + add build.zig | Evaluate pure Zig |
| libjpeg-turbo | C via build.zig | `chearon/libjpeg-turbo` | Keep as-is |
| libpng | C FFI | Fork + add build.zig | Keep as-is |
| zlib | C via build.zig | `andrewrk/libz` | Keep as-is |
| googletest | Replace with `std.testing` | N/A | N/A |

## Porting Order

Decoder-first, bottom-up. Each layer gets tests before moving to the next.

### Phase 1: Foundation
1. `lib/jxl/base/` — bit reader, status codes, memory utilities, math
2. Build infrastructure — `build.zig`, `flake.nix`, `./build`, `./test`, `./bm`

### Phase 2: Entropy Decoding
3. ANS (asymmetric numeral systems) decoder
4. Huffman decoder
5. Brotli integration (via C FFI)

### Phase 3: Core Decoder
6. Frame header parsing
7. Group decoding
8. Modular integer decoding (MA trees)
9. Context map decoding

### Phase 4: Render Pipeline
10. DCT (inverse discrete cosine transform) — first major SIMD translation
11. Color transforms (XYB to linear, tone mapping)
12. Upsampling, noise, blending
13. Render pipeline assembly

### Phase 5: Decode API + CLI
14. Public C FFI decode API (`JxlDecoder*` functions)
15. `djxlz` CLI tool
16. Conformance test validation against reference test vectors

### Phase 6: Encoder
17. Forward DCT + quantization
18. ANS encoder
19. Modular encoder (MA tree construction)
20. Frame encoder
21. Fast lossless encoder (`enc_fast_lossless`)
22. Public C FFI encode API (`JxlEncoder*` functions)
23. `cjxlz` CLI tool

### Phase 7: Extras
24. JPEG recompression (jpegli integration)
25. `jxltranz` transcoder
26. Butteraugli / SSIMULACRA quality metrics

## Benchmarking

`./bm` runs `hyperfine` comparing original vs Zig implementations:

- **Decode speed**: `djxl` vs `djxlz` across test corpus
- **Encode speed**: `cjxl` vs `cjxlz` at multiple quality levels
- **Compression ratio**: byte-for-byte output comparison
- **Memory usage**: peak RSS comparison

Results logged to `benchmarks/` with timestamps for tracking over time. Benchmark suite asserts no "DEBUG BUILD" text is present.

Test corpus: libjxl conformance test images + a curated set of real-world photos at various resolutions.

## File Layout

```
libjxlz/
  build.zig
  build.zig.zon
  flake.nix
  build              # Bash: nix develop -c zig build ...
  test               # Bash: runs all test suites
  bm                 # Bash: benchmarks via hyperfine
  PLAN.md
  IMPROVEMENTS.md    # "Note for later" optimization log
  CODE_MINIMAP.md
  PROJECT_OVERVIEW.md
  src/
    lib/              # Zig core library (pure, no I/O)
      base/           # Bit reader, math, status, memory
      entropy/        # ANS, Huffman
      modular/        # MA trees, modular encoding
      frame/          # Frame parsing, group decoding
      render/         # DCT, color, upsampling, pipeline
      codec.zig       # Top-level encoder/decoder state machines
    ffi/              # C FFI exports
      decode.zig      # JxlDecoder* C API
      encode.zig      # JxlEncoder* C API
    simd/             # @Vector translations of Highway ops
  include/jxl/        # C headers (same API as original)
  cli/                # C CLI sources
    cjxlz.c
    djxlz.c
    jxltranz.c
  tests/
    unit/             # Zig std.testing tests
    integration/      # Round-trip encode/decode tests
    cli/              # Bash CLI tests
    conformance/      # Reference test vector validation
  benchmarks/         # Performance logs
```

## Success Criteria

1. `djxlz` decodes all libjxl conformance test vectors correctly
2. `cjxlz` produces files that `djxl` (original) can decode correctly
3. `djxlz` decodes files produced by `cjxl` (original) correctly
4. Benchmarks show measurable speed improvement on at least encode OR decode
5. All tests pass, build is green on Garnix CI
6. Single static binary output (no runtime deps beyond libc)
