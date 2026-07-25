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

## Measured libjxlz confusion matrix (2026-07-24, first native measurement)

Peter released the strict-validator hold and directed measurement before
architecture. This is the first confusion matrix produced by `libjxlz` itself.
Every earlier number in this program (8/0 good, 4/1 corrupt, sniper 87 /
bolter 97 / shotgun 100) was measured on **stock `libjxl` through Validate** and
remains baseline/oracle evidence only.

Gate: `tests/cli/labeled_corpus_matrix_smoke.sh`
Corpus: `tests/corpus/labeled/`, vendored byte-for-byte from Peter's
independently labeled `validate_gui/ground_truth_examples/` set. The labels were
authored outside this repository, which is what makes them an independent oracle
rather than a libjxlz self-assessment.

| Bucket | n | Result |
|---|---|---|
| labeled-good | 8 | accepted 2, unsupported-valid 6, oracle-disagreement 0 |
| labeled-corrupt | 5 | rejected 5, falsely accepted 0 |
| discriminating detections | — | **0 of 5** |

### The corrupt score is vacuous, and that is the finding

`libjxlz` rejects 5/5 labeled-corrupt fixtures, which in isolation looks like a
strictness win over stock `libjxl` — stock `libjxl` accepts
`bicycles_corrupt_5.jxl`. It is not a win. `libjxlz` also rejects the clean
`bicycles.jxl` base image, and every rejection in the entire corpus — valid and
corrupt alike — emits the identical opaque string `JxlDecoderProcessInput
failed`. A classifier that rejects everything scores 100% on any corrupt corpus;
the specificity side of the matrix (6 of 8 *good* files rejected) is what
exposes it.

The gate therefore pairs each corrupt fixture with the clean base it was derived
from and counts a rejection as *discriminating* only when that base is accepted.
The recorded count is **0**, and the runner prints an explicit
`NOT YET DISCRIMINATING` banner whenever rejections exist with zero
discrimination, so the matrix cannot be quoted as a detection result.

### Why the buckets cannot be gamed

- A `good` fixture may not be recorded as a bare `reject`; it must use
  `unsupported`, which the runner only allows when the pinned `djxl v0.11.2`
  oracle accepts the stream. A genuinely invalid file cannot be parked there.
- A `corrupt` fixture may not be recorded as `unsupported` at all.
- Case count and discriminating count are declared in the gate script, not the
  manifest, so a truncated or partially-read manifest cannot pass as a full
  sweep.
- The gate runs pure classifier and manifest-validator negative controls before
  the sweep. Both control groups were mutation-tested on 2026-07-24: forcing the
  classifier to always return `accept` and disabling the good/`reject` manifest
  guard each killed the run at the control stage.

### What this measurement makes falsifiable next

The 6 unsupported-valid files are the honest coverage denominator for the
decoder, and the 0 discriminating detections are the honest starting score for
strictness. Both move only when real capability lands. Any future claim that
`libjxlz` detects corruption must raise the discriminating count, which
mechanically requires accepting the clean base first.

Scope note: this gate runs under canonical `./test`, not under the narrower
`checks.x86_64-linux.test` derivation that Mechatron builds, because it needs the
pinned external `djxl` oracle. That is the same pre-existing constraint the other
ground-truth corpus gates carry.

### The corpus itself is the binding constraint, and the reason is structural

`jxlinfo` on each labeled-good fixture explains the whole matrix:

| Fixture | Codec mode | libjxlz |
|---|---|---|
| `delta_palette`, `from_gif` | lossless modular RGB / RGBA | accepted |
| `bicycles`, `grayscale`, `alpha_premultiplied` | lossy VarDCT | unsupported-valid |
| `sunset_logo`, `patches_lossless` | lossless with patches / layers | unsupported-valid |
| `animation_icos4d` | animation with blending | unsupported-valid |

The six unsupported files are three VarDCT, two patches, and one animation
blending case, which matches this review's previously stated decoder gaps
exactly.

All five labeled-corrupt fixtures are derived from `bicycles.jxl`, a VarDCT
image. The entire corrupt corpus therefore sits inside the region libjxlz does
not implement at all: effective corpus diversity of one, and zero measurable
detection by construction. No amount of validator work can raise the
discriminating count on *this* corpus without VarDCT decode.

Two consequences follow, and the second is the important one.

1. Corpus widening must derive corrupt variants from streams libjxlz can already
   accept — lossless modular — so detection becomes measurable now rather than
   after Phase 4. Peter's `/mnt/Fileserver` NAS holds 21,420 PNG, 47,125 JPEG,
   and 7,791 GIF sources (and exactly one pre-existing `.jxl`), so `cjxl` can
   mint a large, content-diverse valid corpus, and byte-level mutation of those
   gives corrupt cases whose ground truth is known by construction rather than
   by label.
