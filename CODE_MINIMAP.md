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

## docs/plans/
- `2026-03-06-libjxlz-design.md` — Overall project design document
- `2026-03-06-phase1-foundation.md` — Phase 1 implementation plan
