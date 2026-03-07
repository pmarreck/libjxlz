# Upstream Optimization Notes

This document summarizes the decode-side optimizations that were kept in
`libjxlz` after correctness checks, direct A/B benchmarking, and regression
tests. It is intended to be useful to upstream `libjxl` maintainers and to make
clear which improvements are language-independent versus merely easier to express
in Zig.

## Ground Rules

- Only kept changes are listed here. Losing or noise-level experiments were
  reverted.
- The benchmark basis is the checked-in public C API harness in `./bm`, which
  compares `libjxlz_capi` against upstream `libjxl` using the same C harness and
  the same committed fixture corpus.
- The most meaningful current scenario is the large modular multigroup fixture:
  `src/lib/testdata/lossless_600x300_multigroup_rgb.jxl`.

## Kept Improvements

### 1. Skip unused modular properties after MA-tree filtering

What changed:
- After static tree pruning, `libjxlz` records which dynamic properties are
  still reachable and only materializes those in the decode loop.

Why it helps:
- Reduces per-pixel property writes and reference-property precomputation that
  the filtered tree can never read.

Why upstream might care:
- This is algorithmic dead-work elimination, not a Zig-specific trick.
- It should be portable to C/C++.

### 2. Specialize weighted prediction when WP property 15 is unused

What changed:
- Added a `predictNoWPProp` path so weighted prediction can run without also
  computing/storing the WP error property when the filtered tree does not
  consult it.

Why it helps:
- Removes work from the hottest inner loop on trees that need weighted
  prediction as a predictor but not as a tree property.

Why upstream might care:
- Also portable to C/C++.
- This is another case of work-elimination guided by filtered-tree structure.

### 3. Hoist scanline row slices and `y`-dependent state

What changed:
- Hoisted top-row / top2-row slice selection and `y > 0` / `y > 1` checks out
  of the inner pixel loop.

Why it helps:
- Small but measurable reduction in repeated per-pixel control work.

Why upstream might care:
- Straightforward source cleanup that should be portable.
- Low risk, though the win is modest.

### 4. Reduce `decodeGroup` scratch and row-copy overhead

What changed:
- Pre-reserved per-group scratch channel storage and hoisted copy extents out of
  the row loop.

Why it helps:
- Cuts avoidable allocation and copy bookkeeping around group decode.

Why upstream might care:
- Portable idea, though it is less central than the modular inner-loop work.

### 5. Narrow no-reference property-mask specializations

What changed:
- Added compile-time-specialized decode loops for the dominant no-reference
  filtered-tree masks seen on the committed modular corpus.

Why it helps:
- Turns generic per-pixel property guards into constant-folded writes for the
  hot masks actually seen in practice.

Why upstream might care:
- The core idea is portable.
- The exact implementation strategy is where Zig had a real ergonomics edge.

### 6. Compact no-reference property slots

What changed:
- Remapped filtered-tree property IDs for the hot no-reference masks into a tiny
  local slot space instead of carrying the generic non-reference property index
  space into the specialized loop.

Why it helps:
- Shrinks the hot property array and reduces generic indexing overhead in lookup.

Why upstream might care:
- This is portable to C/C++.
- It is especially attractive when the filtered-tree mask is already known.

### 7. Compact specialized no-reference MA-tree lookup

What changed:
- Re-encoded remapped no-reference trees into a denser inline node layout for
  the specialized path, while preserving the generic tree representation as a
  fallback.

Why it helps:
- The post-specialization hotspot was still the inlined MA-tree traversal.
- The denser node layout reduced metadata traffic and improved the large modular
  case by about `~5%` versus the previous `libjxlz` checkpoint.

Why upstream might care:
- This is still fundamentally portable.
- The payoff depends on whether upstream finds the added representation worth the
  code complexity.

## What Zig Helped With

### Easier specialization

Zig made it cheap to keep:
- a generic path
- several narrowly specialized paths
- shared helper logic

without falling into heavy template or macro machinery.

The mask-specialized loops are the clearest example: the source stays readable
while the compiler still gets strong compile-time constants.

### Low-friction layout experiments

The compact property-slot and compact tree-layout work were easy to prototype,
test, and keep side-by-side with the old path. Zig’s explicit layouts and
lightweight `comptime` helped here.

### Tighter coupling between profiling and code shape

The source-to-generated-code relationship stayed manageable enough that line-level
profiling and disassembly could directly guide the next specialization step.

## Where Zig Was Not a Free Win

### ABI compatibility costs real work

Matching `libjxl`’s public C surface is manual work. Public API parity does not
come “for free” just because the core decoder is in Zig.

### Specialization can still bloat code

Zig makes specialization easier, but that does not make all specializations
worth keeping. Several source-level experiments were correct and elegant but
still regressed benchmarks. They were reverted.

### Tooling maturity still favors C/C++

For SIMD breadth, thread-pool infrastructure, and large-ecosystem profiling
habits, upstream C/C++ still has advantages. Zig did not remove the need for
careful measurement.

## Could Upstream Apply These Too?

Mostly yes.

The following ideas are clearly language-independent:
- property-use planning after tree filtering
- WP-property dead-work elimination
- row-slice hoisting
- group scratch/copy reduction
- compact property-slot remapping
- compact no-reference tree layout

What Zig mainly changed was the implementation friction, not the abstract
possibility.

## What This Does Not Claim

- It does not claim that Zig alone makes `libjxlz` faster.
- It does not claim every kept win is globally worthwhile for upstream.
- It does not claim the current benchmark set is sufficient for all JPEG XL
  modes or all hardware.

## Current Status Snapshot

As of the latest checked-in benchmark history on March 7, 2026:

- full committed public-API corpus: `libjxlz` about `1.06x` faster than upstream
  `libjxl`
- large modular multigroup fixture: `libjxlz` about `1.08x` faster than upstream
  `libjxl`

Those are modest but real wins against an already heavily optimized production
codec, not a naive reference implementation.
