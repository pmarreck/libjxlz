# Release-Critical Code Review — libjxlz

**Date:** 2026-07-24 EDT
**Reviewer:** Codex
**Scope:** Einstein's blocking gate-repair boundary, canonical test integrity, and the smallest evidence-backed TDD repairs
**Reviewed tree:** base `31d5b1ef836c1be7f933e6a60f9980b5fd1f48b8` plus the explicitly staged repair set; the final remote revision is recorded in the durable inbox report

## Executive verdict

The repository's truthful canonical gates are restored. The unmodified top-level
`./test` passes all 485 Zig unit tests and all 86 immediate `tests/cli/*.sh`
entries. The required optimized `./build` also exits 0. No test was skipped,
renamed out of discovery, or weakened to obtain green.

`decode_spline_exact_oracle.sh` remains in canonical `tests/cli/` discovery as
test 75/86. The attempted `tests/pending/` addition is not part of the repair.
Both spline fixtures now match the pinned `djxl v0.11.2` oracle byte-for-byte
and have moved truthfully from the known-diff manifest into the exact
ground-truth manifest.

This review stops at Einstein's release boundary. It does not begin the separate
strict Validate parser architecture.

## Four original observed failures

| Failure | Evidence classification | Witnessed evidence | Repair and independent control |
|---|---|---|---|
| Native Nix test binaries could not load `libbrotlienc.so.1` | **Infrastructure defect — test runtime closure** | Both generated test binaries reported their internal Zig tests passing, then failed when invoked without the Brotli runtime search path. | The Nix check invokes each native test binary through its dynamic loader with an explicit Brotli library path. A real `nix build ".#checks.${system}.test"` passed before the final full gate. |
| `capi_encode_brob_box.c` used undeclared GNU-only `memmem` under strict C11 | **Test/oracle defect — portability and vacuity risk** | The product smoke never ran because `-std=c11 -Werror` rejected the helper. | The smallest initial TDD slice replaced it with bounded `contains_bytes` and a known-positive interior match, then retained the original negative brob assertion. Focused and canonical tests pass. |
| x86_64 Windows cross-linking could not resolve Brotli | **Infrastructure defect — archive-name adapter** | Zig 0.16 searched `libbrotli*.a`/`.lib`/`.dll`, while the Nix MinGW package supplies all three libraries only as `libbrotli*.dll.a`. | The smoke creates a PID-namespaced temp adapter, first proves all three exact source archives exist, then aliases them under Zig's searched names. All nine cross target/library builds pass. |
| Both spline fixtures differed from pinned `djxl v0.11.2` by real `+/-1` bytes | **Product defect under the repository's exact-parity contract** | Baseline exact comparison found 553,663 differing bytes in `splines.jxl` and 528 in `spline_on_first_frame.jxl`, with maximum absolute delta 1. | Direct calls into the installed upstream AVX2 `ContinuousIDCT` supplied independent exact-bit controls. The minimal source-aligned repair pins AVX2 lane reduction/fused range reduction, cutoff arithmetic, ordered dither, and nearest-even packing. Both canonical fixtures now compare exactly. |

No failure was declared out of scope. The spline oracle remained blocking and
canonical throughout diagnosis.

## TDD and falsifiability trail

The strict-C11 compiler failure was the red test for the first, smallest repair
slice. The positive control prevents an always-false byte-search helper from
passing vacuously.

The spline work proceeded through exact failing controls rather than visual or
manual acceptance:

- the canonical oracle stayed red while mismatch counts narrowed from
  `553663/528` to `57/0`, then to `36/0`, and finally to `0/0`;
- rendered UINT8 tests first failed at witnessed `0x80` versus oracle-correct
  `0x7f`, then passed after their stale expectations were updated;
- `maximumDistance` and `localIntensity` tests pin source-version-specific
  floating-point bit patterns;
- `ContinuousIDCT` tests pin actual upstream AVX2 results for isolated
  coefficients and a synthetic coefficient vector, including the fused
  range-reduction behavior found in the installed oracle;
- the first complete post-repair run exposed two stale unit expectations and
  the honest known-diff classifier rejecting a newly matching fixture. Those
  tests were updated, focused checks passed, and the complete suite was rerun.

The known-diff test remains in canonical discovery with an explicitly empty
manifest. The repaired fixtures are additions to the passing classifier, not
deletions from coverage.

## Required final gates

| Command | Exact result |
|---|---|
| `./test` | exit 0; 485/485 Zig unit tests and 86/86 CLI tests |
| `./build` | exit 0; optimized Nix package copied into `zig-out/bin` |
| `git diff --check` | exit 0 before the final full test |

Focused controls also passed:

- Nix native check derivation with real Brotli runtime loading;
- strict-C11 brob public-C-API smoke;
- two rendered UINT8 unit filters;
- known-diff and expanded exact ground-truth corpus classifiers;
- canonical exact spline oracle;
- Windows cross-compile smoke;
- `./build && ./build`, with unrelated `.exe`/`.pdb` SHA-256 values unchanged.

## Build repair boundaries

The test-runtime change affects check-time execution only. Installed package
binaries retain the separately tested loader/RPATH closure.

`./build` no longer clears or replaces `zig-out/bin`. It unlocks only an
existing colliding target binary when necessary, then performs the same copy.
Unrelated cross-platform artifacts remain present and byte-identical. This is a
recoverable, idempotent update rather than deletion disguised as repair.

## Preserved state and ownership

The dirty `third_party/highway` submodule remains at
`457c891775a7397bdb0376bb1031e6e027af1c48` with its sole original worktree
change:

`D hwy/contrib/sort/result-inl.h`

Unrelated untracked project notes, inbox files, compatibility instructions, and
the pre-existing broad `.dirtree-state` delta remain outside the staged repair.
The dirtree annotations were updated in place but are deliberately left dirty
rather than bundling unrelated historical annotation deletions into this
commit.

The explicitly owned repair comprises the build/Nix adapters, C11 brob test,
canonical runtime and spline gates, spline arithmetic/output packing and exact
tests, corpus classifier promotion, `PLAN.md`, and this review. Neither
`AGENTS.md` nor `CLAUDE.md` is staged.

## Review boundary

The gate repair is ready to ship and review. The next strict-parser work remains
separately blocked on a stable verdict/finding contract, strict BMFF envelope
validation, bounded input ownership, full codestream completion semantics, and
resource controls. None of that broader architecture is included here.
