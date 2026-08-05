# libjxlz JPEG XL coverage gameplan

Written 2026-08-05. Every number below was measured on this machine against
`packages.default` (ReleaseSafe) at `5e8f9d68`, not estimated. The measurement
harness is described in "How these numbers were produced" at the bottom so the
next session can re-run it rather than trust it.

## 1. Where we actually are

### 1.1 The labeled corpus, by strict-validation verdict

`JxlValidate` over `tests/corpus/labeled/`:

| File | Verdict | Finding | Frames | Upstream `jxlinfo` |
|---|---|---|---|---|
| `good/delta_palette.jxl` | VALID | none | 1 | 555x751 8-bit RGB |
| `good/from_gif.jxl` | VALID | none | 1 | 640x426 8-bit RGB+A |
| `good/sunset_logo.jxl` | VALID | none | 2 | 1386x924 10-bit RGB+A |
| `good/grayscale.jxl` | UNSUPPORTED | unsupported-feature | 0 | 200x200 8-bit gray, lossy |
| `good/alpha_premultiplied.jxl` | UNSUPPORTED | unsupported-feature | 0 | 1024x1024 12-bit RGB+A, lossy |
| `good/animation_icos4d.jxl` | UNSUPPORTED | unsupported-feature | 0 | 128x128 animation |
| `good/patches_lossless.jxl` | UNSUPPORTED | unsupported-feature | 1 | 1600x1096 8-bit RGB+A |
| `good/bicycles.jxl` | **INDETERMINATE** | unclassified-decoder-error | 0 | 1024x631 8-bit RGB, lossy |
| `corrupt/bicycles_corrupt_1..5.jxl` | **INDETERMINATE** ×5 | unclassified-decoder-error | 0 | — |

Three of eight known-good files decode. Four are honestly rejected as
unsupported. One is untyped.

### 1.2 The corrupt bucket proves nothing today

All five files in `corrupt/` are derived from `bicycles.jxl`, which already
fails before any frame is validated. Their INDETERMINATE verdict is inherited
from the clean file, so the bucket currently measures nothing about corruption
detection. This is the "green by exclusion" failure mode Einstein's
2026-07-24 note warned about, in its purest form: the corpus looks like a
5-case detection suite and is a 5-case restatement of one pre-existing bug.
This was already known and already declared. `tests/cli/labeled_corpus_matrix_smoke.sh`
prints it on every `./test` run:

```
  labeled-good     n=8  accepted=2  unsupported-valid=6  oracle-disagreement=0
  labeled-corrupt  n=5  rejected=5  falsely-accepted=0
  discriminating detections=0 of 5 rejections (a rejection counts only when the clean base fixture is accepted)
  NOT YET DISCRIMINATING: every corrupt rejection above is unproven.
```

A gate that reports its own vacuity rather than a green tick is the right
design, and it means the work below is closing a gap someone deliberately left
visible instead of one that was hidden.

This is not a claim that nobody built a control here. `tests/lib/mutation_detection.bash`
is a real MFIC harness: 15 bases, 270 mutants, an independent pinned djxl
oracle deciding must-detect versus may-ignore, and a specificity check that
fails loudly if a base stops being accepted. It scores 264/264 with 0 false
accepts. What it measures is `djxlz` exiting non-zero, which is decode failure,
not verdict correctness. The strict verdict layer sits above it and is
currently unmeasured, which is exactly where the collapse happens: every one of
those 264 detections would report INDETERMINATE through `JxlValidate`.

Worse, corrupting a file we *can* decode does not produce CORRUPT either:

| Mutant | Verdict | Finding |
|---|---|---|
| `delta_palette.jxl`, byte 5000 flipped | INDETERMINATE | unclassified-decoder-error |
| `delta_palette.jxl`, byte 200 flipped | INDETERMINATE | unclassified-decoder-error |
| `sunset_logo.jxl`, byte 9000 flipped | **UNSUPPORTED** | unsupported-feature |

