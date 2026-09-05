# Fixed arithmetic cost, 2026-09-05

Measured on Peter's Thelio, AMD Ryzen Threadripper 3990X, Linux x86_64,
Zig 0.16.0, clang 21.1.8 and hyperfine 1.20.0. Source baseline is
`5ee037fa6e960a8a5d1d81edd170711cabd74dbb`; the two candidate changes affect
only mantissa alignment in `add` and the magnitude quotient in `div`.
Raw observations are retained in `tests/benchmark/20260905/`.

`sf.Fixed` stores a normalized i64 mantissa and an i32 exponent. It is integer
software floating point, with 63 significant magnitude bits. The controls use
native f32 (24 significant bits) and f64 (53). This measures the practical cost
of the current representation and algorithms, including their precision and
memory differences. It does not measure every possible fixed-point design.

## Arithmetic kernels

ReleaseFast, native CPU target, five runs, 4,096 seeded inputs. Each run uses
8,192 repetitions for Fixed and 32,768 for native controls. Allocation, input
conversion, warmup and output checking are outside the measured interval.
Every output is checked against scalar expectations before timing. The
compiler may vectorize independent native operations. CPU nanoseconds per
element, averaged across the five runs:

| Kernel | Fixed before | f32 | f64 |
|---|---:|---:|---:|
| Add | 17.369 | 0.282 | 0.313 |
| Multiply | 2.150 | 0.489 | 0.308 |
| Divide | 71.459 | 0.847 | 1.202 |
| `(a+c)/4+b/2` | 33.268 | 0.500 | 0.493 |

The division originally emitted 62 restoring-division rounds. Computing
`(u128(a) << 62) / b` gives exactly the same truncated magnitude. Aligning a
mantissa for addition originally divided by a runtime power of two; shifting
its unsigned magnitude and restoring its sign preserves truncation toward
zero. An initial candidate measurement gave 6.96 ns for addition, 14.01 ns for
division and 18.36 ns for the three-tap kernel. These candidate kernel numbers
are single runs; use `./bm` for subsequent recorded measurements.

The retained pre-change oracle checks 400,144 signed/boundary division cases,
a zero numerator, and 286,720 addition cases across all exponent gaps 0–69.
Existing pinned rounding, cancellation and transcendental tests also pass.
The representation and rounding rules are unchanged.

## Complete decodes

Both libraries use the same C public-API benchmark, with reused decoder/output
storage and no worker runner. libjxlz uses ReleaseFast with baseline x86_64
instructions, matching its Nix package. Upstream is the retained CMake Release
build (`-O3 -DNDEBUG`) and can dispatch SIMD. Hyperfine uses no shell, two
warmups and five runs. CPU time and wall time are retained in its JSON output.
These figures include allocation and all decoder work, not just arithmetic.

| Input | libjxlz before | Upstream | libjxlz quotient only | libjxlz both changes |
|---|---:|---:|---:|---:|
| VarDCT 272×19 | 6.09 ms | 0.35 ms | 5.78 ms | 5.43 ms |
| Lossless modular 600×300 | 26.6 ms | 23.7 ms | unmeasured | unmeasured |

The VarDCT case is fixture 3 from `tests/unit/vardct_frame_oracle.cc`, repeated
256 times. The modular case is `lossless_600x300_multigroup_rgb.jxl`, repeated
32 times. The VarDCT output hash is `63b73252e02847b5` for baseline and both
candidates. The fixture's full pixel comparison against upstream already has
a one-level RGB8 bound in the regression suite.

Together, the changes reduced VarDCT time by about 10.8% (1.12× throughput).
The remaining upstream gap cannot be attributed entirely to integer math:
transform algorithms, setup, allocation and SIMD also differ. More image sizes
and filter configurations need measurements before quoting a general decoder
speed ratio.

## Continuing measurements

`./bm` now requests `packages.releasefast` and includes arithmetic and VarDCT
scenarios alongside the existing modular/encoder cases. Arithmetic history
records CPU and monotonic wall time, source commit, target and machine. It
flags CPU changes over 5% in either direction against that machine and target's
last matching input size. A rerun accepts the recorded measurement. Timing
checks stay in `./bm`; `./test` checks outputs and measurement bookkeeping.

`LIBJXLZ_BENCH_REF_BUILD` can select an existing upstream Release build directory.
Public API CPU/wall history also records the numeric-kernel SHA-256 so a run
with uncommitted arithmetic changes is distinguishable from its parent commit.
The earlier April macOS results describe older modular-only coverage and should
not be read as a current VarDCT performance claim.

The first integrated run completed successfully at 10:30 EDT on
`04ee5c359d97c4f287de269d84ac109ed4ea9574`. VarDCT measured 5.52 ms per decode
versus upstream 0.358 ms (15.4×); large modular measured 26.84 ms versus
23.64 ms. This VarDCT result is about 9.4% below the earlier 6.09 ms baseline.
The packaged arithmetic benchmark uses the baseline x86_64 CPU target, so its
kernel numbers should not be treated as paired comparisons with the native
target table above. Raw CPU and wall times are in `arithmetic_history.jsonl`
and `public_api_cpu_history.jsonl`; the dequantization history remains unseeded.