2. **Validation must not be bound to decode capability.** Today the only verdict
   libjxlz exposes is "did a full decode succeed," which conflates *cannot
   render* with *invalid*. That conflation is what makes the corrupt score
   vacuous. A strict validator should be able to parse and structurally validate
   a VarDCT stream — rejecting `bicycles_corrupt_N.jxl` on an enforceable
   invariant while classifying clean `bicycles.jxl` as unsupported-valid —
   without implementing VarDCT rendering. This reframes the next slice: the
   verdict/finding contract is not a reporting layer over the decoder, it is a
   decode-independent surface.

## First real detection score, and the false accept it found (2026-07-24)

Peter directed widening the corpus from local sources. Two source surveys came
back negative and one positive, and the negatives matter:

- `/mnt/Fileserver` (10TB) holds exactly **one** `.jxl` file. JPEG XL is barely
  deployed in the wild, so found-in-the-wild JXL is not a viable corpus source.
- `~/Pictures/big-desktops-jxl` holds 529 real `.jxl` files, but `jxlinfo`
  reports `JPEG bitstream reconstruction data available` on them: they are
  JPEG-to-JXL lossless recompression, so the underlying codestream is VarDCT.
  "Lossless" there means lossless relative to the source JPEG, not modular.
  All of them land in the same unsupported region as `bicycles.jxl`.
- Minting works. `cjxl -d 0` on PNG sources produces lossless-modular JXL that
  libjxlz accepts. Over 40 real-world sources the acceptance rate was 27/40;
  the split is content-driven rather than format- or size-driven, since 2560x1600
  8-bit RGB lossless appears in both the accepted and rejected buckets.

That unlocked the first detection measurement with specificity established by
construction. Gate: `tests/cli/mutation_detection_smoke.sh` over
`tests/corpus/generated/base/` — 15 deduped small bases that libjxlz decodes
successfully, each mutated into 10 deterministic variants (4 truncations, 5
single-bit flips, 1 signature corruption). Only the bases are vendored; mutants
are byte-manipulated at test time, so the corpus is reproducible on any machine
without vendoring 150 binaries or seeding a PRNG.

Ground truth here is definitional — we know which byte changed — and the pinned
`djxl v0.11.2` oracle supplies the must-detect/may-ignore split, because a
mutation landing in entropy-coded data can still decode to a different but
perfectly valid image. Requiring rejection there would be wrong.

| Measure | Result |
|---|---|
| bases accepted by libjxlz | 15 / 15 (a reject-everything build fails this gate) |
| mutants | 150 (144 must-detect, 6 may-ignore) |
| must-detect caught | **144 / 144** |
| false accepts | **0** |
| over-rejections on may-ignore | 0 |

### The defect this found: unvalidated `brob` metadata

The first run was red with one false accept: a single flipped bit inside the
`brob` box of `16_moon.jxl` was rejected by the oracle but accepted by libjxlz,
which produced pixel output **byte-identical to the clean decode**. BMFF box
parsing confirmed offset 611 lands inside the `brob` payload (bytes 57..682).

The cause was that `OwnedBox.ensureDecompressed` is lazy: it only runs when a
caller explicitly asks for decompressed boxes, so the ordinary decode path never
touched the corrupt Brotli stream. Directly corrupting the `brob` payload of
every vendored base generalized the finding — in both cases where the oracle
rejected, libjxlz accepted.

Peter's direction was explicit: the goal is strictness and reporting, not
forgiveness, and Brotli metadata must be validated. `extractCodestreamAndBoxes`
now validates every `brob` payload as it walks the box stream
(`validateBrobPayload` in `src/lib/codec/container.zig`). Two Zig unit tests
cover it, written red first: a corrupt-payload case paired with a well-formed
positive control, so a reject-every-brob regression cannot satisfy the negative
case, plus a too-short-to-carry-an-inner-type case. All 15 bases remain
accepted after the fix, so strictness did not cost specificity.

### Two build/gate defects the brob fix exposed

**1. Benchmark targets were never wired for Brotli.** Making `validateBrobPayload`
reachable broke the build with `'brotli/decode.h' not found`. This was not a
pre-existing failure and not caused by the validation logic itself: Zig only
analyses a function body when it is referenced, so nothing on the benchmark
paths had ever forced `brotli.zig`'s `@cImport`. All four benchmark modules
lacked both `linkBrotliModule` and `link_libc` while every other target had
them. `build.zig` now wires them uniformly. The general lesson is that lazy
analysis lets build-configuration gaps hide indefinitely until some unrelated
change makes a call reachable, so "it compiles today" is weak evidence that a
target is correctly configured.