The third case is the dangerous one. Corruption flipped bits that the decoder
reads as a frame-encoding decision, so `peekFrameEncoding` classified damaged
data as a feature we do not implement. A consumer that treats UNSUPPORTED as
"valid but unverifiable" will accept a corrupt file. `JXL_VALIDATION_UNSUPPORTED`
is currently produced from *data-dependent* reads with no proof that the
surrounding bitstream is well-formed, which makes it unsound as a
non-corrupt signal.

**Today libjxlz reports CORRUPT only for signature and length violations.**
Every genuine bitstream invariant violation lands in INDETERMINATE or
UNSUPPORTED.

### 1.3 The three pinned defects, located

**(a) Truncation is reported as a generic error.** Validate's reproducer
`FF 0A 00 00` fails inside `ensureParsed` (`src/capi_root.zig:1136`). Root
cause is `BitReader.close()` at `src/lib/base/bit_reader.zig:161`, which
returns `JxlError.GenericError` when more bits were consumed than the input
holds. Consuming past the end of a closed input *is* truncation, and the error
set already has `NotEnoughBytes` for it. This mirrors upstream libjxl's
`BitReader::Close`, which has no truncation code to return; we do.

**(b) `bicycles.jxl` fails in modular AC group 8 of 12.** Measured frame
header: `encoding=.modular type=.regular_frame flags=0 dc_level=0 upsampling=1
is_last=true`, TOC 15 entries, 1 DC group, 12 AC groups, 1 pass. DC global and
DC group decode fine; AC groups 0-7 decode fine; group 8 returns
`error.GenericError` from `ModularDecoder.decodeGroup`. So this is a genuine
modular decoding bug on a real-world lossy-modular (XYB) file, not a missing
feature and not a DC-frame misclassification. Both of those hypotheses were
tested and refuted.

**(c) A VALID verdict is not backed by a successful decode.** `sunset_logo.jxl`
validates VALID with 2 frames, and `djxlz` fails on it with
`JxlDecoderProcessInput failed`. The two paths diverge: `JxlValidate` calls
`FrameDecoder.decodeFrame` directly (`src/capi_root.zig:1332`), while the
decoder API also runs `writeFrameDecoderOutput` in `ensureDecoded`. Whatever
the specific cause, VALID currently means "every frame's coefficients decoded",
not "this file decodes".

The corpus matrix gate corroborates this from the other side without knowing
about it: it reports `accepted=2` of 8 known-good files (that is `djxlz`
decoding), while `JxlValidate` returns VALID for 3. `sunset_logo.jxl` is the
one file in the gap.

### 1.4 What of the format is implemented

Present and exercised: container signature and a BMFF subset, size and image
metadata headers, colour encoding, compressed ICC, frame header and TOC, ANS
and prefix entropy decoding with LZ77, modular mode (MA trees, predictors,
weighted predictor, and all three transforms: RCT, Palette, and Squeeze, each
with a working inverse), splines, and a narrow lossless modular encoder.

Absent:

- **VarDCT in its entirety.** `src/lib/codec/dec_frame.zig:582` returns
  `error.Unsupported` for any frame whose encoding is not modular. This is the
  mode `cjxl` produces by default for any lossy encode. Missing pieces:
  full `DequantMatrices` (only `decodeDC` exists), the quantizer and adaptive
  quant field, coefficient order tables, AC strategy (DCT2 through DCT256 plus
  Hornuss and AFV), chroma-from-luma, and the inverse DCT.
- **Patches and noise.** `dec_frame.zig:545` rejects both frame flags.
- **The render pipeline.** No Gaborish, no edge-preserving filter, no
  upsampling, no frame blending, no noise synthesis. XYB lifting exists only
  as the narrow float path used for spline overlays.
- **Progressive structure.** DC frames, LF frames, multiple passes, and
  reference frames are parsed in the header but not decoded.
- **JPEG reconstruction (`jbrd`).**

## 2. Two completion targets, and they are not the same

Peter's framing came through validate: "JXL remains partial and
non-claimable." That resolves into two distinct goals with very different
costs, and conflating them is how this gets mis-scoped.

