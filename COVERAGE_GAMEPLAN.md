# libjxlz JPEG XL coverage gameplan

Written 2026-08-05. Every number below was measured on this machine against
`packages.default` (ReleaseSafe) at `5e8f9d68`, not estimated. The measurement
harness is described in "How these numbers were produced" at the bottom so the
next session can re-run it rather than trust it.


## 0. Peter's ruling, 2026-08-27: all features

Verbatim, relayed by validate: *"we need jpegz/libjxlz to support ALL jpegxl
features."*

This does not change the analysis below; it changes which half is optional.
Target B (decode completeness, §2) was written as the expensive half that could
wait. It cannot. Target A still goes first, because it is cheap and because it
turns B's progress into a per-file measurement rather than a feeling, but the
plan now runs to the end rather than stopping when validate is unblocked.

Two things landed the same day and are recorded here so §1's tables are read in
the right light:

**Findings now name the feature.** `JxlValidationResult.feature` plus
`JxlValidationFeatureName()` report which specific feature stopped validation.
Four rejection sites are named so far; every other site reports `unknown`,
deliberately, so the remaining sweep is visible rather than silently mislabeled
as "no feature". See `src/lib/base/unsupported.zig`.

**The witnessed real-world case needs two features, not one.** A private 12MP
iPhone-class photo (diagnosed locally, never copied) has a 239-byte
`modular` / `reference_only` frame 0 followed by a `var_dct` / `regular_frame`
frame 1 with `flags=0x2` (`kPatches`). So the file needs **VarDCT and patches**.
This is the shape to expect from consumer photo tooling, and it is why the
roadmap order is VarDCT, then the render pipeline VarDCT output requires, then
patches and noise.

Worth noting against §1.4's framing: `jxlinfo` calling such a file
"(possibly) lossless" reports `uses_original_profile`, which is a colour
management fact. It says nothing about whether the frame is modular or VarDCT,
and it misled a consumer into guessing modular transforms were the gap.
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
| `good/bicycles.jxl` | **VALID** | none | 1 | 1024x631 8-bit RGB, lossy modular |
| `corrupt/bicycles_corrupt_1..4.jxl` | rejected by `djxlz` | — | — | Clean base now decodes, so these are discriminating controls |
| `corrupt/bicycles_corrupt_5.jxl` | accepted by `djxlz` and stock `djxl` | — | — | Externally labeled mutation, but not an invalid-bitstream control |

Four of eight known-good files decode. Four are honestly rejected as
unsupported.

### 1.2 The corrupt bucket proves nothing today

All five files in `corrupt/` are derived from `bicycles.jxl`. Now that the
clean base decodes, four reject and count as discriminating detections.
`bicycles_corrupt_5.jxl` is accepted by both libjxlz and the stock `djxl`
oracle, so it stays recorded as a false acceptance rather than pretending it
is a valid corruption-detection control. `tests/cli/labeled_corpus_matrix_smoke.sh`
prints the measured matrix on every `./test` run:

```
  labeled-good     n=8  accepted=3  unsupported-valid=5  oracle-disagreement=0
  labeled-corrupt  n=5  rejected=4  falsely-accepted=1
  discriminating detections=4 of 4 rejections (a rejection counts only when the clean base fixture is accepted)
```

A gate that reports its false acceptance alongside the four actual detections
keeps the remaining corpus work visible.

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

**(a) Truncation was reported as a generic error.** Validate's reproducer
`FF 0A 00 00` reads 41 bits from a 16-bit input inside `ensureParsed`
(`src/capi_root.zig:1136`). `BitReader.close()` now returns
`NotEnoughBytes` on its own overread, but metadata validation can return
`GenericError` first. The bounded header path therefore gives a proven reader
overread precedence over a later generic parser error. The public C control
now reports CORRUPT/TRUNCATED, while in-bounds non-zero alignment padding
remains `GenericError`.

**(b) `bicycles.jxl` failed in modular AC group 8 of 12 and now decodes.** The
upstream differential showed the cause at the first bottom-edge group:
upstream gives modular decoding a raw 256×256 group rect, then clamps each
shifted channel against its own full dimensions. The group therefore contains
mixed `64×60`, `32×30`, and `128×59` channels. libjxlz had treated the edge as
one clamped group size, which produces no single correct ceiling or floor
calculation. `groupChannelExtent` now reproduces the shifted-and-clamped
construction; the public C validation control reports VALID.