**2. The canonical gate does not test the configuration we ship.** Two
`capi_root` tests — `JxlEncoder encodes two animation frames with a staged
selection mask` and `... staged subsampled depth channel` — pass under `./test`
and fail under native `zig build test`, both expecting
`.JXL_ENC_NEED_MORE_OUTPUT` and getting `.JXL_ENC_ERROR`.

The cause is that the Nix check derivation builds
`-ODebug -target x86_64-linux-gnu -mcpu baseline`, while `./build` ships
ReleaseFast with native CPU features. The gate therefore certifies a build
configuration no user runs.

This was confirmed empirically rather than argued: stashing only
`src/lib/codec/container.zig` and `build.zig`, re-running natively, and
observing 483 pass / 2 fail at the pre-change state — the same two failures,
with the count differing only by the two container tests added in this session.
Both files were verified byte-identical after restore.

Neither is fixed here. Both are recorded in `PLAN.md`. The second is the more
serious of the two: a divergence between Debug/baseline and ReleaseFast/native
is exactly the shape of an optimizer-exposed undefined-behaviour or
SIMD-feature-dependent defect, and no amount of green in the current gate would
surface it.

## Root-cause progress on the ReleaseFast-only encoder failure (2026-07-24)

Peter flagged the Debug/ReleaseFast gate gap as the important one, so the two
failing `capi_root` animation tests were characterized rather than left as a
note. Nothing here is fixed; this section exists so the evidence is not lost.

### It is not the optimizer alone, and not a safety-check difference

| Mode | Safety checks | Optimization | Result |
|---|---|---|---|
| Debug | on | none | pass |
| ReleaseSafe | on | aggressive | pass |
| ReleaseSmall | **off** | size | pass |
| **ReleaseFast** | **off** | **aggressive** | **fail** (reproduced twice) |

`ReleaseSmall` also disables safety checks and passes, so "safety off" is not
the trigger. `ReleaseSafe` keeps bounds and overflow checking on and passes, so
the defect is not an out-of-bounds access or an integer overflow — either would
panic there. Only the combination in `ReleaseFast` fails, which is the
configuration `./build` ships.

### The failure is a stale-state read, not an uninitialized read

Temporary instrumentation (applied, captured, and reverted with the source
verified byte-identical afterwards) established:

- `JxlEncoderProcessOutput` returns `JXL_ENC_ERROR` because
  `finalizeSimpleEncode` fails with `error.InvalidArgs`.
- The specific site is `src/capi_root.zig:703`,
  `if (has_staged_alpha == has_interleaved_alpha) return error.InvalidArgs;`,
  which only executes inside `if (has_alpha)`.
- Observed state at the moment of failure:
  `alpha_bits=8 num_extra=1 img_channels=4 num_color=3 staged=true interleaved=true`.

That state does not belong to the test that failed. `JxlEncoder encodes two
animation frames with a staged selection mask` sets `num_color_channels=3` and
`num_extra_channels=1` where the single extra channel is a **selection mask**,
passes a **3-channel** pixel format, and never sets `alpha_bits` at all. It
should therefore compute `has_alpha == false` and never reach line 703.

An earlier hypothesis that this was an uninitialized-memory read was checked and
**discarded**: `EncoderImpl.pending_extra_channels` is default-initialized
(`[_]EncoderPendingExtraChannel{.{}} ** 256`), not `undefined`.

The remaining explanation consistent with all four build modes is that
`impl.basic_info` and `frame.image_format` are being read through a stale or
reused pointer, picking up a previous encoder's state. `ReleaseFast` recycles
freed heap memory sooner and lays it out differently, which is exactly when such
a read starts returning plausible-but-wrong values instead of poison.

If that holds, this is a memory-safety defect in the shipped configuration, and
the two failing tests are the symptom rather than the disease.

### Next steps, in order

1. Wire a `-Dtest-filter` option into `build.zig`. The compiled test binary
   rejects `--test-filter` (it is a build-system flag), so single-test isolation
   is currently impossible — and isolation is the decisive experiment: if the
   test passes alone, cross-test contamination is confirmed.
2. Audit the lifetime of `EncoderImpl` and of the queued-frame `extra_buffers`
   against `JxlEncoderDestroy` and the frame-settings objects.
3. Only after the root cause is known, add a ReleaseFast check derivation to the
   flake so the gate covers the shipped configuration. Adding it first would
   turn the canonical suite red without explaining why.