**Target A — validation completeness.** Every input receives a verdict backed
by an invariant we can name: VALID, CORRUPT with a typed finding, or
UNSUPPORTED with a *proven* well-formed unsupported feature. INDETERMINATE
becomes reachable only through resource limits and allocation failure. This
does not require decoding VarDCT. It requires parsing enough of it to prove
well-formedness, and it requires the error taxonomy to stop collapsing.

**Target B — decode completeness.** libjxlz decodes what libjxl decodes.
Requires VarDCT and the render pipeline.

Target A is what unblocks validate from "non-claimable". Target B is what makes
the UNSUPPORTED column shrink. Do A first: it is smaller, it is what the
consumer asked for, and it makes B's progress measurable file by file.

## 3. The plan

### Phase 0 — Package shape (hours)

Validate cannot consume our headers through a Zig URL dependency:
`build.zig.zon` `.paths` lists only `build.zig`, `build.zig.zon`, and `src`,
so `lib/include/jxl/*.h` and `include/jxl/*.h` are omitted from the fetched
package. Validate worked around it with a local extern ABI mirror.

- [ ] Add `include` and `lib/include` to `.paths`.
- [ ] Test the *fetched* package shape, not the working tree: fetch the package
      into a scratch global cache and assert the headers are present. A test
      that stats `lib/include/jxl/validate.h` in the repo passes vacuously and
      is exactly the check that would have missed this.
- [ ] Add a `jxlz validate` subcommand that calls `JxlValidate` and prints
      verdict, finding code, byte offset, host offset, exactness, and frames
      validated, with `--json`. Every measurement in section 1 was taken with a
      throwaway C probe, which means it is not reproducible without rebuilding
      the probe. A real subcommand makes the whole coverage matrix a one-liner,
      gives validate a CLI to diff against, and is the natural surface for the
      per-file scores the later phases produce.

**Control:** the test must fail if `.paths` is reverted. Verify that by
reverting it once.

### Phase 1 — Type the errors (days)

The architectural cause of the indeterminate bucket is that `JxlError`
(`src/lib/base/status.zig:10`) has four variants, mirroring upstream's
`jxl::Status`, and upstream never needed to distinguish "corrupt" from "we
gave up". Every invariant violation in the codebase becomes
`error.GenericError`, and `validationFailure` (`src/capi_root.zig:1244`) can
only map that to INDETERMINATE.

- [ ] Widen the internal error set. Add at least `Malformed` (a named invariant
      was violated, the file is provably corrupt) alongside `GenericError`
      (we do not know). Keep the four-variant `Status` mapping at the C
      boundary so the existing FFI surface is unchanged.
- [ ] `BitReader.close()` returns `NotEnoughBytes` on overread rather than
      `GenericError`. This alone fixes validate's `FF 0A 00 00` reproducer.
      Check the blast radius: `jumpToByteBoundary`'s non-zero-padding error is
      genuinely `Malformed` and must not be swept into the same change.
- [ ] Sweep every `return error.GenericError` in the decode path and classify
      each one: truncation, malformed, unsupported, or genuinely unknown.
      There are 221 such sites across 20 non-encoder files (counted, not
      estimated; `transform.zig` 52, `container.zig` 19, `dec_ans.zig` 18,
      `toc.zig` 17, `splines.zig` 17, `dec_frame.zig` 15, `frame_header.zig`
      14, and a long tail). That is too many for one commit, so sweep by file
      in dependency order, starting with the ones on the path a truncated or
      corrupt file actually takes: `frame_header`, `toc`, `dec_ans`,
      `dec_ma`, then modular `encoding` and `transform`. Each reclassification
      needs a one-line justification, because "we chose Malformed" is a claim
      about the spec, and the mutation sweep below is what refutes a wrong one.
- [ ] Make UNSUPPORTED sound. `peekFrameEncoding` currently decides from raw
      bits with no surrounding well-formedness proof, so corruption reads as
      unsupported (§1.2). Either validate the frame header fully before
      trusting the encoding field, or downgrade an unsupported verdict reached
      from unvalidated bits to indeterminate. The second is cheaper and honest;
      the first is correct.