**(c) A VALID verdict is not backed by a successful decode.** `sunset_logo.jxl`
validates VALID with 2 frames, and `djxlz` fails on it with
`JxlDecoderProcessInput failed`. The two paths diverge: `JxlValidate` calls
`FrameDecoder.decodeFrame` directly (`src/capi_root.zig:1332`), while the
decoder API also runs `writeFrameDecoderOutput` in `ensureDecoded`. Whatever
the specific cause, VALID currently means "every frame's coefficients decoded",
not "this file decodes".

The corpus matrix gate corroborates this from the other side without knowing
about it: it reports `accepted=3` of 8 known-good files (that is `djxlz`
decoding), while `JxlValidate` returns VALID for 4. `sunset_logo.jxl` is the
one file in the gap.

### 1.4 What of the format is implemented

Present and exercised: container signature and a BMFF subset, size and image
metadata headers, colour encoding, compressed ICC, frame header and TOC, ANS
and prefix entropy decoding with LZ77, modular mode (MA trees, predictors,
weighted predictor, and all three transforms: RCT, Palette, and Squeeze, each
with a working inverse), splines, and a narrow lossless modular encoder.

Absent:

- **VarDCT in its entirety.** `decodeFrame` still returns `error.Unsupported`
  for any frame whose encoding is not modular. This is the mode `cjxl`
  produces by default for any lossy encode. `DequantMatrices.decode` now
  reads every encoding except raw; `EnsureComputed` materializes identity,
  DCT2, DCT8, DCT16, and DCT32 library tables (distance-band `GetQuantWeights` in
  randomz Fixed). Still missing: DCT64+, rectangular DCT, DCT4/DCT4x8/AFV/raw
  table compute, the quantizer and adaptive quant field, coefficient
  order tables, AC strategy (DCT64 through DCT256 plus Hornuss and AFV),
  chroma-from-luma, and the inverse DCT.
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

- [x] Add `include` and `lib/include` to `.paths` — 2026-08-06 11:13 AM EDT.
- [x] Test the *fetched* package shape, not the working tree: fetch the package
      into a scratch global cache and assert the headers are present. A test
      that stats `lib/include/jxl/validate.h` in the repo passes vacuously and
      is exactly the check that would have missed this. The control failed
      before the manifest change and when both paths were reverted — 2026-08-06
      11:13 AM EDT.
- [x] Add a `jxlz validate` subcommand that calls `JxlValidate` and prints
      verdict, finding code, named feature, byte offset, host offset,
      exactness, and frames validated, with `--json`. Coverage measurements no
      longer need a throwaway C probe: `jxlz validate --json file.jxl` is the
      one-liner, and `tests/cli/jxlz_validate_smoke.sh` locks the labeled-good
      unsupported set at 0 `unknown` with both `patches` and `vardct_frame`
      present — 2026-08-27 5:03 PM EDT.

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
- [x] `BitReader.close()` returns `NotEnoughBytes` on overread rather than
      `GenericError`, and the bounded header path reports a measured overread
      before a later generic metadata error can mask it. The public `FF 0A 00
      00` control now returns CORRUPT/TRUNCATED; `jumpToByteBoundary`'s
      non-zero padding remains `GenericError` — 2026-08-06 11:13 AM EDT.
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

- [x] Fix `bicycles.jxl` AC group 8. The upstream `ModularDecode`
      differential exposed the raw-group, per-channel-clamp rule; a public C
      control moved from INDETERMINATE to VALID — 2026-08-06 7:20 PM EDT.
- [ ] Rebuild `tests/corpus/labeled/corrupt/` so it is derived from files we
      decode. Keep `bicycles_corrupt_1..4`; retain oracle-accepted
      `bicycles_corrupt_5` only as a may-ignore record, then add mutants of
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

1. [ ] `DequantMatrices` in full (`decode` all modes except raw; `EnsureComputed` identity/DCT2/DCT8/DCT16/DCT32; DCT64+ / rectangular / DCT4/AFV/raw compute still open).
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