**Controls (this is the phase where MFIC matters most):**

- A **mutation sweep** over the decodable corpus: for each good file, flip
  bytes at N positions and require every mutant to come back CORRUPT or
  UNSUPPORTED-but-provable, never INDETERMINATE. Report the score as a number,
  not a boolean.
- A paired **specificity corpus**: every unmutated good file must still return
  VALID. Without this, a checker that returns CORRUPT for everything scores
  100% on the sweep above.
- Bits that are legitimately don't-care (padding, unused extension bytes) must
  be bucketed as may-ignore before the score means anything.

**Done when:** the mutation sweep reports zero INDETERMINATE outcomes on
mutants of files we can decode, and validate's two reproducers return
CORRUPT/TRUNCATED and a typed verdict respectively.

### Phase 2 — Fix modular, then re-earn the corrupt corpus (days)

- [ ] Fix `bicycles.jxl` AC group 8. Start by dumping the group's MA tree,
      predictor set, and channel shape and comparing against groups 0-7, which
      succeed on the same file. A differential against upstream's
      `ModularDecode` on the same group is the strongest available oracle and
      does not depend on libjxlz explaining itself.
- [ ] Rebuild `tests/corpus/labeled/corrupt/` so it is derived from files we
      decode. Keep the bicycles mutants once bicycles decodes; add mutants of
      `delta_palette`, `from_gif`, and `sunset_logo`.
- [ ] Reconcile the strict path with the decode path (§1.3c) so VALID means the
      file decodes end to end. Either strict validation runs the output stage,
      or the divergence is documented and VALID is renamed to something
      narrower.
- [ ] Triage the 13/40 content-driven modular rejections already recorded in
      `PLAN.md`. With bicycles fixed, re-measure before investigating: some of
      those may be the same bug.

**Done when:** the corrupt bucket detects corruption in files whose clean
originals validate VALID, and the sweep score is recorded with the commit and
machine id.

### Phase 3 — VarDCT decode (the large slice)

This is the bulk of the remaining format. Ordered so each slice is testable
against upstream rather than against itself:

1. [ ] `DequantMatrices` in full (currently only `decodeDC`).
2. [ ] Quantizer and the adaptive quantization field.
3. [ ] Coefficient order / natural order tables.
4. [ ] AC strategy: DCT2x2 through DCT256x256, plus Hornuss and AFV.
5. [ ] Chroma-from-luma.
6. [ ] Inverse DCT for every block variant.
7. [ ] DC group decoding for VarDCT frames (modular-coded DC).
8. [ ] Coefficient reconstruction and dequantization.

**Control for every slice:** differential against upstream libjxl 0.12.0 on the
same input. We already run a pinned oracle; extend it to per-stage
intermediates rather than only final pixels, so a slice can be proven correct
before the pipeline that consumes it exists. Peter's float policy applies:
prefer fixed-point or rational arithmetic, and where upstream disagreement
traces to float nondeterminism, adjust our expectation to our own output
provided error detection is equal or better.

### Phase 4 — Render pipeline

- [ ] XYB to linear to display, as a general path rather than the spline-only
      lift.
- [ ] Upsampling (2x, 4x, 8x) with the custom kernels.
- [ ] Gaborish and the edge-preserving filter.
- [ ] Patches and noise synthesis (removes the `dec_frame.zig:545` rejection).
- [ ] Frame blending and reference frames (unblocks animation).

### Phase 5 — Remaining format surface

- [ ] Progressive: DC frames, LF frames, multiple passes.
- [ ] BMFF breadth beyond the current metadata / `brob` / extended-size subset.
- [ ] ICC breadth beyond the built-in `{sRGB, linear sRGB, gray sRGB}` export.
- [ ] JPEG reconstruction (`jbrd`).

### Phase 6 — Acceptance: the conformance suite

`PLAN.md` has "Conformance tests" unchecked under Phase 5 and it should be the
gate for the word "complete", not our corpus. The JPEG XL conformance suite
(libjxl/conformance) is the right control by MFIC's own test: we did not write
it, it enumerates the format mechanically rather than by our guesses about what
matters, and it ships expected output with defined tolerances, so a case can
refute us. Our own corpus fails the independence axis, since we chose both the
files and the expectations.

- [ ] Vendor or fetch the conformance suite; confirm its licence permits
      redistribution before vendoring. Do not assume; check.
- [ ] Wire it as a scored gate: pass count, fail count, and the specific
      failures, logged per commit and machine id the way `./bm` logs
      performance.
- [ ] Publish the score. "libjxlz decodes N of M conformance files" is a claim
      a consumer can act on. "JXL support" is not.

Define "complete coverage" as a conformance score. Until Phase 6 exists there
is no number to put in a release note, and until the score is high there is
nothing to claim.

## 4. The existing backlog, triaged against this plan

These are the open `PLAN.md` bullets that are *not* on the critical path above,
kept so they are not lost:

**Ship-blocking but independent of format coverage**

- `packages.debug` does not build (`patchelf` assertion in `fixupPhase`). Not
  in the Mechatron manifest, so it fails unnoticed.
- aarch64 *cross* builds from an x86_64 host link this machine's brotli because
  `BROTLI_LIB_DIR` is host-specific. CI's native aarch64 job is unaffected.
- `./bm` baseline now measures the ReleaseSafe binary. Re-baseline, and stop
  quoting the README's ReleaseFast-era wins until they are re-measured or
  relabelled.

**Fuzzing**

- `./fuzz` only targets the decoder. `cjxlz` / `jxlz encode` has never been
  fuzzed; malformed PNM/PAM input is the obvious next surface.
- Reuse Validate's sniper/bolter/shotgun mutators so scores are comparable
  across the four parser projects. This becomes more valuable once Phase 1's
  sweep exists, since they measure the same thing on the same scale.

**CLI polish (`jxlz`)**

- `transform` is recognised and exits 3; there is no jxltran equivalent yet.
- `--lang` is parsed and validated but not applied; the `JXLZ_LANG` / `LANG`
  precedence chain is unimplemented.
- Delegated subcommands still print `djxlz` / `cjxlz` usage strings.
- Decide whether `djxlz` / `cjxlz` stay as separate binaries or become aliases.
  They are currently the FFI dogfooding consumers, so they cannot simply go.

**Encoder**

Encoder parity work (histogram refinement, palette heuristics, modular writer
slices) is orthogonal to decode coverage and should not compete with Phases
1-3 for attention while validate is blocked.

## 5. Recommended order

1. Phase 0, Phase 1's `BitReader.close()` fix, and Phase 2's bicycles fix.
   These three are what validate asked for, and together they turn its two
   reproducers into typed results.
2. The rest of Phase 1 plus the mutation sweep. This is what makes the verdicts
   trustworthy rather than merely typed.
3. Phase 6's harness, *before* Phase 3. Standing up the conformance gate while
   the score is near zero is cheap and gives every VarDCT slice an immediate,
   independent measure of progress. Standing it up after the work is done means
   discovering how much is wrong all at once.
4. Phases 3, 4, 5.

## How these numbers were produced

A ~25-line C probe linked against `packages.default`'s `libjxlz_capi.a` calls
`JxlValidate` on each file and prints verdict, finding code, byte offset, and
frames validated. Failure sites were located by temporarily instrumenting the
five failure returns in `JxlValidate` and the five stages of
`FrameDecoder.decodeFrameWithReaderStrategy` with `std.debug.print`, building
ReleaseSafe locally, and reverting afterwards; `git status` was verified clean.
Upstream comparison used `jxlinfo` from nixpkgs libjxl 0.12.0, the same version
the oracle gate is pinned to. Mutants were produced with `dd conv=notrunc` at
fixed offsets, so they are reproducible without a seed.

Two hypotheses were tested and refuted along the way, recorded so they are not
re-tried: `bicycles.jxl` frame 0 is not a DC frame (measured
`type=.regular_frame dc_level=0`), and it is not rejected by the non-modular
guard (measured `encoding=.modular`).
