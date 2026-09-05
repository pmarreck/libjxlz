# libjxlz Plan

## Overnight implementation sequence (2026-09-05)

Peter explicitly authorized overnight work at 01:02 EDT. Reuse the inventory
below; pause for decisions only when they prevent safe implementation.

- [x] Extract a shared-reader permutation path from `toc.zig` without changing
  TOC decoding. Prove shared ANS state, skipped LLF coefficients, discarded
  unused orders, malformed ranks, truncation and allocation cleanup.
  Targeted tests pass, including TOC physical/logical mapping — 01:14 EDT.
- [x] Decode all 13 coefficient-order classes for the 27 strategies, reusing
  natural orders. Check actual encoded streams against retained upstream C++.
  All 39 channel digests and exact 433 bits match; every unused-class mask,
  truncated byte prefix and injected allocation failure passes — 01:14 EDT.
- [x] Decode the remaining VarDCT DC-global context model and CfL parameters;
  wire completed quantizer and modular global metadata in stream order.
  Upstream context/CfL fixtures, selector endpoints, limits, truncated inputs,
  allocator failures and frame adapter sentinel pass — 01:26 EDT.
  Regression tests also exposed/fixed U32 offset overflow and swallowed OOM
  in the shared context-map decoder.
- [x] Run the full suite and production build for the order/DC-global slice.
  `./test` passed all 94 CLI suites and the Nix unit check; `./build`,
  ReleaseFast unit checks and Windows cross checks passed — 01:37 EDT.
- [x] Correct chroma sampling shifts before subsampled DC groups. An external
  test of all 64 upstream wire combinations fails; a separate upstream 4:2:0
  DC fixture also fails because the current geometry reverses sampling ratios.
  All 64 combinations now pass. Integrated eight upstream DC fixtures covering
  4:4:4/4:2:0 and all four precision values. Exact dequantized samples and
  context buckets, truncated prefixes, borrowed global entropy and frame
  adapter checks pass, including allocation sweeps — 01:45 EDT.
  The sweep also exposed/fixed a swallowed Huffman allocation error in
  `dec_ans.zig`. `./test` (all 94 CLI suites and Nix unit checks) and `./build`
  passed — 01:58 EDT.
- [x] Push the coefficient-order/DC-global slice as `4845b94d`; independently
  verified `origin/yolo` equals HEAD. Mechatron passed all exact-commit targets
  in 459 seconds, finishing 01:46:50 EDT.
- [x] Integrate inverse transforms for all 27 strategies, including AFV and
  DCT256. Upstream comparisons cover every pixel in 8x8 blocks, 64 positions
  in each larger transform and every low-frequency DC coefficient. Constant
  DC reconstruction checks every output pixel. Stride, input preservation,
  aliasing, invalid dimensions and allocation failures pass — 02:05 EDT.
  `./test` passed the Nix unit check and all 94 CLI suites; `./build` passed
  — 02:20 EDT. AC coefficients and DC smoothing remain next.
- [x] Push DC groups as `073f1b38`; origin independently matched HEAD.
  Mechatron passed in 460 seconds, finishing 02:05:43 EDT.
- [x] Implement VarDCT DC/AC coefficient-group processing and block inverse
  transforms, reusing modular and entropy machinery and existing XYB output.
  First end-to-end gate: a public upstream-produced VarDCT image matches libjxl.
- [x] Decode AC coefficient passes using the existing entropy decoder. All 30
  upstream tokenized/encoded streams match every token context and coefficient
  hash, covering all strategies, mixed blocks, 4:2:0, ANS and Huffman. Added
  shifted-pass accumulation, custom scanning, impossible-count rejection,
  truncated-prefix checks and allocation sweeps — 02:27 EDT.
- [x] Implement whole-image adaptive DC smoothing in Fixed. Complete upstream
  image comparisons, exact border preservation, partial-strength and sharp
  discontinuity cases, shape/scale validation and allocation sweeps pass
  — 02:27 EDT. `./test` passed the Nix unit check and all 94 CLI suites;
  `./build` passed — 02:39 EDT.
- [x] Mechatron passed inverse transforms (`6c57e410`) in 470 seconds,
  finishing 02:29:06 EDT; origin independently matched the pushed commit.
- [x] Add a fixture that proves LZ77 is actually selected. Requesting RLE in
  the upstream encoder was insufficient: it chose ANS without LZ77. The next
  generator asserts the emitted mode, using repeated runs across mixed values.
  Its failure exposed the additional LZ77 distance context in the group reader;
  a real multi-group image exposed the same issue in coefficient orders. Both
  now decode their actual LZ77 streams — 02:43 EDT.
- [x] Decode AC-global pass orders/histograms and connect groups to frame
  orchestration. Six complete upstream images match within one RGB8 level per
  channel, covering partial edge blocks, multiple AC/DC groups and progressive
  AC passes. DC smoothing runs after assembly of the whole DC image. Public
  validation and decoding pass the same oracle — 02:51 EDT.
  Added the missing sRGB transfer step at the XYB output boundary. Allocation
  sweeps exposed/fixed TOC error conversion, a weighted-predictor cleanup leak
  and an unnecessary fallible Huffman shrink. `./test` passed the Nix unit
  check and all 94 CLI suites; `./build` passed — 03:06 EDT.
- [x] Mechatron passed AC passes/DC smoothing (`7006c0e1`) in 470 seconds,
  finishing 02:47:26 EDT; origin independently matched the pushed commit.
- [ ] Extend VarDCT rendering to Gaborish/EPF, subsampling, extra channels,
  custom opsin parameters and the other existing gated features below.
- [x] Implement Gaborish and all three EPF stages in Fixed. Four independent
  upstream stage fixtures check every pixel, mirrored borders, custom weights
  and skipped blocks. Ten complete frames now match upstream RGB, including
  every filter configuration. Filtered-frame allocation sweeps pass — 03:13 EDT.
- [x] Enable all six DCT128/DCT256 strategies in dequantization by reusing the
  existing distance-band algorithm. All channels match 64 upstream samples per
  strategy; invalid mask bits still fail before allocation — 03:13 EDT.
- [x] Run full suite/build for the filtered VarDCT path and large matrices.
  First full run passed unit checks, production build and all 264 required
  mutation detections. Three CLI characterizations became stale: the extended
  container now matches upstream PAM bytes exactly, and grayscale reaches the
  ICC gate. Updated the classifications and retained exact pixel coverage.
  Full rerun passed the Nix unit check and all 94 CLI suites; production build
  passed — 03:41 EDT.
- [x] Mechatron passed complete VarDCT frames (`ad399b1b`) in 561 seconds,
  finishing 03:18:00 EDT; origin independently matched the pushed commit.
- [ ] Extend that working path to progressive/reference semantics and remaining
  dequant forms, then patches and remaining render stages. Each subfeature
  needs a known-good upstream fixture and malformed/truncated counterparts.
- [ ] Complete remaining container/reconstruction semantics and conformance
  corpus coverage before claiming full JPEG XL parsing/decode support.
  A fully rejected category is still unfinished, even if rejection is typed.
- [ ] For each passing code slice: run `./test` and `./build`, commit/push,
  verify exact-commit CI, and refresh coverage evidence before proceeding.

## Active parsing work (2026-09-04)

Full JPEG XL parsing and decode coverage remain the completion target.
Preserve typed rejection of unsupported features until their payloads are checked.

- [x] Reconcile the remaining-coverage list with current indexed code before
  sequencing more implementation: distinguish absent code, partial helpers,
  disconnected paths and proven end-to-end coverage (Peter, 2026-09-04).
  Codescan reported zero pending paths; inspected the returned source and
  frame/output call sites. Corrected `COVERAGE_GAMEPLAN.md` section 1.4 and
  removed duplicate AC-strategy work below. Existing permutation decoding,
  modular pass routing, animation, XYB output and loop-filter header parsing
  must be reused. The remaining broad categories already existed at
  `3bbf1a3e`; this check adds no requirements — 2026-09-04 22:44 EDT.

- [x] Finish the Einstein handoff, then summarize the recent libjxlz work,
  validation and remaining full-JPEG-XL coverage for Peter (2026-09-04).
  Einstein acknowledged at 22:34 EDT and checkpointed the Nix migration and
  updater in `~/Code/PLAN.md`; `/etc/nixos/PLAN.md` holds detailed criteria.

- [x] Move Collie to private HTTPS port 8446 using its existing user service;
  restore Mechatron's public port 443 and verify Collie restart preserves it.
  Save recoverable configuration copies first (Peter, 2026-09-04).
  Completed at approximately 22:32 EDT: private HTTPS returns 200, both public
  Funnel relay IPs return 200 for the badge, and Collie restart leaves the
  complete Tailscale configuration byte-identical. Service is enabled and
  user lingering is enabled. Backups: `~/.config/collie/backups/20260904-routing/`.
  GitHub's webhook redelivery succeeded with HTTP 200 at 22:31:05 EDT.
- [ ] Put Collie's package, service and private ingress under the host's
  declarative Nix configuration (Peter, 2026-09-04). Finish live routing
  verification first; preserve Mechatron's public ingress throughout.
  Implementation/update acceptance criteria are checkpointed in `/etc/nixos/PLAN.md`.
- [ ] Add a Nix-compatible Collie update workflow: detect a newer upstream
  release, update the version/checksum pin, build and verify before activation,
  and retain rollback (Peter, 2026-09-04 follow-up).

- [x] Identify the public-ingress regression: history records installation
  from `https://colliepwa.dev/install.sh`, followed by `collie start`.
  Collie 1.5.1's `~/.config/collie/serve.out`, timestamped 20:34:37 EDT,
  explicitly records `Removing Funnel` for the host's HTTPS port 443.
  Its managed-handler record assigns that listener's root to localhost:8787.
  Mechatron's paths survived, but public ingress was disabled. No service or
  routing changes made during this investigation — 2026-09-04 22:28 EDT.
  Remote CI remains blocked; JPEG XL implementation remains the project goal.

- [x] Read the handoff and implement quantizer parsing and coefficient scales
  in randomz Fixed. Witnessed missing-implementation failures, then passed
  56 selector-endpoint combinations, all 36 truncated bit prefixes, scale
  arithmetic and constructor bounds. `./test` (94 CLI suites) and `./build`
  passed. Wire reference: `lib/jxl/quantizer.cc` — 2026-09-04 20:25 EDT.
- [x] Decode modular AC metadata into adaptive quantization, all 27 strategy
  geometries, EPF sharpness and clamped CfL maps. The frame adapter derives
  partial edge-block geometry. Tests cover every truncated byte prefix,
  overlap, AC-group boundaries, subsampling and allocation failures.
  Frame-level VarDCT dispatch is still gated — 2026-09-04 20:33 EDT.
- [x] Preserve allocation errors at the three modular entropy sites reached
  by the new AC-metadata allocation sweep; all injected failures now return
  `OutOfMemory` and release partial state — 2026-09-04 20:33 EDT.
- [x] Correct permutation entropy contexts, with a witnessed rank-3 failure
  and exhaustive ranks through 65536. Compute natural coefficient orders for
  all 27 strategies; digests match compiled upstream C++ (regenerator in
  `tests/unit/coeff_order_oracle.cc`) — 2026-09-04 20:33 EDT.
- [x] Convert DC quant storage/parsing to Fixed; keep IEEE-754 conversion at
  XYB display. Fix witnessed truncation and stale-default failures. Preserve
  DC's existing exact 1e-8 acceptance bound in integer arithmetic; the earlier
  AC weight exponent fences remain unchanged — 2026-09-04 20:33 EDT.
- [x] Reject unimplemented strategy-mask bits before table allocation. A
  witnessed test showed DCT128+ bits being silently marked computed; invalid
  raw strategies also reject explicitly — 2026-09-04 20:33 EDT.
- [x] Fix the global-tree limit: the 2047-node VarDCT reproducer failed
  at `dec_ma.decodeTreeInner` because color channels were zeroed before the
  limit calculation. Moving that assignment after the tree, matching C++,
  passed the regression — 2026-09-04 20:50 EDT.
- [x] Adapt `toc.zig`'s existing permutation decoder to a shared entropy reader
  for custom coefficient orders; reuse `ac_strategy.zig`'s natural orders;
  then DC-global block contexts and CfL parameters — 2026-09-05 01:37 EDT.
  DC groups and AC groups remain in the overnight sequence above.
  Curiosity poke: `lib/jxl/coeff_order.cc` consumes encoded permutations even
  for unused strategies and checks the ANS final state once after all orders.
  Cover zero custom orders, preserved LLF prefixes, unused-order consumption,
  invalid Lehmer ranks, truncation and allocation failure before integration.
- [ ] Connect the completed quantizer, strategy/block map, dequant tables and
  CfL maps to the remaining VarDCT coefficient/group path and block inverse
  transforms, then compare real files with libjxl. Reuse existing XYB output.
  Curiosity poke: progressive passes and large transforms must remain visible.
- [x] Final `./test` passed the Nix unit check and all 94 CLI suites;
  `./build` passed. Coverage notes updated for this metadata/order slice
  — 2026-09-04 21:05 EDT.
- [x] Commit and verify the metadata/order slice on exact-commit Mechatron CI.
  Keep patches, rendering, progressive structure, and the other existing
  coverage items in scope after VarDCT.
  Code is committed and pushed as `b5655a287f1d835cc52b83c77c818da2aed877d4`.
  Mechatron succeeded at 22:31:10 EDT after the routing repair, taking 6s
  with the exact-commit Nix targets already available locally. The historical
  failure and repair investigation below are retained for attribution.
  All four manifest targets passed locally against that exact Git revision
  (including ReleaseFast and Windows cross-link) — 2026-09-04 21:13 EDT.
  Mechatron's original webhook delivery and retry returned EOF; the receiver
  is running, but `tailscale funnel status` marks HTTPS as tailnet-only.
  Follow-up at 22:21 EDT: tailscaled's journal shows a Serve configuration
  POST at 20:34:37 EDT, a proxy handler for localhost:8787, and the explicit
  message `Hostinfo.IngressEnabled changed to false`. GitHub's preceding
  delivery succeeded at 20:25:42 EDT. The caller of that configuration update
  was subsequently identified as Collie's start-time Serve setup; its own
  `serve.out` explicitly records removal of Funnel at that timestamp.
  No public routing was changed. GitHub Actions run `33935122064` is still
  in progress. This CI note is intentionally uncommitted so the next code
  slice can carry it without restarting the running Actions jobs.

## Mechatron CI (2026-08-27)

- [x] `6d64442f` quantizer passed Mechatron's four targets in 451s, finishing
  2026-09-04 20:33 EDT. GitHub Actions also passed all three jobs.

- [x] `4cb13298` (feature naming) **success** on Mechatron: started 20:43:26Z,
  finished 20:51:11Z, 465s. `mechatron-ci log --project libjxlz --commit 4cb13298 --json`
  reports `"status": "success"`. First push exercising the four-target
  manifest including `test-releasefast` — 2026-08-27 5:19 PM EDT
- [x] `0791846c` (`jxlz validate`) **success** on Mechatron: started 21:29:49Z,
  finished 21:37:16Z, 447s — 2026-08-27 5:37 PM EDT
- [x] `20cbcb65` (`DequantMatrices.decode` first slice) **success** on Mechatron:
  started 21:49:10Z, finished 21:56:28Z, 438s — 2026-08-27 5:56 PM EDT
- [x] `8387bf08` (remaining decode modes except raw) **success** on Mechatron:
  started 22:04:23Z, finished 22:11:57Z, 454s — 2026-08-27 6:12 PM EDT
- [x] `8348306c` (EnsureComputed identity) **success** on Mechatron: started
  22:18:22Z, finished 22:25:40Z, 438s — 2026-08-27 6:26 PM EDT
- [x] `cfdd4857` (EnsureComputed DCT2) **success** on Mechatron: started
  22:30:03Z, finished 22:37:22Z, 439s — 2026-08-27 6:37 PM EDT
- [x] `dca55020` (DCT8 GetQuantWeights + `./bm` dequant harness)
  **success** on Mechatron: started 23:32:49Z, finished 23:40:09Z, 440s —
  2026-08-27 7:40 PM EDT
- [x] `42bff2c8` (EnsureComputed DCT16) **success** on Mechatron: started
  23:58:36Z, finished 00:06:05Z, 449s — 2026-08-27 8:06 PM EDT
- [x] `3b594f2c` (EnsureComputed DCT32) **success** on Mechatron: started
  00:22:24Z, finished 00:29:46Z, 442s — 2026-08-27 8:30 PM EDT
- [x] `b8bf4438` (rectangular DCT 8×16/8×32/16×32) **success** on
  Mechatron: started 00:48:50Z, finished 00:56:18Z, 448s —
  2026-08-27 8:56 PM EDT
- [x] `9544d060` (DCT64×64 and 32×64) **success** on Mechatron: started
  01:31:01Z, finished 01:38:24Z, 443s — 2026-08-27 9:39 PM EDT
- [x] `947a7962` (DCT4 and DCT4x8) **success** on Mechatron: started
  02:18:41Z, finished 02:26:01Z, 440s — 2026-08-27 10:26 PM EDT

## GitHub Actions (2026-08-27)

- [x] GitHub Actions `./test` failed on `zig_package_headers_smoke.sh`
  because it sourced `~/dotfiles/bin/src/capture.bash` (absent on
  `runner`). Copied `capture.bash` into `tests/lib/` (sha256
  a9b3f51a8dcc862d06cf8beecd2bd7f00547bc37b8a101a265de987f8034400b)
  and sourced that. Proven with `HOME` pointing at an empty tree. —
  2026-08-27 10:34 PM EDT
- [x] GitHub Actions **success** on `2c6423e1` (all three jobs:
  macos-aarch64, linux-aarch64, linux-x86_64 full `./test`). linux-x86_64
  had been hanging on `zig fetch` of the 1.3G worktree; the smoke now
  fetches a staged copy of `build.zig.zon` `.paths` (~800K). —
  2026-08-28 12:21 AM EDT
- [ ] Promote `capture.bash` to a standalone library (Peter 2026-08-27).
  In-tree copy unblocks Actions; a sibling repo is the durable home.
  Curiosity poke: `capture`'s FD-juggle stalled `zig fetch` on GitHub
  x86_64 (job cancelled after ~30 min in `./test`) while macOS and
  linux-aarch64 finished. The headers smoke now fetches via files plus
  a 60s `timeout`, and still uses `capture` for `tar -tzf`.

## Peter's ruling: support ALL JPEG XL features (2026-08-27)

Verbatim, relayed by validate: *"we need jpegz/libjxlz to support ALL jpegxl
features."* This makes `COVERAGE_GAMEPLAN.md` Target B (decode completeness)
mandatory rather than optional. Target A (validation completeness) is still
done first because it is cheap and it makes B's progress measurable per file.

- [x] **Named the two unsupported features in the witnessed case,
  `~/Downloads/Samson.jxl`** (PRIVATE family photo — diagnosed locally only,
  never copied, no derivative fixture; instrumentation reverted and the tree
  verified clean). Two frames: frame 0 at offset 0 is `modular` /
  `reference_only` / 239 bytes / 1 TOC entry, and frame 1 at offset 239 is
  **`var_dct`** / `regular_frame` / `flags=0x2` / 198 TOC entries. `0x2` is
  `FrameFlags.patches` (`src/lib/codec/frame_header.zig:49`), so frame 0 is the
  patch dictionary reference frame. The file therefore needs **two** features:
  VarDCT and patches. Validate's guess (modular squeeze/palette/RCT) was wrong;
  all three modular transforms are implemented with working inverses —
  2026-08-27 12:47 PM EDT
- [x] **Fine-grained finding detail: the strict result now NAMES the feature.**
  `JxlValidationResult` gains a `feature` field, `JxlValidationFeature` gains 22
  stable codes, and `JxlValidationFeatureName()` returns a stable ASCII string
  so consumers need not mirror the enum. Mechanism: Zig error sets carry no
  payload, so `src/lib/base/unsupported.zig` holds a thread-local slot that
  rejection sites set via `return unsupported(.patches);`. The slot is cleared
  at `JxlValidate` entry and consumed at the boundary, so a reason can neither
  survive into a later call nor be reported against an accepted file. A site
  that still returns a bare `error.Unsupported` reads back as `unknown` rather
  than `none`, which keeps the remaining sweep visible instead of silently
  mislabeled — 2026-08-27
  - Written red first: the C control failed to compile on the missing type,
    field, and function. Non-vacuity proven by mutation: pointing the patches
    site at `.vardct_frame` makes the control fail with
    `patches names itself: ... feature=2 (vardct_frame), expected ... 3 (patches)`.
    The Zig unit tests were proven to actually run (11 matched the filter) by
    breaking one assertion and watching it fail.
  - Specificity control in the same test: an accepted file must report
    `FEATURE_NONE`, so a stale reason cannot masquerade as a finding.
  - **ABI break.** `JxlValidationResult` grew a field. Handled by the pin
    protocol (libjxlz → jpegz → tiffz → validate, mapping note before each
    push) rather than in-band versioning. This corrects what I told validate in
    the 2026-08-27 reply, where I said the result struct would also gain a
    `struct_size` guard: it did not. A caller-initialized size field on a
    result struct that every existing call site leaves uninitialized would read
    garbage, and speculative in-band versioning is the wrong trade for
    pre-1.0 software with three in-fleet consumers and a coordinated pin
    protocol. Say so in the follow-up note.
- [x] Sweep measurement over the in-repo JXL corpus: **unknown = 0**. 43 files
  (`tests/corpus`, `src/lib/testdata`, vendored `testdata/jxl`): 32 VALID, 7
  UNSUPPORTED (6 `vardct_frame`, 1 `patches` on `patches_lossless.jxl`), 4
  INDETERMINATE (`bicycles_corrupt_1..4`). The remaining ~116 bare
  `return error.Unsupported` hits are encoder-path (simple-encode surface,
  extra-channel write, color-profile write) and are not reachable from
  `JxlValidate`. Decoder-path leftover: `icc_codec.zig` unknown ICC command.
  Encoder-site naming is a separate, lower-priority cleanup — 2026-08-27
  ~4:55 PM EDT
- [ ] jpegz FYI 2026-08-27 (no response requested): `src/validation.zig`
  `@import`s `capi_root.zig`, whose 21 `JxlEncoder*` `export fn`s are not lazy,
  so a validation-only Zig consumer still needs `libbrotlienc` via
  `JxlEncoderAddBox` → `brotli.compress`. Same closure defect jpegz fixed in
  its U0 (`a60ecc7`). Their suggested shapes: split C ABI into two archives
  with a shared marshalling module (caveat: two thread-local last-error slots
  are alternatives, not composable), or have `validation.zig` import the
  validation path without the encoder exports. Does **not** remove
  `brotlidec`/`brotlicommon` — `validateBrobPayload` legitimately decompresses.
  Additive to the unknown sweep; do not reorder unless it blocks a consumer.
- [ ] Feature-coverage roadmap, sequenced by real-world frequency (sent to
  validate 2026-08-27): (1) VarDCT decode — `DequantMatrices` in full, the
  quantizer and adaptive quant field, coefficient order tables, AC strategy
  (DCT2 through DCT256 plus Hornuss and AFV), chroma-from-luma, the inverse
  DCT, and VarDCT DC groups; (2) the render pipeline VarDCT output needs (XYB
  to linear, upsampling, Gaborish, EPF); (3) patches and noise, which together
  with (1) complete Samson; (4) progressive structure (DC frames, LF frames,
  multiple passes, reference frames beyond the single `reference_only` case we
  already decode); (5) JPEG reconstruction (`jbrd`), then BMFF and ICC breadth.
  Each slice differential-gated against pinned djxl v0.12.0 on synthesized
  fixtures, plus a per-feature corruption sweep.
  - [x] `DequantMatrices.decode` all-default path (1 bit, 17 Library tables),
    custom-flag library tables (3 bits each), identity/dct2 (F16 × 64),
    dct params (seed band × 64), dct4/dct4x8 (unscaled multipliers + params),
    and afv (first six weights × 64, two param sets). Raw tables still
    return unsupported pending modular quant-table decode. C++ `Decode`
    lives in AC-global, so modular files are unaffected — 2026-08-27 5:58 PM EDT
  - [x] `EnsureComputed` first slice: identity library table inverts the
    known weights (X DC 1/280, (0,1)/(1,0)/(1,1) 1/3160). Other AC
    strategies still unsupported. — 2026-08-27 6:15 PM EDT
  - [x] `EnsureComputed` DCT2 library table: inverts the known integer
    weights ((0,1)/(1,0) 1/3840, (1,1) 1/2560). — 2026-08-27 6:27 PM EDT
  - [x] Dequant tables and encodings use randomz's integer soft-float
    (`m · 2^(e−62)`), copied from `random/src/fixed.zig` at `8fdd4a5`.
    Bitstream F16 is reconstructed as mantissa/exponent integers; invert is
    `div(1, w)` with exact equality tests. `dc_quant` is still f32 (older
    spline/XYB path). IEEE-754 arithmetic stays at the XYB display step.
    Weight magnitude bounds use the binary exponent (`e < -26` / `e > 26`),
    not a decimal 1e-8 fence. — 2026-08-27 6:48 PM EDT
  - [x] `EnsureComputed` DCT library table: distance-band
    `GetQuantWeights` (Mult chain, radial `sqrt`, geometric interpolate)
    in randomz Fixed. Library<0> DC inverts 1/3150, 1/560, 1/512. One-band
    fills every cell; two-band corner is strictly finer than DC. Larger
    DCT16/32/64/128/256 tables still unsupported. Curiosity poke held:
    the C++ `1e-6` fudge on `kSqrt2` is in the scale so the far corner
    never lands on `idx+1 == num_bands`. — 2026-08-27 7:06 PM EDT
  - [ ] `./bm` dequant/VarDCT history seed (Peter 2026-08-27, additive):
    harness is live. `bench_dequant_ensure_computed` checksum-smokes
    DCT8 library EnsureComputed (`0x82731ce8a23584ec`). `./bm` runs the
    bench `--scaling` gate (`O(rows·cols)`): first attempt doubled the side length
    and the gate fired red at 4.00× (quadratic in n, as it should);
    corrected to double `rows` with `cols` fixed, then 2.01× under the
    2.8 linear cap. Do **not** seed `dequant_ensure_computed_history.tsv`
    until DCT256 or a public-C VarDCT decode vs libjxl is worth quoting.
    `DEQUANT_READY=0` in `./bm` keeps the TSV unseeded while still
    running the scaling gate.
  - [x] `EnsureComputed` DCT16 library table: same `GetQuantWeights` at
    16×16 (table 4, required 2×2, 256 cells). DC inverts the C++
    Library<DCT16> seed bands. `kAcStrategyToQuantTable` now includes
    DCT4 (unimplemented) and DCT16 so mask bit 4 maps to table 4.
    Stack buffer covers 3×256 Fixeds; DCT32+ still unsupported. —
    2026-08-27 7:44 PM EDT
  - [x] `EnsureComputed` DCT32 library table (table 5, 32×32, 1024
    cells). Weight scratch moved to the heap (Peter's default). Library
    DC inverts the C++ seed bands; one-band fills all 1024 cells. DCT64+
    still unsupported. — 2026-08-27 8:09 PM EDT
  - [x] `EnsureComputed` rectangular DCT library tables: 8×16, 8×32,
    16×32 (tables 6–8). Two-band 8×16 is anisotropic: (0,1) is finer
    than (1,0), so a swapped rows/cols GetQuantWeights would fail.
    Aliased AC strategies (dct16x8/dct8x16 etc.) share a table. —
    2026-08-27 8:34 PM EDT
  - [x] `EnsureComputed` DCT64×64 and 32×64 library tables (11–12).
    Band 0 is `0.9`/`0.65` times the C++ base, multiplied in Fixed.
    64×64 is 4096 cells; the `./test` filter run went 36s → 55s.
    DCT128+ still unsupported. — 2026-08-27 9:01 PM EDT
  - [x] `EnsureComputed` DCT4 and DCT4x8 library tables. DCT4 expands
    4×4 distance-band weights onto 8×8 by `(y/2,x/2)`, then divides
    (0,1)/(1,0) by mul[0] and (1,1) by mul[1]; a custom 2/4 multiplier
    case proves that. DCT4x8 expands 4×8 by `(y/2,x)` and divides
    (1,0). DCT128/256 still deferred. — 2026-08-27 9:42 PM EDT
  - [x] `EnsureComputed` AFV library table. Special positions (0,1)/(1,0)
    and the 3-pixel corner come from `afv_weights`; remaining even-even
    cells interpolate `kFreqs`; odd rows take 4×8 weights; even-odd
    take 4×4. Custom one-band 4×8/4×4 layout test proves the scatter.
    Raw tables and DCT128+ still open. — 2026-08-27 10:30 PM EDT
  - [ ] DCT128/256 library tables (deferred so they do not dominate
    `./test`) and raw quant-table decode.
- [x] Add a `jxlz validate` subcommand (verdict, finding, feature name, offsets,
  frames, `--json`). `jxlz validate` / `jxlz v` dogfoods `JxlValidate` through
  the published header. Exit 0 only for VALID; other verdicts exit 1 with the
  report still on stdout. Classifier over labeled-good: 0 unknown, both
  `patches` and `vardct_frame` present. Gate: `tests/cli/jxlz_validate_smoke.sh`
  — 2026-08-27 5:03 PM EDT

## Documentation and release-readiness audit (2026-08-14)

- [x] Reconcile project-owned Markdown, the coverage plan, and the live worktree with the stricter JPEG XL parser goal; trashed the obsolete handoff, identified archive/removal candidates, traced the dirty Highway submodule, and recorded the prioritized completion list in `CODE_REVIEW.md`. Security policy remains for replacement rather than deletion because it currently routes reports upstream — 2026-08-14 3:15 PM EDT.

## Worktree hygiene (2026-08-19)

- [x] Restore the unexplained deletion of the pinned Highway file `hwy/contrib/sort/result-inl.h` from the existing submodule commit. Superproject and submodule are clean; the dependency revision remains `457c891775a7397bdb0376bb1031e6e027af1c48` — 2026-08-19 9:57 PM EDT.

## Security reporting route (2026-08-19)

- [x] Enable GitHub private vulnerability reporting for `pmarreck/libjxlz`; replace the inherited upstream security policy, contribution guidance, and vulnerability playbook with libjxlz-owned instructions using GitHub advisories first and `security@validate.pics` as fallback. No SLA, support window, bounty, or disclosure deadline was promised — 2026-08-19 10:04 PM EDT.

## Strict-parser release blockers (2026-08-14 review)

- [ ] Repair decoder input ownership before parent integration. `JxlDecoderReleaseInput` currently lets a C caller free the raw codestream while `frame_data` retains a slice into it; copy/retain the unread bytes or report the true unconsumed suffix, clear all derived slices on release/rewind, and pin a two-chunk C lifetime control.
- [ ] Add checked C image-output size arithmetic. Malicious dimensions or a caller-supplied channel count can overflow row and full-buffer multiplications before allocation; make the public size and write paths return an error instead of panicking or wrapping.
- [ ] Make the published C ABI honest. The installed upstream-shaped headers declare many symbols absent from the archive, and non-null `JxlMemoryManager` callbacks cover only the top-level object; publish a symbol-complete supported subset or explicit stubs, then either propagate the manager through each instance allocation or reject it.

## Mecha Validate v1 strict leaf gate (2026-08-04 overnight)

- [x] Add a bounded Zig/C validation API with four non-overlapping verdicts: valid, corrupt, unsupported, and indeterminate. Generic decoder failures remain indeterminate until tied to a typed violated invariant; this prevents known-valid `bicycles.jxl` from being mislabeled corrupt. `JxlValidationResult` carries a stable finding code, payload-relative offset, host-relative offset, exactness flag, and validated-frame count. Witnessed red before implementation via missing `jxl/validate.h`, then behavior-red for the known-valid generic failure — 2026-08-04 11:55 PM EDT.
- [x] Add hard default limits for input bytes, pixels, and frame count. Limit and allocation failures return indeterminate, never valid. The validator reads only the caller-provided slice, and host offsets let TIFF/other embedding callers map findings without weakening the bound — 2026-08-04 11:55 PM EDT.
- [x] Keep external libjxl as a test/dev oracle only. The current Nix package has no dependency path to the pinned `/nix/store/...-libjxl-0.12.0-bin`; `nix why-depends` reports that it does not depend on the oracle — 2026-08-04 11:57 PM EDT.
- [x] Extend deterministic corpus mutation shapes from truncation/sniper/signature to separately counted sniper (one bit), boltgun (one byte), and shotgun (bounded region) mutations. The cheap classifier-over-the-set gate asserts 4/5/5/3/1 shapes, 18 total per base — 2026-08-04 11:40 PM EDT.
- [x] Run and record the widened 15-base, 270-mutant oracle matrix: all 15 known-good bases accepted, 264/264 oracle-rejected mutations detected, 0 false accepts, and 0 over-rejections among the 6 oracle-accepted mutations — 2026-08-05 12:03 AM EDT
- [x] Run the complete local release gate after initializing the pinned worktree submodules: `./test` passed all Zig units and 92/92 CLI suites, `./build` passed, and local builds of all three manifest attributes (`checks.x86_64-linux.build`, `.test`, `.windows-x86_64-cross`) passed. Mechatron has no terminal result for the branch commit because admission accepts signed pushes only to `yolo`, `master`, or `main`; verify remote CI after promotion — 2026-08-05 12:39 AM EDT
- [ ] Replace remaining generic decoder errors with typed invariant/unsupported/resource errors so the indeterminate bucket shrinks without creating false positives. `bicycles.jxl` no longer occupies the first pinned case; the next case must preserve the same public-C, independently-oracled discipline.
- [ ] Add precise byte/bit offsets below the currently honest frame-boundary approximation. `offset_is_exact == 0` mechanically prevents consumers from presenting approximations as exact locations.
`COVERAGE_GAMEPLAN.md` is the canonical order for JPEG XL coverage. Its current labeled strict matrix is 4 VALID and 4 UNSUPPORTED known-good files; `djxlz` produces output for only 3 because `sunset_logo.jxl` still fails after coefficient decoding.
- [x] Add `include` and `lib/include` to `build.zig.zon` `.paths` so a Zig URL dependency receives public C headers. The isolated-cache archive test failed when the two paths were removed, and the ReleaseSafe suite passed all 93 CLI checks — 2026-08-06 11:13 AM EDT.

## Current coverage delivery (2026-08-06)

- [x] Add `include` and `lib/include` to the fetched Zig package, with an isolated-cache archive test for both header roots. The test was red before the manifest change and red again when the change was temporarily reverted; all 93 canonical CLI checks passed — 2026-08-06 11:13 AM EDT.
- [x] Return `NotEnoughBytes` when `BitReader.close()` detects an overread. In the bounded header parser, prefer a proven overread over a later generic metadata error; `FF 0A 00 00` now reports CORRUPT/TRUNCATED, while non-zero alignment padding retains `GenericError` — 2026-08-06 11:13 AM EDT.
- [x] Fix `bicycles.jxl` modular AC group 8. The upstream differential established that it passes a raw 256×256 bottom-edge rect and clamps each shifted channel independently, yielding mixed `64×60`, `32×30`, and `128×59` channel shapes. `groupChannelExtent` now matches that construction, a unit control pins the shapes, and the public C control changed red (`INDETERMINATE`/unclassified) to VALID — 2026-08-06 7:20 PM EDT.
- [ ] Rebuild the labeled corrupt corpus around accepted bases. The remeasurement is now discriminating for `bicycles_corrupt_1..4`; `bicycles_corrupt_5` remains an expected false acceptance because stock djxl also decodes it. Curiosity poke: preserve oracle-accepted mutations as may-ignore cases rather than claiming them as undetected corruption.
- [ ] Make `UNSUPPORTED` sound before parent integration: do not classify a frame from the unvalidated `peekFrameEncoding` prefix. Parse a full well-formed frame header first, or return INDETERMINATE, and pin the malformed-prefix and `sunset_logo` mutation controls through the packaged C API.
- [ ] Enforce Peter's 2026-08-19 validation policy: reserve `JXL_VALIDATION_VALID` for reaching this file's theoretical validation ceiling, meaning every invariant checkable in principle from its bytes, format semantics, and supplied context or keys was checked and passed. Replace the one-dimensional claim with an MFIC-controlled result model that reports the verdict, theoretical ceiling, current implementation ceiling, achieved depth or coverage, and limiting reasons. Information-dense or specification-unconstrained bytes and encrypted content without a key may lower the theoretical ceiling and still permit qualified `VALID*`; a current-code shortfall may not. Make the qualifier machine-readable, then reconcile final names with the Peter/Einstein nomenclature before freezing the C and Zig ABIs. Curiosity poke: prove controls distinguish a theoretically exhausted but intrinsically opaque file from a file the implementation merely gave up on.
- [ ] Turn the oracle mutation corpus into a strict-validation matrix. It must require a clean decoder exit, VALID bases, and typed outcomes for oracle-rejected mutants; crashes, hangs, and INDETERMINATE results are failures rather than detections.
- [ ] Bound validation working memory and metadata expansion. Apply a checked decoded-byte limit across full and extra planes, cap `brob` decompression, and pass the selected allocator through validation so parent hosts can account for all allocations.

## Validate strict-parser program — corpus matrix first (2026-07-24, Peter released the hold)
- [x] Build a libjxlz-native labeled valid/corrupt corpus runner that reports a true confusion matrix with denominators, so every later strictness claim has a measured base rate rather than stock-libjxl baseline numbers; delivered as `tests/cli/labeled_corpus_matrix_smoke.sh` over the vendored `tests/corpus/labeled/` set, witnessed red at 7 deviations before recording the observed state, and green inside canonical `./test` as test 83/87 — 2026-07-24 09:45 PM EDT
- [x] Curiosity poke (witnessed, now mechanically enforced): a reject-everything classifier scores 100% on any corrupt corpus. djxlz rejects 5/5 labeled-corrupt fixtures AND 6/8 labeled-good fixtures, and rejects the clean `bicycles.jxl` base indistinguishably from `bicycles_corrupt_1..5`. The gate pairs each corrupt fixture with its clean base, counts a detection as discriminating only when that base is accepted, records the count as 0, and prints a `NOT YET DISCRIMINATING` banner so the 5/5 cannot be quoted as a result — 2026-07-24 09:45 PM EDT
- [x] Prove the new gate is not vacuous: pure classifier and manifest-validator negative controls run before the sweep, and both control groups were mutation-tested (forcing `labeled_corpus_classify` to always return `accept`, and disabling the good/`reject` manifest guard) — each mutant was killed at the control stage and the file was restored byte-identical — 2026-07-24 09:39 PM EDT
- [x] Curiosity poke: every rejection currently emits the identical opaque `JxlDecoderProcessInput failed` string, so invalid and unsupported-valid are mechanically indistinguishable today. The oracle-justified `unsupported` bucket (pinned djxl accepts, djxlz rejects) is the only honest classifier available until the verdict/finding contract exists — 2026-07-24 09:45 PM EDT
- [x] Establish why the current corpus cannot measure detection at all: `jxlinfo` shows the 6 unsupported files are 3 VarDCT, 2 patches/layers, 1 animation-blending, and all 5 corrupt fixtures derive from the VarDCT `bicycles.jxl`. The corrupt corpus has effective diversity 1 and sits entirely inside the unimplemented region — 2026-07-24 09:20 PM EDT
- [x] Corpus widening, vendored half (Peter chose the split on 2026-07-24): 15 deduped small lossless-modular bases minted from real PNG sources now live in `tests/corpus/generated/base/` (~110 KB) as a hermetic `./test` gate. Source surveys: `/mnt/Fileserver` (10TB) holds exactly 1 `.jxl`, and all 529 files in `~/Pictures/big-desktops-jxl` are JPEG-recompression VarDCT, so neither is usable as a valid-corpus source; minting via `cjxl -d 0` from PNG is, at a measured 27/40 acceptance rate — 2026-07-24 10:05 PM EDT
- [x] Mutation generators, first tranche (Peter selected all four kinds): deterministic truncation at 4 offsets, single-bit flips at 5 offsets, and signature corruption, generated at test time rather than vendored. Must-detect vs may-ignore bucketing is supplied by the pinned djxl oracle rather than authored by us, and 6 of 150 mutants landed in entropy-coded data the oracle still decodes — so a naive "all mutants must be rejected" gate would have been wrong. First real score: 15/15 bases accepted, 144/144 must-detect caught, 0 false accepts — 2026-07-24 10:05 PM EDT
- [x] Fix the false accept the mutation sweep found: libjxlz accepted files whose `brob` Brotli metadata was corrupt because `ensureDecompressed` is lazy and the decode path never touched it, producing pixel output byte-identical to a clean decode while upstream rejected the file. Peter's direction was strictness and reporting, not forgiveness. `extractCodestreamAndBoxes` now validates every `brob` payload; two Zig unit tests written red first, the corrupt case paired with a well-formed positive control so a reject-every-brob regression cannot pass — 2026-07-24 10:05 PM EDT
- [ ] Corpus widening, local-only half: the large NAS-derived sweep tool that logs the matrix to a source-controlled ndjson keyed by machine id (the `./bm` idiom). Not yet built; the vendored gate above is the hermetic half only.
- [x] **Unified `jxlz` subcommand CLI shipped (Peter chose the name `jxlz` over `jxl`, 2026-08-01).** `src/cli/jxlz.c` provides `decode`/`encode`/`info`/`transform` with `d`/`dec`, `e`/`enc`, `i` aliases. `decode` and `encode` delegate to the existing `djxlz_main`/`cjxlz_main` entry points rather than forking their logic, so each has exactly one implementation; every other symbol in those translation units was already `static`, so the three compile into one binary cleanly. `info` is new and reads `JxlBasicInfo` through the public C FFI, with `--json` for tooling. Written in C for the same reason the other CLIs are: C cannot `@import` a Zig module, so the dogfooding rule is enforced by the language instead of by policy. Gate written red first as `tests/cli/jxlz_unified_smoke.sh` (about/help, dispatch, unknown-subcommand exit 2, JSON info, spaced paths, `--` separator). `./build` 0, `./test` 0, 90/90 CLI suites — 2026-08-01 12:32 PM EDT
- [ ] `jxlz` follow-ups deferred from the first slice: (a) `transform` is recognised and exits 3 with a clear message, because libjxlz has no jxltran-equivalent lossless transform support yet; (b) `--lang` is accepted and validated but not yet applied, and the `JXLZ_LANG`/`LANG` precedence chain is not implemented; (c) the delegated subcommands still print their own `djxlz`/`cjxlz` usage strings rather than `jxlz decode`/`jxlz encode`; (d) decide whether `djxlz`/`cjxlz` stay as separate binaries or become thin aliases — they are currently still installed and still the FFI dogfooding consumers.
- [x] **GitHub Actions CI repaired (2026-08-01). It had been red for at least 7 days with the same 9 failures, on two independent pre-existing causes — neither introduced by this session's work.** Verified by pulling the logs for run 30141816697 (commit `c1bc4562`, 7 days old) and diffing against run 30687908499: identical failure count and identical causes.
  1. **No `djxl` on any runner.** `decode_ground_truth_oracle_djxl()` falls back to `command -v djxl`, so the "pinned" oracle was really whatever the host had. It resolved from Peter's user profile locally and produced `line 38: : command not found` on every runner, failing 7 suites. Per Peter's "pin to 0.12.0 across the board", the `nixpkgs` input was updated (2026-03-04 -> 2026-07-30 rev) so it carries libjxl 0.12.0 matching the corpus baselines, and `libjxl.bin` was added to the dev shell. `djxl` now resolves to a `/nix/store` path locked by `flake.lock` instead of the machine. Only the `bin` output is used so upstream libjxl headers cannot shadow this fork's.
  2. **`.so` files embedded in `libjxlz_capi.a`.** Both static libraries linked shared brotli, and Zig materialises linked shared objects as archive members, so consumers hit `archive member ... is neither ET_REL nor LLVM bitcode` on the aarch64 runners. The two static libraries now add brotli's includes only (`addBrotliIncludes`); every executable and test still links brotli, and the C smoke tests already pass `pkg-config --libs`. Verified with `ar t zig-out/lib/libjxlz_capi.a`, which no longer lists any `.so` member.
  - Curiosity poke that bit immediately: exporting `BROTLI_LIB_DIR` from the dev shell broke `windows_cross_compile_smoke.sh`, which treats "both brotli vars set" as "the caller already chose a brotli" and then skipped resolving the MinGW cross build. Only `BROTLI_INCLUDE_DIR` is exported. Local gates green: `./build` 0, `./test` 0, 89/89 — 2026-08-01 08:35 AM EDT
  - Third cause, found after the first two were fixed and CI went 9 -> 7 failures: the ground-truth fixtures under `testdata/jxl/` are not in this repository at all. They come from the upstream libjxl `testdata` **submodule**, which `actions/checkout` does not fetch, so djxl reported `couldn't load ...` for every fixture. The four `src/lib/testdata/*.jxl` fixtures are tracked in-repo and were always fine, which is why only the `testdata/jxl/` cases failed. The workflow now runs `git submodule update --init testdata` after checkout — that one submodule only, since the Zig build does not consume brotli/googletest/libpng/etc. Note its `.gitmodules` stanza is named `third_party/testdata` while its path is `testdata`, so it must be selected by path, not name. An architecture hypothesis (AVX2 vs NEON lane behaviour) was raised and refuted first: the x86_64 job failed identically to aarch64, which ruled it out — 2026-08-01 08:55 AM EDT
  - Fourth and final cause: `capi_compressed_icc_cross_oracle.sh` configures an upstream CMake build that also needs the `highway` submodule (`Could NOT find HWY`). The workflow now runs `git submodule update --init` for all top-level submodules (~144 MB, about a minute) rather than adding them one at a time at an 8-minute CI round trip each. Non-recursive on purpose.
  - **GitHub Actions CI is GREEN on all three platforms as of run 30700818868 (commit `604619d2`): linux-x86_64, linux-aarch64, macos-aarch64.** Mechatron Prime also PASS on the same commit. CI went 9 -> 7 -> 1 -> 0 failures across four commits, each fixing an independent pre-existing cause — 2026-08-01 09:15 AM EDT
- [ ] Remaining CI gap: aarch64 **cross** builds from an x86_64 host still fail because `BROTLI_LIB_DIR` is host-specific, so executables link this machine's brotli. CI's aarch64 job builds natively and is unaffected, and `./build_all` cross targets need the same per-target brotli resolution that `windows_cross_compile_smoke.sh` already does for MinGW.
- [x] **`./fuzz` extended from one mutation kind to four (2026-08-01):** `splice` (the original multi-byte noise), `truncate` (cut at a random offset, exercising every "ran out of input" path), `bitflip` (single-bit flips, the mutation most likely to survive parsing and reach deeper decode stages), and `structural` (4-byte overwrites confined to the first 64 bytes, where the signature, box sizes and box types live, so the parser's framing checks are tested rather than its arithmetic decoder). `--mode` selects one; the default `all` rotates them by iteration index so each gets equal coverage and every mutant stays a pure function of (seed, iteration). Non-vacuity checked rather than assumed: each kind was run with `--keep` and the mutant compared against the fixture — all four differ, and `truncate` correctly shrinks the file. 720 fresh mutants across all four kinds and three fixtures (VarDCT, spline, lossless modular) produced 0 findings — 2026-08-01 12:57 PM EDT
- [ ] Still outstanding from the four mutation kinds Peter picked: reuse of Validate's sniper/bolter/shotgun mutators so scores stay comparable across the four parser projects. The four kinds above are libjxlz-native; the Validate mutators are a separate corpus-level comparison and need its harness to be callable from here.
- [ ] `./fuzz` only targets the decoder. `cjxlz`/`jxlz encode` has never been fuzzed, and an encoder fed malformed PNM/PAM input is the obvious next surface.
- [ ] Triage the content-driven modular rejections: `cjxl -d 0` output from real PNG sources is accepted 27/40, and the split is not explained by pixel format or dimensions (2560x1600 8-bit RGB lossless appears in both buckets). Isolate the responsible modular transform by differential re-encoding with individual cjxl features disabled, which is an oracle-free triage that does not depend on libjxlz explaining itself.
- [x] Classify the `brotli/decode.h` not-found build failure: NOT pre-existing. Zig only analyses a function body when it is referenced, so nothing had forced `brotli.zig`'s `@cImport` on the benchmark paths until `validateBrobPayload` made the call reachable. All four benchmark modules lacked `linkBrotliModule` and `link_libc`; `build.zig` now wires them the same way every other target is wired — 2026-07-24 10:25 PM EDT
- [x] **Gate coverage gap — closed by shipping ReleaseSafe (Peter's direction, 2026-07-30).** The canonical Nix `./test` compiled at `-ODebug` while `./build` and `packages.default` shipped ReleaseFast, so the shipped configuration was never the tested one. `build.zig`, `./build`, `flake.nix packages.default`, and both `checks.test` compile paths now use **ReleaseSafe**, making the tested mode the shipped mode. `packages.releasefast` is retained so the open ReleaseFast defect stays reproducible. Verified: `./test` exit 6 == HEAD control exit 6 (only the pre-existing oracle drift below), `./build` exit 0 — 2026-07-30 05:25 PM EDT
- [x] **Real defect the ReleaseSafe switch exposed, then fixed: `undefined reference to __zig_probe_stack`.** External C consumers link the installed `libjxlz_capi.a` with the system linker (clang), not `zig cc`, so Zig's compiler_rt was never pulled in on their behalf. Optimize modes that keep safety on emit stack-probe calls into the archive, so all 63 C-linking CLI tests failed at link time; ReleaseFast emitted no probes and hid it entirely. Fix: `capi_lib.bundle_compiler_rt = true` in `build.zig`. Witnessed red (63 link failures) then green (0). The published C FFI was only ever linkable by accident of optimize mode — exactly the class of bug the dogfooded-FFI architecture exists to surface — 2026-07-30 05:25 PM EDT
- [x] **Oracle re-pinned to djxl v0.12.0 and manifests re-baselined (Peter chose re-baseline over pinning 0.11.2, 2026-07-30).** Root cause of the drift: `decode_ground_truth_oracle_djxl()` falls back to `command -v djxl` and `flake.nix` has no libjxl input, so the "pinned v0.11.2 oracle" was really whatever djxl was on PATH; nixpkgs-unstable bumped Peter's profile to 0.12.0 and 6 suites correctly refused to run rather than diff against the wrong reference. Confirmed pre-existing (6 failures at HEAD, 6 after the ReleaseSafe work). Re-pinned the default in `tests/lib/decode_ground_truth_corpus.bash` and the three fake-version strings in `tests/cli/decode_oracle_resolver_smoke.sh`. Measured result of the new oracle: **only the two spline fixtures moved**; the 4 lossless fixtures and `pq_gradient.jxl` are still byte-exact, and the mutation-detection and labeled-corpus gates were unaffected (their oracle-supplied must-detect/may-ignore split is unchanged). `./test` went 6 failures to 1 — 2026-07-30 05:55 PM EDT
- [x] Re-baseline detail, recorded so it cannot be mistaken for exclusion: `splines.jxl` and `spline_on_first_frame.jxl` moved from the byte-exact ground-truth manifest into `decode_known_diff_manifest.tsv`. That bucket is a real bounded assertion, not an ignore list — its runner fails if a listed file *unexpectedly matches* upstream, if max delta exceeds +/-1, or if PAM dimensions or payload size change. Both fixtures measured max absolute delta exactly 1. Ground-truth manifest is now 5 entries, known-diff 2 — 2026-07-30 05:55 PM EDT
- [x] **Spline exact parity re-earned against djxl v0.12.0 (Peter chose option (a): re-tune rather than retire the gate) — `./test` fully green, 88/88 CLI suites, 2081 Zig unit tests, 0 failures.** Two genuine upstream algorithm changes were found by diffing the vendored reference across `bae8be30..HEAD` (0.11.0 -> 0.12.0), neither of which was float noise: (1) the spline cutoff in `ComputeSegments` changed from `std::log(0.1)` (double literal, promoting the whole term to double) to `std::log(0.1f)` with `-2.0f`, making it entirely single-precision — `maximumDistance` now matches, expectation `0x3b47afb9` derived from an independent C reference rather than from our own output; (2) `stage_write.cc` replaced the 8x8 ordered dither (loaded via `LoadDup128`, which repeated each four-value half-row) with a **32x32 blue-noise table** loaded via `LoadU`, adding per-channel offsets `(c*23, c*13)`. Ported the table programmatically from the reference (1536 floats parsed, padding verified as exact duplication of the first 16 columns before use) and threaded a channel index through `scaleRenderedToU8` and its 8 call sites. Result: `spline_on_first_frame.jxl` is now **byte-exact** and returned to the ground-truth manifest; `splines.jxl` went 553,663 -> 20 -> **1** differing byte — 2026-07-31 01:05 PM EDT
- [x] Last spline byte accepted under Peter's float policy (2026-07-31): `splines.jxl` differs at exactly one byte of 12,582,977 — pixel (799,213) channel 2, ours rounding to 112 and upstream to 111. The two straddle 111.5, so a sub-ULP accumulation difference is flipping a round-to-nearest tie; a genuine algorithmic divergence would move thousands of pixels, not one. Per Peter's rule (avoid chasing float nondeterminism; adjust expectations to our own output provided error detection is equal or better) it stays in the known-diff bucket, which still asserts it MUST differ, by at most +/-1, with identical PAM dimensions and payload size. Detection strictly improved versus the session start: previously BOTH spline fixtures sat in known-diff; now one is byte-exact and the other is bounded at a single byte. Note this is strong inference from the tie signature, not an instrumented float measurement.
- [x] `./fuzz` built to Peter's design (2026-07-31): takes a fixture and an iteration count, splices deterministic-random noise (via the `random` PCG32 utility) at deterministic-random offsets, and re-validates. Accept (0) and clean reject (1) both pass — only signals, hangs, and unexpected statuses are findings, since the goal is absence of UB rather than image reproducibility. Every mutant is a pure function of (base seed, iteration), so each finding prints its own exact replay command. A baseline control decodes the unmutated fixture first, so a broken decoder cannot yield a vacuous all-clear.
- [x] **FIXED: attacker-controllable double free in the ANS histogram decoder (2026-07-31).** `./fuzz` found it on its first 40 mutants; root-caused with a `DebugAllocator` swapped in temporarily (instrumentation reverted, `src/capi_root.zig` verified byte-identical at sha `a7ac4dd1024630cf`). Stack trace pointed at `FrameDecoder.deinit` -> `ANSCode.deinit` freeing a slice whose pointer was already dead. Cause: in `decodeHistograms`, `uint_config` and `degenerate_symbols` were stored into `code` while their `errdefer allocator.free(...)` was still armed, so any error raised afterwards (e.g. the `alphabet_sizes[c] > max_alphabet_size` rejection, trivially reachable from corrupt input) freed each buffer once via the errdefer and a second time via the caller's `ANSCode.deinit`. Fix: ownership now moves into `code` before anything fallible runs, and the errdefers are gone; `huffman_data` and `alias_tables` were restructured the same way, which additionally closes a per-entry Huffman-table leak the old errdefer could not reach. `ANSCode.deinit` now clears each slice after freeing so a repeated deinit is a no-op. Regression test written red first (`decodeHistograms does not double free code buffers when it fails after taking ownership`, aborting under `testing.allocator`'s DebugAllocator) then green — 2026-07-31 09:14 PM EDT
- [x] Fuzz verification after the fix: the three original findings (seeds 7/11/30) all report 0; the vendored 137-byte repro now rejects cleanly with `JxlDecoderProcessInput failed` instead of aborting; ~900 fresh mutants across VarDCT (`pq_gradient`, `splines`, `spline_on_first_frame`) and modular generated bases produced **0 findings** — 2026-07-31 09:14 PM EDT
- [x] Superseded, do not do: an earlier note proposed running `./fuzz` itself inside `./test`. Peter confirmed 2026-07-31 that fuzzing is a separate suite and stays out of the standard `./test`, matching the canonical brief. The equivalent coverage is `tests/cli/fuzz_repro_regression_smoke.sh`, which deterministically replays vendored crash inputs and asserts clean rejection without fuzzing — 2026-07-31 10:30 PM EDT
- [x] **`./bm` now records build mode and machine id, and refuses debug builds (2026-08-01).** Both history TSVs gained `build_mode` and `machine_id` columns; the 164 + 64 existing rows are backfilled as `ReleaseFast` / `unknown`, which is truthful since all of them predate the 2026-08-01 ReleaseSafe switch. The regression comparison now matches on scenario **and** mode **and** machine, so a ReleaseSafe row is never diffed against a ReleaseFast series and a machine with no prior row seeds its own baseline and passes instead of failing against someone else's timings. Machine id is a 12-char sha256 of hostname + arch + CPU model, overridable via `LIBJXLZ_BENCH_MACHINE`. `assert_not_debug_build` runs right after the package is built and refuses on either a `DEBUG BUILD` banner or a set `MUTE_DEBUG_STATUS`. Both branches of that control were verified rather than assumed: `MUTE_DEBUG_STATUS=1 ./bm` exits 1 with the refusal, and a locally built Debug `djxlz` does emit the exact banner the guard greps for — 2026-08-01 12:40 PM EDT
- [x] Recovered `.dirtree-state`: the working copy had silently lost 218 of its 227 annotations (233 → 26 lines), with a stray annotation-free `tests/.dirtree-state` created alongside it. Reconstructed the union of HEAD's 227 notes and the 11 newer ones (238 total, 0 lost, working-copy descriptions winning all 9 overlaps); `dirtree orphaned-notes` reports none, so nothing wiped was stale. Only caught because the file is git-tracked. Bug reported to the dirtree project inbox with the damaged artifact attached — 2026-07-30 04:50 PM EDT
- [ ] **Benchmark baseline now measures a different binary.** `./bm:34` builds `.#packages.${SYSTEM}.default`, which the ReleaseSafe switch repointed, so the next `./bm` run will measure a safety-checked build and should show a step change rather than a regression to chase. Two defensible options: keep `./bm` on `default` so benchmarks measure what actually ships (recommended — honest, and still never Debug), and re-baseline; or point `./bm` at `packages.releasefast` to keep the historical series comparable. Either way the README's published wins vs upstream libjxl were measured at ReleaseFast and are now stale — they must be re-measured or explicitly labelled as ReleaseFast-only before being quoted again.
- [x] **FIXED: the ReleaseFast-only encoder defect, open since 2026-07-24 (2026-08-01).** All four optimize modes now pass: Debug, ReleaseSafe, ReleaseSmall, ReleaseFast. Root cause: `validateSimplePackedAnimation` compared each animation frame's extra-channel metadata with `std.meta.eql`, which walks the whole 1071-byte `name_buf` inside `ExtraChannelInfo` — including the bytes past `name_len` that are declared `undefined` and never written. Debug and ReleaseSafe fill `undefined` with 0xAA, so both frames' buffers matched and the comparison passed; under ReleaseFast the two frames held whatever the heap last contained, so two semantically identical depth channels compared unequal and the encode failed with `InvalidArgs`. Fix: `ExtraChannelInfo.eql` compares the meaningful fields and only the live `name_buf[0..name_len]` prefix, and the call site uses it. Regression test written red first (compile error, then green), with a positive control asserting `std.meta.eql` really does disagree on the same inputs, plus negative controls for a genuine name difference and a differing semantic field.
  - **The pre-compaction diagnosis in `CODE_REVIEW.md` was wrong and is superseded.** It named `src/capi_root.zig:703` with state `alpha_bits=8 num_extra=1 img_channels=4 num_color=3`. Fresh instrumentation showed that site is never reached in this failure: `alpha_bits` is 0 in both the passing and failing runs, so `has_alpha` is false. The real error came from `src/lib/codec/enc_api.zig:213`, found by marking all 23 `InvalidArgs` sites in `capi_root.zig` (none fired) and then the library's.
  - **DECIDED (Peter, 2026-08-03): libjxlz keeps shipping ReleaseSafe.** Reasoning: upstream consumers decide for themselves based on their own requirements; a second LLM independently recommended ReleaseSafe at least through initial launch; and a later ReleaseFast release can then be positioned as a performance improvement once the first round of problems has been found and mitigated. No code change was needed — `build.zig`, `./build` and `flake.nix packages.default` already default to ReleaseSafe.
  - Scope correction that came out of Peter's question "if this library is included in jpegz, don't its own settings override this one?" — **yes, for Zig-module consumers.** `jpegz/build.zig` instantiates dependencies as `b.dependency("jp2z", .{ .target = target, .optimize = optimize })`, passing its own mode down, so libjxlz's `b.option(...) orelse .ReleaseSafe` never fires there. `jpegz/PLAN.md:73` states it will consume `jp2z` and `libjxlz` as plain Zig modules rather than through their C FFI (Peter's sibling-Zig exception, dogfooding rule explicitly waived); libjxlz is not yet declared in its `build.zig.zon`. Our default therefore governs only our own binaries (`djxlz`, `cjxlz`, `jxlz`), `packages.default`, `./build`, and C consumers linking the prebuilt `libjxlz_capi.a`. It does **not** govern libjxlz code compiled inside jpegz. Corollary: the "bounds/overflow panics on untrusted input" argument for ReleaseSafe is a property of our *binaries*, not of the *library*; if it matters library-wide it must come from explicit checks in the code.
- [x] **`checks.x86_64-linux.test-releasefast` added to CI (2026-08-03).** The Zig test derivation is now a `mkTestCheck = mode:` function instantiated at both ReleaseSafe and ReleaseFast, and the second is registered in `.mechatron-prime/targets`. Rationale: the unit tests are the mode-sensitive surface (`undefined` memory reads differ per mode), consumers compile this code at a mode we do not choose, and Peter's planned later ReleaseFast release needs that mode verified continuously rather than re-hunted at release time. Verified before wiring: `nix build .#checks.x86_64-linux.test-releasefast` exits 0, and all four manifest targets evaluate.
  - **PROVISIONAL DIRECTION, awaiting Peter's confirmation (2026-08-01 ~02:05 EDT).** Peter was asleep; the orchestrator session directed this hunt on the strength of my own recommendation and the fleet-wide ReleaseSafe-floor work that already surfaced real shipping bugs elsewhere (tiffz u32 underflow, rarz silent archive corruption). Rationale here: the ANS double free fixed on 2026-07-31 was an ownership-overlap bug, and the ReleaseFast encoder symptom (state belonging to a *different* test) fits the same class, so the DebugAllocator technique that pinned the ANS bug in ~20 minutes should apply to `EncoderImpl` and the queued-frame `extra_buffers`. Nothing irreversible is being done on this authority: no change to the shipped optimize mode, no force push, no history edit. Peter to confirm or redirect in the morning.
- [x] `-Dtest-filter` wired into `build.zig` (2026-08-01): a `[]const u8` build option feeding `.filters` on all six `addTest` sites, so a single test can finally be run alone. Canonical `./test` unchanged at 89/89 CLI suites, 0 failures — 2026-08-01 02:30 AM EDT
- [x] **Cross-test contamination CONFIRMED for the ReleaseFast encoder defect, with a minimal two-test reproducer (2026-08-01).** Under ReleaseFast: `staged selection mask` alone passes; `staged subsampled depth channel` alone passes; running just those two together (selection mask declared first) makes the depth test fail. So the defect is state surviving from one test into the next, not a self-contained logic error. Reproduce with `nix develop -c zig build test -Doptimize=ReleaseFast -Dtest-filter='animation frames with a staged'`.
- [x] Closed: the four refuted hypotheses (no module-level globals, `basic_info` zero-initialized, `color_encoding` write-only, `extra_channel_info` default-init no help) were all correct refutations — the culprit was a *fifth* `undefined` field, `ExtraChannelInfo.name_buf`, reached through a comparison rather than a read. Worth keeping as method: the bug class was right (uninitialised memory) even though every specific candidate was wrong.
  1. Module-level mutable globals: none exist anywhere in `src/` (`rg '^\s*(pub )?(threadlocal )?var '` returns nothing).
  2. Stale `EncoderImpl.basic_info`: it defaults to `std.mem.zeroes(JxlBasicInfo)`, so it is not uninitialized.
  3. `EncoderImpl.color_encoding = undefined` (`src/capi_root.zig:264`): only ever *written* (lines 1742, 1770), never read, so it cannot carry state into a read. Still a latent hazard worth removing separately.
  4. `image_metadata.zig:345 extra_channel_info: [256]ExtraChannelInfo = undefined`: default-initializing it to `[_]ExtraChannelInfo{.{}} ** 256` does NOT fix the repro. Experiment run and reverted; the file is byte-identical to HEAD.
- [x] Method notes kept from the ReleaseFast hunt, both worth reusing: (a) swapping the C API allocator for `std.heap.DebugAllocator` **masks** a heap-recycling-dependent defect, so the technique that cracked the ANS double free does not transfer to this bug class; (b) when an error type has many possible origins, mechanically marking *every* return site beats reasoning about which one fires — marking all 23 `InvalidArgs` sites in `capi_root.zig` proved none of them fired, which immediately moved the search into the library and found `enc_api.zig:213`.
- [ ] Audit `EncoderImpl` and queued-frame `extra_buffers` lifetimes against `JxlEncoderDestroy` and the frame-settings objects.
- [x] Superseded by the `./bm` work above: the debug-build assertion now exists, checking the packaged `djxlz` banner rather than the C harness (which still carries no announcement of its own) and rejecting a set `MUTE_DEBUG_STATUS` — 2026-08-01 12:40 PM EDT
- [ ] **`packages.debug` does not build** (found while verifying the new debug guard, 2026-08-01). `nix build .#packages.<system>.debug` dies in `fixupPhase` with `patchelf: Assertion 'startAddr % getPageSize() == startOffset % getPageSize()' failed` while setting the interpreter/RPATH on a Debug binary. Not covered by the Mechatron target manifest (`checks.build`, `checks.test`, `windows-x86_64-cross`), so it has been failing unnoticed. Local `zig build -Doptimize=Debug` is unaffected because it skips patchelf entirely, which is why the debug guard could still be verified. Unknown whether the nixpkgs bump introduced it; worth bisecting against the previous lock before assuming.
- [x] First stable verdict/finding slice delivered by `JxlValidate`: corrupt vs unsupported-valid vs resource/allocator/unclassified indeterminate, bounded input, stable finding codes, host-relative offset mapping, exactness flag, and validated-frame count. Broader box/frame context, expected/actual detail, accumulation, and a decode-independent BMFF-envelope validator remain follow-ups — 2026-08-05 12:39 AM EDT

## Einstein released gate-repair boundary (2026-07-24)
- [x] Repair the Nix test-binary Brotli runtime closure from the witnessed `libbrotlienc.so.1` loader failure; curiosity poke resolved by executing each native check binary through Nix's dynamic loader with an explicit Brotli library path while leaving package runtime closure checks intact — 2026-07-24 03:55 PM EDT
- [x] Adapt MinGW Brotli `lib*.dll.a` archives for Zig 0.16's searched names from the witnessed Windows cross-link failure; curiosity poke resolved with a PID-namespaced RAM/temp adapter that verifies and aliases all three exact import archives — 2026-07-24 03:55 PM EDT
- [x] Make `./build`'s local-artifact update recoverable and idempotent against existing mode-0555 Nix copies; curiosity poke resolved by unlocking only colliding target binaries before copy, preserving unrelated `.exe`/`.pdb` outputs byte-for-byte — 2026-07-24 03:55 PM EDT
- [x] Isolate and repair the exact spline numeric divergence with the pinned oracle still in canonical discovery; curiosity poke resolved through independent direct calls to pinned upstream AVX2 `ContinuousIDCT`, exact-bit tests, and coordinate-aware nearest-even output packing; both canonical fixtures now match byte-for-byte — 2026-07-24 03:55 PM EDT
- [x] Run complete canonical `./test` and `./build` clean with no exclusions, then explicitly stage only owned repair/report files while preserving all pre-existing dirty changes and the Highway submodule identity; final gate: 485/485 Zig units, 86/86 CLI tests, and optimized build all exit 0 — 2026-07-24 04:29 PM EDT
- [x] Commit and push the verified repair, confirm the remote revision, and deliver a durable exact-command/totals report to `/home/pmarreck/Code/inbox`; repair commit `88dd1e2b8808ec125fd84adcceb042b4b09c6887` matched `origin/yolo`, and the report was delivered as `2026-07-24-from-Codex-libjxlz-release-gates-restored.md` — 2026-07-24 04:47 PM EDT

## Einstein blocking gate (2026-07-24)
- [x] Preserve the pre-existing dirty tree and dirty `third_party/highway` submodule exactly; curiosity poke resolved by recording index/worktree/submodule state before edits and verifying the Highway deletion remained intact — 2026-07-24 02:26 AM EDT
- [x] Restore `decode_spline_exact_oracle.sh` to canonical `tests/cli/` discovery without committing the attempted `tests/pending/` demotion; both full runs enumerated it as test 75/86 — 2026-07-24 02:26 AM EDT
- [x] Reproduce the honest full `./test` gate and evidence-classify all four observed failures: two infrastructure defects, one test/oracle defect, and one product defect under the current contract — 2026-07-24 02:26 AM EDT
- [x] Take only the smallest legitimate TDD repair slice: replace GNU-only `memmem` in the brob test with a bounded C11 helper plus positive control; focused smoke and canonical suite slot pass — 2026-07-24 02:26 AM EDT
- [x] Run complete required `./test` and `./build`; after-slice `./test` exits 3 and `./build` exits 1, so no commit was made — 2026-07-24 02:26 AM EDT
- [x] Update `CODE_REVIEW.md` with the release-critical audit evidence and deliver a durable review-boundary report to `/home/pmarreck/Code/inbox`; report records exact commands, 86-test denominator, dirty-state ownership, unresolved gates, and no 1.0 claim — 2026-07-24 02:29 AM EDT

## Current Checkpoint (2026-04-17)
- [x] Decoder status: public-C-API decode remains modestly ahead of upstream `libjxl` on the checked harnesses (`full_corpus` `0.06991032825s` vs `0.0763819845s`, `large_multigroup_rgb` `1.0798166715000002s` vs `1.1401681719999999s` in the latest accepted `./bm` run)
- [x] Encoder status: the narrow lossless modular encoder is now real end to end for static grayscale/RGB plus real multi-frame JXL animation in the public `JxlEncoder` surface; `cjxlz` can convert GIF animation into animated JXL through that public C FFI while preserving loop count, frame delays, transparency, and disposal-backed full-canvas coalescing in C; `djxlz` can now export still or animated JXL back to GIF through the public `JxlDecoder` surface using coalesced displayed frames, preserved loop count, preserved per-frame delays, and a deterministic per-frame RGB332 palette with binary transparency; the public multi-frame encoder queue now accepts staged alpha plus staged sidecar extras, including the first subsampled staged-alpha and subsampled depth forms; the public decoder surface now exposes first-pass animation controls via `JxlDecoderRewind`, `JxlDecoderSkipFrames`, and `JxlDecoderSkipCurrentFrame`; and the staged BMFF metadata-box path now handles both raw metadata boxes and Brotli-compressed `brob` boxes end to end through the public C API. The current accepted narrow encode benchmark remains `0.0090798855s`
- [x] Additional JPEG XL reference corpus is available locally already: checked-in fixtures under `src/lib/testdata` and `testdata/jxl`, plus a much larger ad hoc corpus under `~/Pictures/*.jxl`, so future decoder/container/conformance work does not need internet hunting first
- [x] BMFF/CI status: the pure Zig container parser now accepts both `size == 1` extended-size boxes and final `size == 0` open-ended boxes via self-contained unit fixtures, the real-reference metadata-box smoke now handles streaming box output larger than its first buffer, and Windows cross-compile smoke is green again by target-gating the current C Brotli backend instead of trying to link host Brotli libraries into Windows artifacts — 2026-04-17 ~estimated EDT
- [x] Zig 0.16 status: the codebase was already source-migrated, and the remaining shell/tooling edges now route through a shared `run_project_zig` launcher that self-enters `nix develop -c zig` when needed while avoiding nested `nix develop` inside active dev shells and Nix sandbox builds — 2026-05-20 ~estimated EDT
- [x] Ground-truth corpus status: the repo now has a first checked-in manifest-driven still-image decode corpus that compares packaged `djxlz` output directly against upstream `djxl` on known-supported modular fixtures, giving us a real oracle-backed seam to widen before the optional local desktop corpus is turned on by default — 2026-05-20 ~estimated EDT
- [x] Ground-truth corpus buckets: the checked-in oracle harness now distinguishes three states instead of flattening everything into “pass/fail”: known byte-identical decode parity, known upstream-vs-ours decode mismatches, and known unsupported decode failures (currently VarDCT and blending), so future decoder work has named targets without forcing the main suite red — 2026-05-20 ~estimated EDT
- [x] Decoder bucket cleanup: the black-output still-image false positives were narrowed and reclassified honestly. `small_test_codestream.jxl`, `1x1_exif_xmp.jxl`, and the extended-size lossy container are now explicit `VarDCT` unsupported cases instead of pretending to be modular decode diffs, while `pq_gradient.jxl` now matches upstream exactly after `djxlz` learned to emit 16-bit PNM/PAM for >8-bit integer sources — 2026-05-22 ~estimated EDT
- [x] Root-tooling docs: the repo now explicitly tracks the shared `dirtree` view state and the live Zig `0.15 -> 0.16` migration reference at the root, while the fixture-heavy `testdata` submodule stays a real checked corpus rather than accidental scratch output — 2026-05-22 ~estimated EDT
- [x] Spline groundwork: the repo now has a pure Zig spline subsystem in `src/lib/codec/splines.zig` covering quantize/dequantize, duplicate-point rejection, draw-cache bucketing, and row-overlay helpers with focused TDD; real `splines.jxl` now decodes far enough to produce output and is tracked as a known upstream-vs-ours byte diff; `spline_on_first_frame.jxl` is now in that same known-diff bucket — 2026-05-22 ~estimated EDT
- [x] Spline bitstream parse slice: `Splines.decode` now consumes the upstream-shaped ANS/hybrid-uint spline payload into decoder-owned state, and `FrameDecoder.processDCGlobal` parses spline state before continuing into the normal DC-global modular data instead of treating splines as an immediate unsupported feature — 2026-05-26 04:30 PM EDT
- [x] Float render foundation first slice: `codec/render.zig` now owns a planar `FloatImage` seam that lifts full-resolution modular integer color planes into float rows and can apply cached spline overlays to XYB rows, with guard coverage for subsampled color channels and missing XYB planes — 2026-05-26 04:45 PM EDT
- [x] FrameDecoder spline render wiring: after modular finalization, `FrameDecoder` now builds an optional `rendered_image` for the narrow full-resolution parsed-spline case and applies cached spline overlays there, with public C output now able to consume `rendered_image` through the float-output dispatcher — 2026-05-26 05:40 PM EDT
- [x] Entropy robustness uncovered by spline corpus: prefix-code `alphabet_size == 1` histograms now become explicit degenerate symbols for `ANSSymbolReader`, so spline fixtures remain cleanly bucketed instead of causing ReleaseFast segfaults while byte-exact spline output is still underway — 2026-05-26 06:09 PM EDT
- [x] Public render-output seam: the C API now has a tested float-render output writer and `FrameDecoder` dispatcher that prefers `FrameDecoder.rendered_image` over the integer modular fallback for already-output-domain float rows, while XYB rows are routed to a dedicated conversion stage rather than silently falling back to integer modular output — 2026-05-26 06:59 PM EDT
- [x] Scalar XYB-to-output first slice: `codec/xyb.zig` now owns the upstream-shaped scalar inverse-opsin math with focused black/neutral-white tests, and the public C API can convert a black XYB `FrameDecoder.rendered_image` into RGB output through the FFI buffer path instead of returning `Unsupported` — 2026-05-31 ~estimated EDT
- [x] First real spline fixture bucket transition: hermetic `src/lib/testdata/{splines,spline_on_first_frame}.jxl` unit fixtures now prove `FrameDecoder.decodeFrame` reaches `rendered_image`; removing the over-specific XYB-only spline render guard made packaged `djxlz` decode both checked spline fixtures, and oracle comparison reclassified them from known-unsupported to known-diff because bytes still differ from upstream — 2026-05-31 ~estimated EDT
- [x] Spline render parity narrowing: rendered modular float planes now use the normalized `[0,1]` render domain before C output packing, and the scalar spline renderer now matches upstream's centripetal Catmull-Rom chord lengths plus `FastErff`/`FastCosf` approximation family; both checked spline fixtures remain known-diff, but the gap is now byte-packing-level only (`+/-1`) instead of spline shape/color drift — 2026-06-01 12:43 PM EDT
- [x] Fleet review duplicate-helper cleanup: the four local `subsampledSize` implementations are now one tested signed-shift helper in `base/common.zig`, with encoder/decoder/C API call sites sharing the same chroma/extra-channel geometry contract — 2026-06-01 01:42 PM EDT
- [ ] Nearest parity gaps: broader GIF/JXL animation dogfooding in the public decoder path, iterative histogram refinement / re-seeding, broader upstream `enc_palette.cc` heuristics, more-general modular/frame encoding, broader encode API/CLI coverage beyond the current one-shot and now narrow multi-frame uint8 gray/RGB(+staged alpha/extras) slice, richer input/container formats beyond raw PNM/PAM plus PNG plus GIF, fuller BMFF parity beyond the current metadata/`brob`/extended-size/open-ended subset, broader ICC coverage beyond the current built-in decoder-side structured `{sRGB, linear sRGB, gray sRGB}` export slice, and later lossy / VarDCT with broader conformance coverage
- [ ] Near-term direction: keep porting upstream lossless modular encode structure in narrow tested slices, prefer real roundtrip coverage first, and only keep performance changes that survive `./bm`
- [x] Near-term decoder direction: close the remaining `+/-1` output-quantization diffs for the two spline fixtures so they can move into the passing oracle bucket; exact pinned-oracle parity now holds through source-version-specific SIMD arithmetic and rendered-byte packing tests — 2026-07-24 03:55 PM EDT
- [ ] Current step checklist:
- [x] 1. C API pixel-format seam: extract `JxlDataType`, `JxlEndianness`, `JxlPixelFormat`, row-stride, endian stores, and sample-scaling helpers into `src/capi/pixel_format.zig`; keep `capi_root.zig` as the public export/re-export surface; prove with focused helper tests plus full `./test` — 2026-06-02 09:39 AM EDT
- [x] 2. C API output-buffer seam: move `writeImageToOutput`, `writeRenderedImageToOutput`, and `writeXYBRenderedImageToOutput` into `src/capi/output_buffer.zig` while keeping `capi_root.zig` as the alias/call-site owner, so the remaining spline `+/-1` quantization issue has a narrower home — 2026-06-02 09:46 AM EDT
- [x] Linux Nix package runtime: add a failing packaged-CLI smoke, build native Linux executables as Zig GNU targets, and patch only dynamically linked output binaries to Nix's loader plus Brotli/GIF/libpng/zlib RPATH; `djxlz --about` now executes directly from the Nix store — 2026-07-22 09:05 PM EDT
- [x] 3. Close spline `+/-1` oracle diffs: direct invocation of the installed pinned `djxl v0.11.2` AVX2 `ContinuousIDCT` supplied independent exact-bit controls for its lane reduction and fused range reduction; rendered UINT8 packing now matches its ordered 8x4 effective dither and nearest-even conversion. Both canonical fixtures match the pinned oracle byte-for-byte — 2026-07-24 03:55 PM EDT
- [x] Oracle alignment guard: route every upstream still-image `djxl` comparison through `tests/lib/decode_ground_truth_corpus.bash`, pin the default oracle expectation to `djxl v0.11.2`, add explicit `JXLZ_ORACLE_DJXL` / `JXLZ_ORACLE_DJXL_VERSION` override diagnostics, and prove the resolver with a dedicated CLI smoke so future source-version drift is intentional instead of ambient PATH behavior — 2026-06-21 02:04 PM EDT
- [x] Spline oracle narrowing: confirmed the active oracle is `djxl v0.11.2` while the vendored reference source is `libjxl 0.12.0`; ported the upstream high-precision spline footprint cutoff plus tighter draw/XYB arithmetic seams, but kept `splines.jxl` and `spline_on_first_frame.jxl` in the known-diff bucket because exact byte parity still depends on remaining low-level spline math/SIMD/source-version behavior — 2026-06-21 08:34 AM EDT
- [x] Spline known-diff characterization: prove both checked spline fixtures have identical PAM headers and payload sizes against upstream `djxl`, with every remaining payload mismatch bounded to `+/-1`; harden the known-diff harness so future regressions cannot hide wider drift in that bucket — 2026-06-02 10:05 AM EDT
- [x] Fixed-point render foundation: add `src/lib/base/fixed_point.zig` as a tested integer-only fixed-point helper for deterministic ratio construction, rounded multiply/divide, saturation, and normalized uint8 packing, so future render/XYB/spline work has a non-float building block — 2026-06-22 09:25 AM EDT
- [x] 4. C API memory-manager seam: extract `JxlMemoryManager` validation/allocation/copy-out helpers into `src/capi/memory_manager.zig`; add ownership and error-path tests — 2026-06-02 10:22 AM EDT
- [x] 5. C API extra-channel staging seam: extract staged alpha/extra-channel ABI structs, validation, metadata conversion, and prepared-packing result ownership into `src/capi/extra_channels.zig`; keep root-owned frame queueing staged for the next ownership slice — 2026-06-06 10:37 PM EDT
- [x] 6. C API color-profile seam: extract structured color ABI structs, default/profile conversion helpers, and ICC header-shape classification into `src/capi/color_profile.zig`; preserve embedded ICC, CMYK+black, and built-in structured-profile smokes — 2026-06-07 12:05 PM EDT
- [ ] 7. Encoder parity next slice: continue upstream-shaped lossless modular encode parity, prioritizing real roundtrips and reference comparisons over speculative optimization
- [x] 7a. First 16-bit public encode slice: add an external C smoke for a `2x1` RGB `JXL_TYPE_UINT16` big-endian roundtrip, widen the pure Zig packed-color path to preserve 16-bit samples, and keep 16-bit alpha/extras explicitly rejected until the sidecar bit-depth surface is tested — 2026-06-07 12:19 PM EDT
- [x] 7b. `cjxlz` 16-bit PNM dogfood slice: accept static color-only P5/P6/P7 inputs with `MAXVAL 65535`, pass their big-endian sample bytes through the public `JxlEncoder` FFI as `JXL_TYPE_UINT16`, prove exact `cjxlz -> djxlz` PPM roundtrip, and keep 16-bit alpha/sidecar extras rejected until separate tests drive that surface — 2026-06-07 12:29 PM EDT
- [x] 7c. Public 16-bit encode endian compatibility: expand the external C smoke to cover `JXL_LITTLE_ENDIAN` input, add input-side `loadU16` in the C pixel seam, normalize 16-bit caller rows to the encoder core's big-endian packed color layout, and keep exact `UINT16` decode output parity — 2026-06-07 12:40 PM EDT
- [x] 7d. 16-bit interleaved alpha encode slice: expand the external C `UINT16` smoke to RGBA big/little-endian input, widen the Zig packed-alpha reader and C API staging row strides to preserve 16-bit alpha samples, dogfood `cjxlz` P7 `RGB_ALPHA` at `MAXVAL 65535`, and keep 16-bit sidecar extras explicitly rejected until their own surface is tested — 2026-06-08 06:09 PM EDT
- [x] 7e. 16-bit staged alpha encode slice: expand the external C `UINT16` smoke to RGB plus `JxlEncoderSetExtraChannelBuffer(... alpha ...)`, normalize little-endian staged alpha buffers to the encoder core's big-endian plane layout, dogfood `cjxlz --extra alpha` with 16-bit PPM+PGM input, and keep 16-bit non-alpha sidecar extras rejected until separately tested — 2026-06-08 06:40 PM EDT
- [x] 7f. Navigation-doc migration: replace the stale `CODE_MINIMAP.md` maintenance surface with checked-in `dirtree note` annotations for existing minimap targets, and update README guidance to point future agents at `dirtree --show-notes` — 2026-06-08 10:15 PM EDT
- [ ] 8. Decoder parity next slice after splines: expand known-supported corpus from checked-in fixtures and optional `~/Pictures/big-desktops/` crops, keeping oracle evidence separate from implementation
- [ ] 9. BMFF/ICC follow-up: broaden container box parity and compressed/embedded ICC coverage only through reference-backed tests
- [ ] 10. Performance gate: after each behavior milestone, run `./bm` only for accepted performance checkpoints; do not optimize without a measured regression or clear asymptotic win
- [x] Windows/Nix Brotli parity: replace the temporary Windows `error.Unsupported` Brotli gate with a deterministic Nix-provided cross-target Brotli package wired through `flake.nix` + `build.zig`, and prove it with a failing-then-passing Windows cross smoke that asserts the Brotli backend is available — 2026-04-30 ~estimated EDT
- [x] BMFF parity follow-up: after Brotli is real on Windows again, tighten the next smallest container gap around decoder-side BMFF box visibility/ordering/core-box filtering with a failing test first — 2026-04-30 ~estimated EDT
- [x] ICC first slice: after the BMFF follow-up, start the first real ICC profile surface with the smallest honest public API slice and reference-backed tests — 2026-04-30 ~estimated EDT
- [x] ICC structured-profile follow-up: broaden the deterministic decoder-side ICC bridge from default sRGB to the next two upstream-shaped structured cases (`linear sRGB` and `gray sRGB`) with failing helper/API smokes first, then keep the full suite green — 2026-05-02 ~estimated EDT
- [x] ICC target-parity follow-up: tighten the structured decoder-side ICC oracle so `JXL_COLOR_PROFILE_TARGET_DATA` is exercised alongside `TARGET_ORIGINAL` for built-in `{sRGB, linear sRGB, gray sRGB}` public smokes — 2026-05-03 ~estimated EDT
- [x] ICC codec groundwork: port the first upstream `icc_codec_common` helpers into Zig with direct unit coverage for endian helpers, keyword helpers, header prediction, linear predictors, and ANS context selection, so embedded-ICC work can build on tested shared primitives instead of open-coded byte math — 2026-05-03 09:56 AM EDT
- [x] ICC codec header-only slice: add the first pure-Zig `icc_codec` module with varint preamble validation plus `PredictICC`/`UnpredictICC` support for zero-command header-only streams (`<= 128` bytes), proving the shared predictor path before wider tag/content command support — 2026-05-03 10:05 AM EDT
- [x] ICC codec insert fallback slice: broaden `PredictICC`/`UnpredictICC` from header-only data to full real profiles by supporting the zero-tag + `insert` command path, proving exact roundtrip on the built-in sRGB ICC before smarter tag/type/predict command compaction — 2026-05-03 10:17 AM EDT
- [x] ICC codec tag-table slice: model and reconstruct the built-in sRGB tag table through real tag commands (`known`, `unknown`, `TRC`, `XYZ`) while still falling back to raw `insert` for the remaining body, and prove this shrinks the encoded stream versus pure insert fallback without losing exact roundtrip — 2026-05-03 10:29 AM EDT
- [x] ICC codec body-structure slice: add generic main-body `type-start` and `XYZ` command modeling/reconstruction on top of the tag-table work, and prove the built-in sRGB profile shrinks again versus tag-table-only fallback while preserving exact roundtrip — 2026-05-03 10:36 AM EDT
- [x] ICC codec `mluc` slice: add the first payload-specific body transform by emitting and decoding `shuffle2` for tagged `mluc` UTF-16 payloads, and prove the modeled stream now contains a real shuffle command where the body-structure fallback did not — 2026-05-03 10:44 AM EDT
- [x] ICC codec `sf32` slice: add the next payload-specific body transform by emitting and decoding `shuffle4` for tagged `sf32` payloads, and prove the modeled stream now contains a real `shuffle4` command where the prior fallback did not — 2026-05-04 12:07 AM EDT
- [x] ICC codec first `predict` slice: add the first predictive body transform by emitting and decoding `predict` for a synthetic tagged `curv` payload, and prove the modeled stream gains a real `predict` command and still round-trips exactly — 2026-05-04 ~11:40 AM EDT
- [x] ICC codec `gbd` predict slice: add the next predictive body transform by emitting `predict` for a synthetic tagged `gbd ` payload after the existing generic type-start, and prove exact roundtrip through the shared decoder path — 2026-05-04 ~12:05 PM EDT
- [x] ICC codec nested `mAB`/`mBA` predict slice: track the current outer tag during body modeling, fix the latent generic `type-start` loop-control bug that the new nested oracle exposed, and prove exact roundtrip for synthetic nested `curv` and `vcgt` payloads under `mAB`/`mBA` — 2026-05-05 ~9:45 AM EDT
- [x] ICC codec `mAB` CLUT predict slice: add the first stride-aware nested CLUT `predict` path under `mAB`, driven by a synthetic offset-based CLUT oracle that proves exact roundtrip through the shared decoder path — 2026-05-05 ~10:00 AM EDT
- [x] ICC bitstream first slice: wrap the pure-Zig `predictICC` intermediate in a legal compressed-ICC ANS stream using one shared flat histogram across all 41 contexts, add the inverse decode path, and prove exact roundtrip for built-in sRGB plus a synthetic `mAB` CLUT profile — 2026-05-06 ~10:10 AM EDT
- [x] Embedded ICC public-API first slice: add streaming compressed-ICC decode from the codestream header, wire `JxlEncoderSetICCProfile` through the pure-Zig encoder path for narrow RGB/gray ICC headers, return exact embedded ICC bytes from the decoder public API, and cover it with both a Zig roundtrip test and a C smoke — 2026-05-07 ~11:30 AM EDT
- [x] Public compressed-ICC utility slice: expose `JxlICCProfileEncode` / `JxlICCProfileDecode` through the `compressed_icc.h` surface, allocate returned buffers through `JxlMemoryManager`, and prove both exact roundtrip and custom-memory-manager ownership via Zig + external C coverage — 2026-05-08 ~11:10 AM EDT
- [x] Embedded ICC header hardening: tighten `JxlEncoderSetICCProfile` so it rejects profiles whose declared big-endian size disagrees with the supplied bytes or whose payload is shorter than the mandatory 128-byte ICC header, proving both regressions with failing tests first — 2026-05-08 ~11:35 AM EDT
- [x] Compressed-ICC cross-oracle coverage: add an external smoke that compiles the same helper against `libjxlz` and a vendored-upstream static `jxl_extras_codec` build, then proves each side can decode the other side’s standalone compressed ICC stream and embedded-ICC codestream for a real built-in sRGB profile — 2026-05-13 ~estimated EDT
- [x] Embedded ICC CMYK acceptance first slice: broaden `JxlEncoderSetICCProfile` from RGB/gray-only headers to the first real upstream-shaped CMYK profile path by classifying `CMYK` ICC headers as `RGB + required black extra`, proving acceptance with a hermetic compressed fixture plus a staged black extra-channel test, and keeping explicit rejection when the extra is missing or not black — 2026-05-13 ~estimated EDT
- [x] Embedded ICC component-table follow-up: broaden `JxlEncoderSetICCProfile` from literal `RGB `/`GRAY` headers to the first honest ICC component-count table (`XYZ ` / `Lab ` / `Luv ` / `YCbr` / `Yxy ` / `HSV ` / `HLS ` / `CMY ` / `3CLR` for three-channel, `1CLR` / `MCH1` for one-channel), while still reserving four-channel acceptance for the explicit `CMYK + black extra` mapping — 2026-05-14 ~estimated EDT
- [x] Public CMYK ICC smoke follow-up: extend the external `capi_encode_icc_profile` smoke so it proves both the old RGB path and the new `CMYK + staged black extra` path round-trip exact ICC bytes through the public C encoder/decoder seam — 2026-05-14 ~estimated EDT
- [x] `cjxlz` embedded ICC first slice: add `--icc-profile PATH` to the C CLI for still-image inputs, dogfood `JxlEncoderSetICCProfile` instead of structured color metadata, reject conflicting structured-color flags up front, and prove exact embedded RGB ICC roundtrip with a new external CLI smoke — 2026-05-14 ~estimated EDT
- [x] `cjxlz` embedded ICC CMYK follow-up: broaden the new CLI path from still-image RGB ICC input to the first `CMYK + --extra black PATH` dogfood case, with a failing CLI smoke first and explicit decoder-side assertions on both the exact ICC bytes and the staged black extra channel; fixing the smoke required reordering the CLI’s public-API calls so staged extra-channel info is visible before `JxlEncoderSetICCProfile` validates the ICC shape — 2026-05-14 ~estimated EDT
- [x] `./test` runner observability follow-up: factor the shell-smoke loop into a tiny reusable Bash helper, cover it with a fake-`nix` smoke, and make the real top-level runner print deterministic per-test progress lines so long CLI sweeps no longer look hung — 2026-05-14 ~estimated EDT
- [x] Embedded ICC codestream writer parity follow-up: add failing full-image/frame-parse regressions for the synthetic header-only RGB ICC path, stop embedding the standalone byte-padded compressed-ICC blob inside the main codestream, write ICC bits directly into the outer codestream writer instead, and prove exact `djxlz --icc-profile-output` RGB/CMYK roundtrip through a new CLI smoke — 2026-05-14 ~estimated EDT
- [x] `./test` runner tempdir hardening: extend the shared shell-test runner so stale session-specific `TMPDIR` values are normalized before any `nix develop` smoke launch, and prove it with a fake-`nix` regression that simulates real temp-file creation failure under a missing directory — 2026-05-16 ~estimated EDT
- [x] `djxlz` embedded ICC hardening: add negative `--icc-profile-output` smokes (`@stdout`, write failures, and option-contract edges), prove `@stdout`/`@stderr` alias extraction as a real happy path, and reject ambiguous shared output sinks up front — 2026-05-16 ~estimated EDT
- [x] Embedded ICC broader CLI/API parity: choose the smaller decoder-side helper path before animation work by hardening the existing `djxlz --icc-profile-output` surface around stream aliases and sink conflicts rather than widening GIF/animation ICC handling first — 2026-05-16 ~estimated EDT
- [x] Animated GIF embedded ICC parity: broaden `cjxlz --icc-profile PATH` across GIF input so animated JXL can carry embedded ICC, teach the `cjxlz_gif_info.zig` codestream inspector to skip embedded ICC payloads before frame scans, and prove preserved animation metadata plus exact `djxlz --icc-profile-output` roundtrip with a dedicated GIF smoke — 2026-05-16 ~estimated EDT
- [x] Zig 0.16 tooling hardening: add a shared Bash `run_project_zig` helper plus a fake-`nix` launcher smoke, switch the remaining `build`/Windows/bench scripts off ad hoc bare `zig`, and re-verify `./build`, `./build debug capi`, `./test`, and the Windows cross smoke from green — 2026-05-20 ~estimated EDT
- [x] Ground-truth corpus harness first slice: add a manifest-driven decoder/interop harness for checked-in fixtures and the optional local `~/Pictures/big-desktops/` corpus, then use it to widen ICC/container/animation parity checks against upstream tools — 2026-05-20 ~estimated EDT
- [x] Ground-truth corpus bucket follow-up: promote the known-passing extended-size container fixture into the checked parity manifest, add dedicated oracle-backed “known diff” characterization for `small_test_codestream`, `pq_gradient`, and `1x1_exif_xmp`, and add dedicated oracle-backed “known unsupported” characterization for the current spline/blending files — 2026-05-20 ~estimated EDT
- [ ] Ground-truth corpus follow-up: convert the new known-diff and known-unsupported buckets into true parity as features land, widen the passing bucket toward ICC/container/animation cases, and then start triaging the optional local `~/Pictures/big-desktops/` failures as real decoder-parity bugs instead of ad hoc manual probes
- [ ] Embedded ICC next parity slice: add a more inspectable decoder-side ICC metadata surface, or broaden GIF input further with staged sidecar extras / richer non-RGB embedded-profile animation cases

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
- [x] Brotli integration (C FFI) for BMFF metadata-box handling: add a tiny Zig wrapper over `brotli/decode.h` + `brotli/encode.h`, link the public library/tests/bench harnesses against Brotli, and use it for transparent `brob` decoder support plus compressed metadata-box emission — 2026-04-15 ~5:20 PM EDT

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
- [x] Add strict runtime decode benchmark harness (`bench_decode_runtime.zig`) and baseline-vs-`djxl` corpus benchmark — 2026-03-06 ~8:45 PM EST
- [x] Improve benchmark harness for profiling fidelity (`--repeat`, preload inputs, `c_allocator`) and capture hotspot sample + LLVM IR dump — 2026-03-06 ~8:50 PM EST
- [x] Split modular decode between retained `reference` and compile-time-specialized ANS/LZ77 reader strategies; add parity test, benchmark switch, and `x86_64` compile check; specialized path measured ~2% faster on the 6-file modular corpus — 2026-03-06 ~9:05 PM EST
- [x] Add per-filtered-tree property-use planning so the modular general-case loop only materializes properties that the filtered MA tree can read — 2026-03-06 ~9:45 PM EST
- [x] Benchmark property-use planning against checkpoint `df498e70`; keep it because the 6-file corpus improved from 209.3 ms to 204.6 ms (`~1.02x`) and the large-only subset improved from 287.4 ms to 284.3 ms (`~1.01x`) — 2026-03-06 ~9:45 PM EST
- [x] Re-profile the modular decode hotspot stack and keep a Zig-level weighted predictor loop-unrolling pass because it improved the 6-file corpus from 209.9 ms to 207.5 ms and the large-only subset from 286.4 ms to 284.0 ms (`~1.01x` on both) while preserving `x86_64` ReleaseFast compilation — 2026-03-06 ~10:07 PM EST
- [x] Validate TOC section boundaries, propagate multi-section section-reader errors, and add exact-pixel + truncation regression coverage for a real 3-group grayscale frame (`lossless_600x10_multisection.jxl`) — 2026-03-06 ~11:20 PM EST
- [x] Reject unsupported DC-global patches/splines/noise flags explicitly and size modular YCbCr channels to their chroma-subsampled dimensions before group decode — 2026-03-06 ~11:25 PM EST
- [x] Tighten weak decode/frame/weighted tests to assert exact values instead of conditional/non-asserting behavior, and re-verify `x86_64-macos` compilation — 2026-03-06 ~11:30 PM EST
- [x] Re-benchmark after the multi-section fix and confirm the old large-corpus baseline was invalid because multi-group channels were not actually being decoded (`grad_2048_raw.jxl` old baseline ended at `pLast=0/0/0`) — 2026-03-06 ~11:35 PM EST
- [x] Add a committed large RGB multi-group fixture (`lossless_600x300_multigroup_rgb.jxl`) with exact boundary-pixel regression coverage and include it in reference-vs-specialized decode parity tests — 2026-03-07 ~12:10 AM EST
- [x] Harden `bench_decode_runtime.zig` with sampled image fingerprints, known-fixture checksum verification, and explicit checksum-print/skip-verification switches so benchmarks fail on partial or zero decodes — 2026-03-07 ~12:15 AM EST
- [x] Make `zig build test` run the benchmark harness tests in addition to the library unit/integration suite — 2026-03-07 ~12:20 AM EST
- [x] Re-profile the corrected multi-group modular path, reject three losing weighted-predictor micro-optimizations, and keep a low-risk scanline row-slice hoist in `decodeModularChannelImpl` because stricter benchmarks showed it improving both the 600x300 fixture and the full committed corpus by about `~1%` while preserving `x86_64-macos` compilation — 2026-03-07 ~1:35 AM EST
- [x] Add a dedicated weighted-predictor microbenchmark harness (`bench_weighted_predict.zig`) with a stable synthetic-workload checksum and include its tests in `zig build test` so predictor-only changes can be evaluated without full-frame decode noise — 2026-03-07 ~12:25 AM EST
- [x] Specialize the weighted predictor hot path for trees that do not read the WP error property: add tested `predictNoWPProp`, route the modular decode loop through it when `PropertyUsePlan` says property 15 is unused, and keep it because the checked-in public-API benchmark improved the large multigroup case from about `1.206 s` to `1.188 s` while staying slightly ahead on the full corpus — 2026-03-07 ~8:15 AM EST
- [x] Trim `decodeGroup` scratch/copy overhead by pre-reserving per-group channel storage and hoisting copy extents out of the row loop; keep it because the public-API benchmark stayed slightly ahead on the full corpus while remaining within noise of upstream on the large multigroup case, and re-verify `x86_64-macos` builds — 2026-03-07 ~8:25 AM EST
- [x] Re-profile filtered-tree shapes on the committed corpus, add tests for a no-reference property-mask classifier, and keep a narrow mask-specialized modular decode path for the dominant `WP` property sets because it improved the large multigroup public-API benchmark from about `1.187 s` to `1.155 s` while widening the full-corpus lead to about `1.04x` and preserving `x86_64-macos` compilation — 2026-03-07 ~8:35 AM EST
- [x] Compact the hot no-reference filtered MA trees into tiny local property-slot spaces, add remap regression tests for lookup equivalence and zero-sentinel preservation, and keep it because a direct A/B against checkpoint `9183091c` improved the large multigroup public-API benchmark from `1.162 s` to `1.140 s` (`~1.02x`) while staying slightly ahead on the full corpus (`75.0 ms -> 74.6 ms`) and preserving `x86_64-macos` compilation — 2026-03-07 ~9:50 AM EST
- [x] Re-encode remapped no-reference mask trees into an inline compact node layout, add lookup-equivalence and small-storage fallback tests, and keep it because a direct A/B against checkpoint `9bfc415e` improved the large multigroup public-API benchmark from `1.139 s` to `1.084 s` (`~1.05x`) and the full corpus from `74.4 ms` to `72.1 ms` (`~1.03x`) while preserving `x86_64-macos` compilation — 2026-03-07 ~10:05 AM EST
- [ ] Generalize the MA-tree LUT fast path beyond `gradient_only` / `wp_only`, starting with any filtered tree that reads exactly one non-reference property
- [x] End-to-end lossless decode test (real JXL → exact pixel data) — 2026-03-06 ~11:20 PM EST
- [x] Multi-group frame decoding verification — 2026-03-06 ~11:20 PM EST

## Phase 4: Render Pipeline
- [ ] Inverse DCT (SIMD)
- [ ] Color transforms (XYB)
- [ ] Upsampling, noise, blending
- [ ] Pipeline assembly

## Phase 5: Decode API + CLI
- [x] Migrate the repo’s working/default branch from `main` to `yolo` in the safe two-branch form: create and push `yolo`, switch GitHub’s default branch, and retarget the checked-in GitHub Actions workflow + README badge so CI follows `yolo` instead of the old branch name — 2026-03-07 ~2:25 PM EST
- [x] First `libjxl`-shaped decoder C FFI compatibility slice: `JxlSignatureCheck`, `JxlDecoder{Create,Reset,Destroy,SubscribeEvents,SetInput,ReleaseInput,CloseInput,GetBasicInfo,ImageOutBufferSize,SetImageOutBuffer,ProcessInput}` with real external C smoke decode of `lossless_4x4.jxl` via upstream `jxl/decode.h` — 2026-03-07 ~11:10 AM EST
- [x] Add `djxlz`, a C CLI that dogfoods only the public C FFI, with `--help`, `--about`, `--output_format`, stdin/stdout path aliases, debug-build warning, and PPM/PGM/PAM output verified by CLI smoke tests — 2026-03-07 ~7:15 AM EST
- [x] Add the first narrow encoder-side public C FFI slice: `JxlEncoder{Create,Reset,Destroy,FrameSettingsCreate,SetBasicInfo,SetColorEncoding,AddImageFrame,CloseInput,ProcessOutput}`, `JxlEncoderInitBasicInfo`, and `JxlColorEncodingSetTo{SRGB,LinearSRGB}`, all thinly wrapping a pure Zig one-shot encoder core for 8-bit grayscale/RGB images, with external C smoke proving exact encode→decode pixel roundtrip through upstream `jxl/encode.h` and the existing `JxlDecoder` path — 2026-03-31 ~2:55 PM EDT
- [x] Add `cjxlz`, a C CLI that dogfoods only the new public `JxlEncoder` slice, keeps all parsing/I/O in C, currently accepts raw binary P5/P6 PNM via files or stdin/stdout aliases, and is verified by a CLI smoke test that round-trips a tiny RGB PPM through `cjxlz` + `djxlz` byte-for-byte — 2026-03-31 ~3:15 PM EDT
- [x] Check in a permanent public-API decode benchmark harness (`tests/benchmark/decode_public_api.c`) plus `./bm`, compile it against both `libjxlz_capi` and upstream `libjxl`, log benchmark history, and add a deterministic checksum smoke test — 2026-03-07 ~7:30 AM EST
- [x] Optimize the common C-API `UINT8` output path (RGB and grayscale expansion) and fix correct 8-bit scaling for high-bit-depth input; public-API benchmarks improved from `80.8 ms -> 76.2 ms` on the full corpus and `1.294 s -> 1.206 s` on the large multigroup case, reaching parity/slight lead vs upstream in the checked-in harness — 2026-03-07 ~7:40 AM EST
- [x] Add a repo-specific GitHub Actions workflow (`libjxlz_ci.yml`), keep Garnix on the existing flake checks, and update the README with repo-owned CI badges plus an upstream-facing optimization note and honest current project status — 2026-03-07 ~10:20 AM EST
- [x] Remove inherited upstream GitHub workflows so Actions only reports repo-owned `libjxlz CI` plus Garnix for this fork, instead of unrelated upstream C++/Pages/CodeQL jobs failing on every push — 2026-03-07 ~11:15 AM EST
- [x] Add a `NOTICE` file plus README attribution note clarifying that `libjxlz` is a derived Zig rewrite of `libjxl`, not a clean-room implementation, and that upstream/new material keep their respective credit — 2026-03-07 ~11:20 AM EST
- [x] Add the first encoder-side benchmark/profiling scaffold (`bench_modular_encode_prep.zig`) for modular predictor selection plus hybrid-uint tokenization, wire it into `zig build test`, `./test`, and `./bm`, and log the initial baseline (`1024x768x3`, repeat `24`: `1.1987 s`) — 2026-03-07 ~11:20 AM EST
- [x] Fix Linux CI for the encoder scaffold by keeping it pure-library (no `capi_root` import leak) and adding an `x86_64-linux` compile-only smoke check so `./test` catches libc-linkage regressions before push — 2026-03-07 ~11:30 AM EST
- [x] Add `x86_64-windows-gnu` compile-only coverage via a checked-in smoke test, wire it into `./test`, and expose it through the Linux flake checks so both GitHub Actions and Garnix catch Windows portability regressions early — 2026-03-07 ~12:05 PM EST
- [x] Investigate `bad_conversion_samples/*` producing apparently black JPEG XL outputs via the external `jpegxl` wrapper / `cjxl`; confirm the files are valid, `djxl`/`sips`/Preview decode them correctly, and narrow the black-screen issue to Finder Quick Look on grayscale JXL rather than a core encoder/decoder bug — 2026-03-07 ~12:35 PM EST
- [ ] Conformance tests

## Phase 6: Encoder
- [ ] Forward DCT + quantization
- [ ] ANS encoder
- [x] ANS encoder slice: add `encodeUintConfig(s)` using the new `BitWriter`, with mixed and exhaustive roundtrip coverage against `dec_ans.decodeUintConfigs`, so the entropy writer can emit real HybridUint metadata before full histogram/token support exists — 2026-03-07 ~2:10 PM EST
- [x] ANS encoder slice: add `storeVarLenUint8/16` with exhaustive roundtrip coverage against the decoder-side varlen readers, so histogram-header metadata can be written and unit-tested independently before larger ANS assembly work — 2026-03-07 ~2:20 PM EST
- [x] ANS encoder foundation: add `SizeWriter` and make the current metadata writers generic over counting vs real output, with tests proving its bit counts match `BitWriter` exactly for varlen integers and uint-config metadata — 2026-03-07 ~2:30 PM EST
- [x] ANS encoder foundation: add `Token`, `ANSEncSymbolInfo`, an alias-table-backed info-table builder, and `ANSCoder.putSymbol`, with tests that compare the reciprocal fast path against a direct division-based reference step and cover the empty-stream fallback symbol — 2026-03-07 ~2:40 PM EST
- [x] ANS encoder slice: add a minimal single-histogram token-stream writer that emits real ANS state + reversed bit payloads, with decoder roundtrip tests covering both direct-token and extra-bit `HybridUintConfig` cases — 2026-03-07 ~2:50 PM EST
- [x] ANS encoder slice: add the smallest `decodeHistograms`-compatible metadata writer for one-context degenerate histograms (LZ77 disabled, ANS mode, one uint config, simple-code single symbol), with roundtrip assertions on `context_map`, `uint_config`, and `degenerate_symbols` — 2026-03-07 ~3:30 PM EST
- [x] ANS encoder slice: add the smallest non-degenerate `decodeHistograms` bundle writer (one context, two-symbol simple histogram) and prove exact recovered frequencies from the alias table after decode, so shared multi-context histogram plans now have a tested mixed-symbol building block — 2026-03-07 ~3:50 PM EST
- [x] ANS encoder slice: add a one-context flat-histogram bundle writer and prove exact recovered flat frequencies from `decodeHistograms`, so local channel streams can widen beyond degenerate/two-symbol cases without a full histogram encoder — 2026-03-08 ~12:15 AM EST
- [x] Context-map encoder slice: add the smallest multi-context writer (`is_simple=1`, `bits_per_entry=0`) and prove it round-trips through `decodeContextMap` for a six-entry all-zero map, so future tree/histogram writers have the first real multi-context metadata primitive — 2026-03-07 ~3:40 PM EST
- [x] Frame-shell encoder slice: add a no-permutation TOC writer and prove it round-trips through `toc.readToc` for both single-entry and mixed-size multi-entry tables, so frame-level work can focus on section payload composition instead of size packing — 2026-03-08 ~12:45 AM EST
- [x] Frame-shell encoder slice: add a borrowed-header frame wrapper that copies a proven grayscale frame-header bit prefix, appends our generated TOC and DC-global section, and prove a full `FrameDecoder.decodeFrame` grayscale image roundtrip on a `3x3` `.gradient` image — 2026-03-08 ~1:00 AM EST
- [x] Codestream-shell encoder slice: add a raw `SizeHeader` writer plus a borrowed-metadata codestream wrapper, and prove a complete grayscale codestream roundtrip (marker → headers → `FrameDecoder.decodeFrame`) on a `3x3` `.gradient` image — 2026-03-08 ~1:15 AM EST
- [x] Modular encoder slice: widen the fully local single-leaf group writer from one grayscale channel to multi-channel images by concatenating per-channel token streams under the same local tree/histogram, and prove a `3x2` RGB roundtrip through `encoding.modularDecode` — 2026-03-09 ~2:50 PM EST
- [x] Codestream-shell encoder slice: prove the borrowed metadata + borrowed frame-header shell also works for color by round-tripping a `3x2` RGB codestream through full header parsing and `FrameDecoder.decodeFrame` — 2026-03-09 ~3:00 PM EST
- [x] Frame-shell encoder slice: replace borrowed frame-header bits for the simple modular grayscale/RGB path with a native Zig `writeFrameHeader` + `writeFrame`, prove exact bit matches against committed fixture headers, and re-run both grayscale and RGB borrowed-metadata codestream roundtrips through the native frame writer — 2026-03-09 ~7:20 PM EST
- [x] Modular encoder slice: add single-channel single-node grayscale tokenization for non-weighted predictors, with exact token assertions for `zero` and `gradient` paths so modular residual generation is proven before bitstream assembly — 2026-03-07 ~3:00 PM EST
- [x] Modular encoder slice: bridge single-node grayscale tokenization into the ANS writer and prove an end-to-end gradient-channel roundtrip by reconstructing decoded pixels through the existing predictor path, so the first writable modular stream is validated before broader encoder assembly — 2026-03-07 ~3:10 PM EST
- [x] Modular encoder slice: add the smallest real modular group writer in global-tree mode (default WP header, no transforms) and prove it round-trips through `encoding.modularDecode` with an injected one-leaf tree/histogram, so encoder work now crosses from token streams into a decodable modular group surface — 2026-03-07 ~3:20 PM EST
- [x] MA-tree encoder slice: add the smallest real tree writer (single leaf, zero offset, multiplier 1) using a simple all-zero tree context map plus a shared histogram, and prove it round-trips through `dec_ma.decodeTree` for `Predictor.gradient` — 2026-03-07 ~4:00 PM EST
- [x] Modular encoder slice: add the first fully local modular group roundtrip (`use_global_tree=0`) for a `1x1` zero pixel using a single-leaf `.zero` MA tree and degenerate channel histogram, and prove it decodes through `encoding.modularDecode` without any injected tree/code/context map — 2026-03-07 ~4:10 PM EST
- [x] Modular encoder slice: widen the fully local local-tree roundtrip from the degenerate `1x1` case to a non-degenerate `2x2` `.zero`-predictor tile by switching channel histograms to the new flat one-context writer, while keeping the old minimal zero-pixel case green — 2026-03-08 ~12:20 AM EST
- [x] Modular encoder slice: prove the widened fully local local-tree path is predictor-generic enough for a non-zero leaf by round-tripping a `3x3` `.gradient` tile through `encoding.modularDecode` without any injected state — 2026-03-08 ~12:30 AM EST
- [ ] Modular encoder
- [x] Encoder bit-writer foundation: add `src/lib/base/bit_writer.zig` with LSB-first write + byte-pad semantics and roundtrip it against the existing `BitReader`, so future ANS/modular writer work has a real writable primitive instead of the synthetic prepass scaffold alone — 2026-03-07 ~1:55 PM EST
- [x] Replace synthetic encoder-prepass benchmarking as the repo’s primary encode signal with a real narrow lossless modular encode harness (`bench_modular_encode_codestream.zig`) built on the working `600x300` multi-group RGB codestream path, with checksum smoke coverage and source-controlled benchmark history — 2026-03-09 ~9:05 PM EST
- [ ] Frame encoder
- [x] Replace borrowed metadata bits with native Zig `ImageMetadata` / `CustomTransformData` writers for the simple modular grayscale/RGB codestream path, prove exact metadata-bit matches on the committed grayscale/RGB fixtures, and rerun both full codestream roundtrips through the native shell — 2026-03-09 ~8:05 PM EST
- [x] Widen the native codestream writer from tiny single-group fixtures to a real multi-group RGB image by emitting repeated local modular group sections and proving full `FrameDecoder.decodeFrame` pixel equality on a `600x300` image — 2026-03-09 ~8:35 PM EST
- [x] Profile the real `bench_modular_encode_codestream` hotspot stack, identify `enc_ans.writeSingleHistogramTokens` / `addReversedBits` as the first encode bottleneck, and keep two successive packing-buffer simplifications there (paired arrays -> chunk buffer, then `ArrayList` -> fixed-capacity chunk slice) because the real encode harness improved from about `11.35 ms` to about `10.27 ms` (`~1.10x`) after the benchmark baselines were re-accepted — 2026-03-09 ~9:35 PM EST
- [x] Re-profile the real encode harness after the token-packing win, add a cache-backed flat-histogram info-table path for repeated cropped RGB tiles, and keep it because the real `600x300` multi-group encode harness improved from about `10.27 ms` to about `10.00 ms` (`~1.03x`) while preserving exact checksum/codestream roundtrips — 2026-03-09 ~9:35 PM EST
- [x] Re-profile again after the histogram-cache win, add `BitWriter.ensureUnusedCapacityBits`, and use it to reserve the full ANS chunk flush before `writeSingleHistogramTokens` writes state/chunks so repeated bit-writer growth stops dominating the hot loop; keep it because the real `600x300` multi-group encode harness improved from about `10.00 ms` to about `9.81 ms` (`~1.02x`) with full tests and checksum stability preserved — 2026-03-09 ~9:40 PM EST
- [x] Re-profile again after the bit-writer reservation win, remove the temporary tile-copy step from `writeSingleNodeLocalTreeGroupImageRectWithCache` by tokenizing source rects directly, and keep it because the real `600x300` multi-group encode harness improved from about `9.81 ms` to about `9.59 ms` (`~1.02x`) while preserving cropped-rect and full-codestream roundtrip coverage — 2026-03-09 ~9:45 PM EST
- [x] Pivot the encoder toward direct upstream modular transliteration by porting `TokenizeTree` from upstream `enc_ma.cc`, widening `enc_ma.zig` from a single-leaf special case to a generic MA-tree writer, and keep it because split-tree roundtrip coverage is now real and the accepted `./bm` encode baseline improved from about `9.59 ms` to about `9.36 ms` (`~1.02x`) while the first run came in at `8.95 ms` and tripped the perf-shift guard — 2026-03-10 ~5:20 PM EST
- [x] Continue the upstream modular encoder transliteration by porting `MakeFixedTree` / `PredefinedTree` from `enc_encoding.cc`, extending `options.zig` with encoder-side `TreeKind`/`TreeMode`, and proving the generated fixed-tree path both structurally and through the existing injected-global-tree roundtrip (`gradient_fixed_dc`) — 2026-03-11 ~6:35 PM EDT
- [x] Replace global-tree injection on the narrow multigroup RGB path by adding a real multi-context all-zero histogram bundle writer, a DC-global writer for encoded MA trees + shared histograms + empty global modular images, and a global-tree group writer for multichannel rect payloads; prove it with a full `600x300` codestream roundtrip that carries an encoded `gradient_fixed_dc` tree through `FrameDecoder` — 2026-03-11 ~7:05 PM EDT
- [x] Move beyond the all-contexts-map-to-histogram-0 shortcut by adding direct simple context-map writing, multi-flat-histogram bundle writing, contextual ANS token writing, and a full `600x300` codestream roundtrip with a channel-split global MA tree that uses two different histogram contexts during decode — 2026-03-12 ~12:05 AM EDT
- [x] Port the first real per-pixel MA-tree encoder loop subset by adding a no-WP/no-reference global-tree tokenizer for group rects, then prove it with exact token-context assertions plus both `modularDecode` and full `600x300` codestream/frame roundtrips through tree-driven global histogram contexts — 2026-03-13 ~12:10 AM EDT
- [x] Extend that per-pixel MA-tree encoder subset to default-weighted no-reference trees, with a manual weighted-state tokenization check plus a direct `modularDecode` roundtrip for a weighted-leaf global tree — 2026-03-13 ~12:30 AM EDT
- [x] Extend the per-pixel MA-tree encoder subset to rect-local reference properties (still no weighted state), with exact context assertions for a previous-channel value split, a direct `modularDecode` roundtrip on a 2-channel image, and a full `600x300` RGB codestream/frame roundtrip whose group payloads branch on previous-channel values — 2026-03-13 ~1:05 AM EDT
- [ ] Re-profile the real encode harness after the token-packing win and choose the next hotspot from measured data rather than the old synthetic prepass
- [x] Combine the now-separate weighted and reference-property MA-tree encoder slices so trees that need both WP state and previous-channel properties drive one shared per-pixel tokenization path, with exact token checks on a 2-channel weighted/reference split tree plus both direct `modularDecode` and full `600x300` RGB codestream/frame roundtrips — 2026-03-14 ~10:45 AM EDT
- [x] Replace flat-only ANS histogram placeholders with an exact non-flat histogram foundation: normalize raw token frequencies onto the 4096-entry ANS table, serialize one- and multi-context normalized histograms through `decodeHistograms`, and add a contextual histogram-bundle builder that turns a token stream + simple context map into reusable normalized counts plus ANS info tables — 2026-03-14 ~12:20 PM EDT
- [x] Wire those exact histogram bundles into the real global-tree codestream path, add direct multigroup/global-section regression tests, and fix the hidden MA-tree leaf-context mismatch by canonicalizing emitted trees to decoder breadth-first leaf order before bundle-building and exact-histogram codestream emission — 2026-03-15 ~9:45 AM EDT
- [x] Coalesce identical exact histograms after normalization, carry the clustered `bundle.context_map` through exact-histogram DC-global/group emission, and keep direct-section plus full-suite coverage green so the encoder no longer assumes “one logical context == one emitted histogram” — 2026-03-16 ~9:35 PM EDT
- [x] Add an upstream-shaped encoder histogram cost foundation (`Histogram`, Shannon entropy, merge distance) with focused exact-value tests, so future clustering decisions can be based on measured data-cost deltas instead of ad hoc heuristics — 2026-03-16 ~9:50 PM EDT
- [x] Port the first real `EncodeContextMap` choice layer: add encoder-side move-to-front transform plus exact bit-cost selection between simple direct entries, raw ANS, and MTF+ANS for context maps, with focused “must stay simple” and “must choose MTF” tests and full-suite verification — 2026-03-16 ~10:05 PM EDT
- [x] Wire the new context-map chooser into the DC-global flat/exact histogram writers, add a 9-histogram normalized roundtrip through `decodeHistograms`, and re-run `./bm` to confirm the current narrow encoder path stays in-range — 2026-03-16 ~10:25 PM EDT
- [x] Port the next upstream histogram-planning slice beyond exact-duplicate coalescing: cost-based histogram merging and less-naive context-map encoding (`BuildAndEncodeHistograms` / `EncodeContextMap`), using a greedy same-`HybridUintConfig` negative-cost merge pass on top of the new exact histogram/context-map cost model; kept with full-suite green and an accepted narrow encode benchmark shift from `0.009936822875000001 s` to `0.009559646125 s` (`~1.04x`) — 2026-03-27 ~02:38 PM EDT
- [x] Port the next upstream histogram-planning slice beyond greedy same-config pair merges: add a fixed-seed reassignment pass so original logical histograms can move onto the cheapest surviving emitted histogram after the greedy merge stage, then rebuild clustered histograms from that reassigned mapping; kept with full-suite green and benchmark runs still in-range (`full_corpus` `~1.10x` faster than upstream, `large_multigroup_rgb` `~1.09x`, narrow encode baseline `0.009559646125 s -> 0.009957369750000002 s`, under the 5% guard) — 2026-03-27 ~02:56 PM EDT
- [x] Port the next upstream histogram-planning slice beyond one-shot fixed-seed reassignment: add upstream-shaped fast seed selection before merge/reassignment so emitted histogram sets are seeded by the largest/farthest histograms instead of only by surviving greedy merges; kept with full-suite green and an accepted narrow encode benchmark shift from `0.009957369750000002 s` to `0.010301609250000001 s` (within the 5% guard) — 2026-03-27 ~04:30 PM EDT
- [x] Port the first upstream-shaped adaptive uint-config slice after clustering: choose the emitted `HybridUintConfig` per final histogram from raw clustered values instead of blindly preserving the caller-supplied config, with brute-force exact-cost tests plus bundle/codestream regression coverage; kept with full-suite green and an accepted narrow encode benchmark shift from `0.010301609250000001 s` to `0.010297015500000001 s` (effectively neutral) — 2026-03-27 ~05:15 PM EDT
- [x] Port the next upstream entropy-planning slice: build/cluster raw-value histograms before uint-config choice so histogram clustering is no longer constrained by pre-encoded token alphabets or same-config families; kept with full-suite green and an accepted narrow encode benchmark shift from `0.010297015500000001 s` to `0.009420505249999999 s` (`~1.09x`) — 2026-03-28 ~12:20 PM EDT
- [x] Port the next upstream histogram-planning slice on top of raw-value clustering: switch surviving-seed reassignment from raw population-growth delta to KL divergence against the seed histograms, add a concrete counterexample where the old metric chose the wrong coding seed, and keep it with full-suite green plus accepted benchmark runs still in-range (`full_corpus` `0.07134394262500002 s` vs upstream `0.07677562 s`, `large_multigroup_rgb` `1.089826354125 s` vs `1.1728888127500001 s`, narrow encode `0.009882823249999999 s`) — 2026-03-28 ~1:25 PM EDT
- [x] Port the first encode-side modular transform slice: add exact forward YCoCg RCT support plus a narrow DC-global writer that emits one modular RCT transform, then prove a full `600x300` RGB codestream roundtrip where the encoder tokenizes transformed channels and the normal decoder undoes the transform back to exact RGB pixels; kept with full-suite green and accepted benchmark runs still in-range (`full_corpus` `0.070934583375 s` vs upstream `0.07700118775 s`, `large_multigroup_rgb` `1.0788072343750001 s` vs `1.1602977500000002 s`, narrow encode `0.009708078125 s`) — 2026-03-28 ~2:05 PM EDT
- [ ] Port the next upstream histogram-planning slice beyond KL reassignment: iterative refinement / re-seeding so the emitted histogram set can change after the first KL-based assignment pass
- [x] Port the next encode-side modular transform foundation after RCT: add exact forward horizontal/vertical squeeze plus `fwdSqueeze`, and prove it round-trips exactly through the existing inverse squeeze path on a deterministic single-channel image; kept with focused squeeze tests and full `./test` green — 2026-03-29 ~9:15 AM EDT
- [x] Port the next encode-side modular transform slice after the squeeze foundation: wire a narrow forward-squeezed grayscale image through a real encoded modular stream/codestream roundtrip, using a local single-leaf tree plus explicit squeeze metadata in the modular group header so `FrameDecoder` replays `metaApply`/`undoTransforms` and recovers the exact original pixels — 2026-03-29 ~10:20 AM EDT
- [x] Port the next encode-side modular transform slice after narrow squeeze coverage: add a minimal explicit grayscale palette transform writer plus exact transform/codestream roundtrips so the second major lossless modular transform family is no longer decode-only on its simplest path — 2026-03-29 ~10:45 AM EDT
- [x] Broaden the narrow palette encode path beyond explicit grayscale/zero-delta mode: support a multi-channel explicit palette codestream roundtrip so RGB palette transforms are no longer decode-only on their simplest path — 2026-03-29 ~11:05 AM EDT
- [x] Broaden palette beyond explicit zero-delta mode: add a grayscale delta/predictor palette roundtrip (`left` + one delta entry) at both transform and codestream scope, and fix decode-side palette indexing to use the full palette width so delta-prefixed palettes reconstruct correctly — 2026-03-29 ~11:25 AM EDT
- [x] Broaden palette beyond grayscale delta mode: add a multi-channel delta/predictor palette roundtrip so RGB delta palettes are no longer decode-only on the narrow `left`-predictor path — 2026-03-29 ~11:40 AM EDT
- [x] Move beyond explicit/delta narrow palette coverage into the first heuristic palette-construction slice: deterministically choose the most common residual tuples as auto-delta entries and prove the result on a tiny RGB transform plus codestream roundtrip — 2026-03-29 ~11:55 AM EDT
- [x] Add the first implicit-palette encode slice: let `fwdPalette` emit decoder-native implicit RGB colors without materializing explicit palette rows, including the all-implicit codestream case with `nb_colors == 0` — 2026-03-29 ~12:20 PM EDT
- [x] Extend implicit-color reuse into the delta/auto-delta palette path: let `fwdPaletteWithDeltas` keep delta matches first, then reuse decoder-native implicit colors before falling back to explicit rows, including an RGB codestream that mixes implicit colors with one explicit delta entry — 2026-03-29 ~12:35 PM EDT
- [x] Port the first upstream-style implicit-color selection heuristic: promote very frequent implicit RGB colors into explicit palette rows so they get short indexes instead of always staying implicit — 2026-03-29 ~12:50 PM EDT
- [x] Port the first explicit-color ordering heuristic: sort plain RGB palette rows by luma instead of raw image order, remap indices accordingly, and keep exact roundtrip coverage — 2026-03-29 ~1:05 PM EDT
- [x] Extend luma ordering into the delta/auto-delta explicit-fallback rows, keeping delta matches first while reordering only the surviving explicit RGB palette rows — 2026-03-29 ~1:15 PM EDT
- [x] Port the first richer auto-delta discovery step: bucket nearby residual tuples before ranking them, then emit the strongest exact tuple inside the winning bucket so dense neighborhoods beat unrelated first-seen singletons — 2026-03-30 ~12:05 AM EDT
- [x] Continue palette-construction parity toward upstream `enc_palette.cc`: keep bucket population as the primary auto-delta signal, but break ties by rounded-delta magnitude so equally dense buckets no longer fall back to first-seen order; proved with a new grayscale counterexample while keeping the existing RGB auto-delta regression green — 2026-03-30 ~1:10 AM EDT
- [ ] Continue palette-construction parity toward upstream `enc_palette.cc`: move beyond count-first bucket ranking by incorporating real residual-distance weighting into auto-delta discovery, closer to upstream `FindFrequentColorDeltas`
- [x] Widen the native codestream writer beyond RGB-only metadata: add the smallest write-side extra-channel slice by supporting one default 8-bit alpha `ExtraChannelInfo`, prove it with both metadata-level roundtrip coverage and a full `3x2` RGBA codestream/frame roundtrip through `FrameDecoder`, and keep it with a fresh accepted `./bm` run (`full_corpus` `0.069937172s` vs upstream `0.077249651s`, `large_multigroup_rgb` `1.0704175835s` vs `1.188056177s`, narrow encode `0.00934890625s`) — 2026-03-30 ~5:45 PM EDT
- [x] Broaden the narrow write-side extra-channel surface from all-default alpha to explicit associated alpha: emit the non-default alpha `ExtraChannelInfo` form, prove it with both metadata roundtrip coverage and a full `3x2` RGBA codestream/frame roundtrip through `FrameDecoder`, and keep it with a clean accepted `./bm` rerun (`full_corpus` `0.06962615112500001s` vs upstream `0.07556896349999999s`, `large_multigroup_rgb` `1.0637188333749998s` vs `1.157124427s`, narrow encode `0.009225265750000001s`) — 2026-03-31 ~8:25 AM EDT
- [x] Repair the local native build/test/benchmark entrypoints on macOS by routing `./build`, `./test`, and `./bm` through flake-backed package/check outputs instead of native `zig build`, wiring `build.zig` install artifacts into Zig's default install step, and retargeting CLI smoke scripts at flake-built artifacts so the full suite is green again on this host — 2026-03-31 ~8:35 AM EDT
- [x] Extend the extra-channel path to subsampled alpha: prove metadata roundtrip for an explicit alpha with `dim_shift = 1`, teach the decoder to apply `ExtraChannelInfo.dim_shift` before modular token decode, and keep a full `4x2` RGB + `2x1` alpha codestream/frame roundtrip plus accepted `./bm` numbers (`full_corpus` `0.06912589075s` vs upstream `0.07455769787500001s`, `large_multigroup_rgb` `1.055974218875s` vs `1.15204722375s`, narrow encode `0.009094807250000001s`) — 2026-03-31 ~9:10 AM EDT
- [x] Broaden the narrow write-side extra-channel surface beyond alpha-only metadata: support the plain shared-field extra-channel family (`selection_mask`, `depth`, `black`, `thermal`, `optional`) while still rejecting spot/CFA/reserved forms, prove it with metadata roundtrips for `selection_mask` and subsampled `depth`, and keep full codestream/frame roundtrips for a full-size `selection_mask` plane plus a `4x2` RGB + `2x1` subsampled `depth` plane alongside accepted `./bm` numbers (`full_corpus` `0.070226432375s` vs upstream `0.07914932800000002s`, `large_multigroup_rgb` `1.074479364625s` vs `1.1953739845s`, narrow encode `0.009186921625s`) — 2026-03-31 ~10:05 AM EDT
- [x] Broaden the extra-channel writer into the first conditional-payload form: add `spot_color` support with a real `F16Coder.write`, prove metadata roundtrip of the four half-float colorants, and keep a full `3x2` RGB + spot-color codestream/frame roundtrip plus accepted `./bm` numbers (`full_corpus` `0.07045454174999999s` vs upstream `0.079049307375s`, `large_multigroup_rgb` `1.072570651125s` vs `1.1788242656249999s`, narrow encode `0.009157171875s`) — 2026-03-31 ~10:25 AM EDT
- [x] Finish the remaining practical conditional extra-channel form on the narrow writer: add `cfa` metadata/codestream coverage by serializing `cfa_channel`, proving a focused metadata roundtrip plus a full `3x2` RGB + CFA codestream/frame roundtrip, and keep accepted `./bm` numbers (`full_corpus` `0.07046635437500001s` vs upstream `0.079833552s`, `large_multigroup_rgb` `1.074264020625s` vs `1.198401473875s`, narrow encode `0.009337572875s`) — 2026-03-31 ~10:45 AM EDT
- [x] Pivot outward from the now-broader metadata surface by starting the encode C FFI slice first: add a narrow `JxlEncoder`-shaped one-shot path backed by a pure Zig encoder core, prove it with a real external C smoke roundtrip, then expose it through the first `cjxlz` C CLI — 2026-03-31 ~3:15 PM EDT
- [ ] Fast lossless encoder
- [x] C FFI encode API — narrow one-shot `JxlEncoder` slice for 8-bit grayscale/RGB, later widened to the first alpha-capable public path so callers can encode gray/gray+alpha/RGB/RGBA images entirely through the libjxl-shaped C surface and round-trip them through the existing decoder API — 2026-03-31 ~4:05 PM EDT
- [x] cjxlz CLI — narrow raw binary P5/P6 encoder CLI through the public C FFI, with `--help`, `--about`, stdin/stdout aliases, and exact RGB roundtrip smoke coverage through `djxlz` — 2026-03-31 ~3:15 PM EDT
- [x] Broaden the first encode-side public API/CLI slice beyond grayscale/RGB-only: let the pure Zig encoder core accept gray+alpha / RGBA, allow one 8-bit alpha extra channel in the public `JxlEncoder` surface, widen `cjxlz` input to narrow `P7` PAM (`GRAYSCALE`, `RGB`, `GRAYSCALE_ALPHA`, `RGB_ALPHA`), and prove it with exact Zig/C/CLI alpha roundtrips; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07088505212500001s` vs upstream `0.07684763012500001s`, `large_multigroup_rgb` `1.078952739625s` vs `1.1671430468750001s`, narrow encode `0.009748947875000002s`) — 2026-03-31 ~4:05 PM EDT
- [x] Broaden the public one-shot `JxlEncoder` slice beyond alpha-only extras: add `JxlEncoderInitExtraChannelInfo`, `JxlEncoderSetExtraChannelInfo`, `JxlEncoderSetExtraChannelName`, and `JxlEncoderSetExtraChannelBuffer`, stage color and extra planes separately in the C API, finalize them into the pure Zig encoder path at `ProcessOutput` time, and prove a full-size `selection_mask` roundtrip through both Zig tests and an external C smoke compiled against upstream `jxl/encode.h`; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07185275525s` vs upstream `0.077099348875s`, `large_multigroup_rgb` `1.0862495105s` vs `1.166939947625s`, narrow encode `0.009629880125000002s`) — 2026-03-31 ~01:26 PM EDT
- [x] Broaden that staged extra-channel public path from one non-alpha plane to multiple full-size uint8 extras, relax the pure Zig encoder façade to accept more than one supplied `ExtraChannelInfo`, and fix the underlying metadata decoder bug where multiple decoded extra-channel names aliased the last local stack buffer; proved with new Zig roundtrips for `selection_mask + thermal`, a metadata-only multi-extra regression, and an external C smoke compiled against upstream `jxl/encode.h`, with accepted `./bm` numbers (`full_corpus` `0.071258969s` vs upstream `0.07705826062500001s`, `large_multigroup_rgb` `1.08577576575s` vs `1.170176562375s`, narrow encode `0.009356625250000002s`) — 2026-03-31 ~01:38 PM EDT
- [x] Broaden that staged public `JxlEncoder` path to mixed interleaved alpha plus sidecar uint8 extras, so libjxl-style `alpha_bits` still reserves public extra index `0` for the interleaved alpha plane while later extra indexes can carry staged metadata/buffers like `selection_mask`; proved with a new Zig roundtrip for `RGBA + mask`, an external C smoke compiled against upstream `jxl/encode.h`, and accepted `./bm` numbers (`full_corpus` `0.072271823s` vs upstream `0.0781825835s`, `large_multigroup_rgb` `1.0877649845000001s` vs `1.169714401125s`, narrow encode `0.009493708250000002s`) — 2026-03-31 ~01:50 PM EDT
- [x] Broaden `cjxlz` beyond a single raw PNM/PAM image by adding repeated `--extra TYPE PATH` sidecar inputs for the current full-size uint8 extra-channel family (`selection_mask`, `depth`, `black`, `thermal`, `optional`), piping them through the existing staged `JxlEncoder` public API while keeping all codestream logic in Zig; proved with a new CLI smoke that round-trips RGB pixels through `djxlz` and checks `JxlDecoderGetBasicInfo` reports one extra channel for `--extra selection_mask` — 2026-03-31 ~02:05 PM EDT
- [x] Prove the widened CLI and public encoder API stay aligned on the mixed-alpha path by adding an end-to-end `cjxlz` smoke for `RGB_ALPHA + --extra selection_mask`, verifying `djxlz` round-trips the PAM color+alpha pixels and `JxlDecoderGetBasicInfo` reports `alpha_bits = 8` with two total extra channels — 2026-03-31 ~02:15 PM EDT
- [x] Broaden the public encode surface into the first parameterized conditional extra-channel form by proving `spot_color` through both the staged `JxlEncoder` API and `cjxlz`: add a Zig roundtrip that asserts the four spot-color metadata floats survive the public C API path, and widen `cjxlz --extra` to accept `spot_color:R,G,B,S PATH` while keeping the main image round-trip and extra-channel count green in CLI smoke coverage — 2026-03-31 ~02:42 PM EDT
- [x] Broaden the staged public encode surface to the remaining currently practical narrow extra-channel forms by adding `cfa` metadata/buffer coverage to the `JxlEncoder` path, widening `cjxlz --extra` to accept `cfa:N`, and proving both via Zig/API/CLI roundtrips plus `JxlDecoderGetExtraChannelInfo` inspection — 2026-03-31 ~11:45 PM EDT
- [x] Broaden the staged public encode surface from full-size uint8 sidecars to the first subsampled sidecar path by allowing `dim_shift` on plain extras, plumbing it through the pure Zig packed encode façade, widening `cjxlz --extra` to accept `TYPE:SHIFT`, and proving a `depth:1` roundtrip through Zig/API/CLI plus decoded extra-info inspection — 2026-04-01 ~12:20 AM EDT
- [x] Broaden the staged public encode surface so alpha no longer has to arrive interleaved: allow a full-size staged alpha plane at public extra index `0`, keep the implicit alpha metadata model from `JxlBasicInfo`, reject ambiguous “interleaved alpha plus staged alpha” input, and prove it through Zig unit tests, an external C smoke, and a `cjxlz --extra alpha PATH` CLI roundtrip; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07141127087499999s` vs upstream `0.07735605737500001s`, `large_multigroup_rgb` `1.084048145875s` vs `1.171238677125s`, narrow encode `0.009394244875000003s`) — 2026-04-01 ~1:10 AM EDT
- [x] Broaden the public encode/CLI metadata surface so associated alpha is no longer hidden behind the raw C API only: add `cjxlz --premultiplied-alpha` / `--associated-alpha`, prove the flag through an external C smoke using `JxlBasicInfo.alpha_premultiplied = 1`, and extend the CLI extra-channel helper so smoke tests can assert decoded `alpha_premultiplied` metadata directly; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07038834375000001s` vs upstream `0.0753836875s`, `large_multigroup_rgb` `1.063174109375s` vs `1.1558806876249998s`, narrow encode `0.009132859250000002s`) — 2026-04-01 ~1:35 AM EDT
- [x] Broaden alpha metadata at public extra index `0` beyond the old synthesized default: allow `JxlEncoderSetExtraChannelInfo/Name(enc, 0, ...)` for alpha when it matches `JxlBasicInfo`, thread that explicit alpha metadata through the pure Zig packed encoder core, add a Zig regression that asserts the encoded alpha name and `alpha_associated` flag survive metadata parsing, add an external C smoke that calls the public alpha-info/name setters directly, and dogfood it from `cjxlz --alpha-name`; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07111444250000001s` vs upstream `0.077882734375s`, `large_multigroup_rgb` `1.078989901375s` vs `1.169321922s`, narrow encode `0.00921229175s`) — 2026-04-01 ~2:20 AM EDT
- [x] Complete the decode-side half of named extra-channel metadata parity by exporting `JxlDecoderGetExtraChannelName`, then tighten the named-alpha external C smoke and `cjxlz --alpha-name` CLI smoke so they assert the decoded UTF-8 extra name instead of only the pixels; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07182824475s` vs upstream `0.07734604162500001s`, `large_multigroup_rgb` `1.07292117725s` vs `1.1715544373750002s`, narrow encode `0.009396557500000001s`) — 2026-04-01 ~2:40 AM EDT
- [x] Fix the Linux CI regression in `cjxlz` spot-color parsing by replacing the POSIX-only `strtok_r` use with a tiny C11-portable comma parser, keeping the existing spot-color CLI smoke green and rerunning the full suite plus benchmarks from a clean state; accepted `./bm` numbers were `full_corpus` `0.070865625125s` vs upstream `0.076802473875s`, `large_multigroup_rgb` `1.079144948s` vs `1.1710964427500001s`, narrow encode `0.009413281250000002s` — 2026-04-01 ~1:15 PM EDT
- [x] Broaden the first public metadata/frame slice beyond alpha naming by carrying non-default tone mapping through the full encode path: teach `writeImageMetadata` to emit tone-mapping-only `extra_fields`, thread `JxlBasicInfo.{intensity_target,min_nits,relative_to_max_display,linear_below}` through the pure Zig packed encoder and public `JxlEncoder` API, add an external C smoke that round-trips those fields through `JxlDecoderGetBasicInfo`, and dogfood them from `cjxlz` via `--intensity-target`, `--min-nits`, `--relative-to-max-display`, and `--linear-below`; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.07086740625s` vs upstream `0.07675735925s`, `large_multigroup_rgb` `1.086012765625s` vs `1.1656721095s`, narrow encode `0.009285838625s`) — 2026-04-01 ~1:45 PM EDT
- [x] Broaden that same public metadata/frame slice to carry simple orientation and intrinsic-size metadata end-to-end: add native `headers.writeSizeHeader`, widen `writeImageMetadata` to emit orientation plus intrinsic size before tone mapping, thread `JxlBasicInfo.{orientation,intrinsic_xsize,intrinsic_ysize}` through the pure Zig packed encoder and public `JxlEncoder` API, add an external C smoke that round-trips those fields through `JxlDecoderGetBasicInfo`, and dogfood them from `cjxlz` via `--orientation` and `--intrinsic-size`; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.071414119625s` vs upstream `0.076385474125s`, `large_multigroup_rgb` `1.0967419843750001s` vs `1.1960524166250002s`, narrow encode `0.009430500125000001s`) — 2026-04-01 ~3:25 PM EDT
- [x] Broaden the staged alpha public-encode path from full-size only to the first subsampled alpha surface: allow `dim_shift` on public alpha metadata at extra index `0`, carry that through the pure Zig packed encoder and staging helper, reject only the incompatible interleaved+subsampled alpha combination, add an external C smoke for `JxlEncoderSetExtraChannelInfo(... alpha.dim_shift = 1 ...)`, and dogfood it from `cjxlz --extra alpha:1 PATH`; kept with full `./test` green, while `./bm` was rerun but left unaccepted because the decode machine timings were too noisy to use as a meaningful performance signal — 2026-04-01 ~4:00 PM EDT
- [x] Broaden `cjxlz` input beyond raw PNM/PAM by adding native-build PNG decode in the C CLI only, keeping all codestream logic in Zig, reusing the decoded pixel buffer for both main-image and grayscale `--extra` sidecar paths, and keeping Windows compile-only coverage green by making that PNG reader an explicit build option that the Windows smoke disables; proved by new `cjxlz` PNG roundtrip and PNG-`--extra` smokes, with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.070847245s` vs upstream `0.077014838625s`, `large_multigroup_rgb` `1.081014385375s` vs `1.1747901250000001s`, narrow encode `0.009358666875000001s`) — 2026-04-01 ~5:35 PM EDT
- [x] Broaden the public color-profile surface just enough to dogfood non-default transfer functions through the real CLI: export `JxlDecoderGetColorAsEncodedProfile`, emit `JXL_DEC_COLOR_ENCODING` once parsed metadata is available, thread `--linear-srgb` through `cjxlz` so it chooses `JxlColorEncodingSetToLinearSRGB` instead of the hardcoded sRGB default, and prove both the direct C API and CLI paths with external smokes that inspect the decoded structured profile; the same slice also fixes a real Darwin packaging defect by repacking the flake-built static archives with Apple `libtool` so the external C smoke binaries keep linking cleanly — 2026-04-01 ~6:20 PM EDT
- [x] Broaden that same public color-profile dogfooding slice from transfer-function-only to the first non-default rendering intent: add `cjxlz --rendering-intent {perceptual,relative,saturation,absolute}`, thread it into the staged `JxlColorEncoding` before encode, and prove it with a CLI smoke that inspects the decoded structured profile through `JxlDecoderGetColorAsEncodedProfile` — 2026-04-01 ~6:35 PM EDT
- [ ] Broaden the encode-side public API/CLI beyond the current one-shot uint8 gray/RGB/alpha + staged-sidecar slice: richer metadata/frame options, more extra-channel types, and richer input/container formats beyond raw P5/P6/P7 plus PNG
- [x] Broaden the public metadata/frame surface after color-encoding dogfooding by taking the smallest honest animation slice: allow `have_animation` plus `AnimationHeader` through metadata writing, add a narrow `JxlFrameHeader` / `JxlEncoderSetFrameHeader` timing path to the public encoder, thread that through the pure Zig one-shot encoder and `cjxlz`, and prove it with focused Zig tests plus external C/CLI smokes for single-frame animated codestream metadata and timing — 2026-04-02 ~11:40 AM EDT
- [x] Broaden animation from the current single-frame metadata/timing slice into real multi-frame JXL animation by adding a native frame-byte-span helper, multi-frame codestream writing in Zig, a narrow animated packed-frame encoder core, and public `JxlEncoder` queue/`JxlEncoderCloseFrames` support; the first public slice intentionally supports same-geometry uint8 gray/RGB with optional interleaved alpha, but still rejects staged sidecar extras in multi-frame mode so the next step can focus cleanly on GIF demux/disposal and later wider per-frame extra support — 2026-04-02 ~2:35 PM EDT
- [x] Layer GIF-to-JXL animation conversion on top of the new multi-frame core in the C CLI, preserving loop count, frame timing, transparency, and disposal semantics without moving file I/O out of C; the current slice keeps the demux/coalescing and GIF semantics in `cjxlz.c`, feeds only repeated main-image frames through the existing public `JxlEncoder` FFI, adds a tiny codestream inspector smoke for `traffic_light.gif`, and keeps Windows compile-only coverage honest by putting GIF input behind `-Dgif_input` just like PNG — 2026-04-02 ~4:55 PM EDT
- [x] Broaden the public decoder surface after GIF-to-JXL lands by adding multi-frame iteration/events so animated codestreams produced by `cjxlz` can be inspected and round-tripped end to end from the C API too: the decoder now walks one encoded frame at a time, emits repeated `JXL_DEC_FRAME` / `JXL_DEC_FULL_IMAGE`, exposes `JxlDecoderGetFrameHeader` plus `JxlDecoderGetFrameName`, and proves the path with both a Zig regression and a new external C smoke that inspects `traffic_light.gif` after `cjxlz` converts it to animated JXL — 2026-04-02 ~6:05 PM EDT
- [x] Add the first narrow `animated JXL -> GIF` path in `djxlz` and then widen the public multi-frame alpha surface enough that animation no longer requires interleaved alpha: `djxlz` now emits still or animated GIF through the public decoder FFI using coalesced displayed frames, preserved loop count, preserved delays, and a deterministic per-frame RGB332 palette with binary transparency, while the public multi-frame `JxlEncoder` queue now accepts staged alpha planes (including `dim_shift = 1`) in addition to interleaved alpha; kept with targeted GIF smoke coverage, new Zig regressions for multi-frame staged alpha, full `./test` green, and accepted `./bm` numbers (`full_corpus` `0.069604166625s` vs upstream `0.07386381275000001s`, `large_multigroup_rgb` `1.06348048425s` vs `1.15471491675s`, narrow encode `0.00908240625s`) — 2026-04-14 ~10:20 AM EDT
- [x] Broaden the public multi-frame encoder queue beyond alpha-only animation by carrying staged sidecar extras through the same packed-frame animation core: `SimplePackedU8AnimationFrame` now carries per-frame extra planes, the animation validator now requires matching extra-plane metadata across frames, `finalizeSimpleEncode` reuses `prepareQueuedPackedInput` for all queued animation frames, and Zig regressions now prove both full-size `selection_mask` and subsampled `depth:1` channels survive two-frame animation codestreams alongside the older staged-alpha cases; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.06886178650000001s` vs upstream `0.07423447925s`, `large_multigroup_rgb` `1.05852086475s` vs `1.1333278385s`, narrow encode `0.009081411125000001s`) — 2026-04-14 ~10:40 AM EDT
- [x] Broaden the public animated decoder surface beyond repeated frame events by adding the first real control APIs: `JxlDecoderRewind` now resets parsed-frame iteration state while preserving subscribed events, `JxlDecoderSkipFrames` can drop upcoming displayed frames before `JXL_DEC_FRAME`, and `JxlDecoderSkipCurrentFrame` can advance away from the currently parsed frame after its header is visible; proved with focused Zig regressions plus a new external C smoke that converts a generated GIF through `cjxlz`, exercises both skip styles, and confirms the surviving frame durations are `100 300 100` on both the skip and rewind paths; kept with full `./test` green and accepted `./bm` numbers (`full_corpus` `0.069909463375s` vs upstream `0.075250031125s`, `large_multigroup_rgb` `1.067387562625s` vs `1.149778494625s`, narrow encode `0.0090798855s`) — 2026-04-14 ~12:10 PM EDT
- [x] Fix the Actions regression in the new GIF animation smokes by removing their dependency on the untracked local `testdata/` tree: add a checked-in `tests/cli/make_traffic_light_gif.c` fixture generator, have both GIF-based CLI smokes build that tiny helper into `$TMPDIR`, and keep the full `./test` suite green so CI sees the same animated input locally and remotely — 2026-04-02 ~6:35 PM EDT
- [x] Broaden animated decoder dogfooding beyond frame-header control checks by asserting real image-output semantics too: add an external C smoke that converts the generated traffic-light GIF through `cjxlz`, hashes actual decoded RGBA frame buffers, and proves that `JxlDecoderRewind` + `JxlDecoderSkipCurrentFrame` produce the same surviving image sequence as `JxlDecoderSkipFrames(1)`; fixing that smoke exposed and repaired a real public-decoder bug where `JxlDecoderRewind` kept a stale caller-owned output-buffer pointer alive and skipped `JXL_DEC_NEED_IMAGE_OUT_BUFFER` on replay — 2026-04-14 ~1:15 PM EDT
- [x] Broaden the public structured color-profile path beyond the old sRGB/linear-only adapter: `toInternalColorEncoding` now accepts standard RGB primaries (`srgb`, `p3`, `bt2100`) plus standard non-gamma transfer functions (`709`, `linear`, `srgb`, `pq`, `dci`, `hlg`), `cjxlz` now dogfoods them through `--primaries` and `--transfer-function`, and new external C/CLI smokes prove a `P3 + HLG` codestream survives through `JxlDecoderGetColorAsEncodedProfile` while the older linear-sRGB/rendering-intent smokes continue to pass — 2026-04-14 ~3:35 PM EDT
- [x] Broaden the same public structured-color path one step further by admitting non-default white points (`d65`, `e`, `dci`) through both the public `JxlEncoder` adapter and `cjxlz --white-point`, and prove it with new external C/CLI `P3 + DCI` smokes while updating the existing structured-profile probe output to include decoded white point explicitly — 2026-04-14 ~5:10 PM EDT
- [x] Broaden the same public structured-color path again by admitting explicit gamma transfer through both the public `JxlEncoder` adapter and `cjxlz --gamma`, prove it with direct C/CLI smokes, and lock down the CLI error contract so `--transfer-function gamma` is rejected unless a numeric `--gamma` value in `(0, 1]` is supplied — 2026-04-14 ~5:35 PM EDT
- [x] Broaden the public metadata/frame surface by carrying preview metadata through the existing simple encoder path: add `writePreviewHeader`, permit `have_preview + preview_size` in `writeImageMetadata`, thread preview width/height through the pure Zig simple-image structs, public `JxlEncoder` validation, and `cjxlz --preview-size`, then prove it with a Zig metadata roundtrip plus direct C/CLI basic-info smokes — 2026-04-14 ~6:10 PM EDT
- [x] Broaden the same structured-color path from enum-only white points to the first custom chromaticity surface: the pure Zig color writer now serializes custom CIExy white points, the public `JxlEncoder` adapter now accepts `JXL_WHITE_POINT_CUSTOM` plus `white_point_xy`, the decoder-side profile export repopulates those custom coordinates, and `cjxlz --white-point-xy X,Y` dogfoods the full path; proved with a focused Zig roundtrip plus direct C/CLI smokes — 2026-04-14 ~7:00 PM EDT
- [x] Broaden the same structured-color path again from custom white point to custom RGB primaries: the pure Zig color writer now serializes custom red/green/blue CIExy triplets, the public `JxlEncoder` adapter now accepts `JXL_PRIMARIES_CUSTOM` plus `primaries_{red,green,blue}_xy`, the decoder-side profile export already mirrors those coordinates back out, and `cjxlz --primaries-xy Rx,Ry,Gx,Gy,Bx,By` now dogfoods the full path; proved with focused Zig roundtrips plus direct C/CLI smokes — 2026-04-14 ~7:20 PM EDT
- [x] Broaden the next smallest spec-facing gap after custom structured chromaticities with the first real container slice: add a pure Zig BMFF wrapper/unwrapper for `signature + ftyp + jxlc`, allow `have_container = 1` through the narrow public `JxlEncoder` path, teach the public decoder to unwrap that minimal container and report `basic_info.have_container = 1`, and dogfood it from `cjxlz --container`; proved with a Zig container-module roundtrip plus direct C/CLI container smokes — 2026-04-14 ~8:00 PM EDT
- [x] Broaden the next container/profile gap after the first `jxlc` shell by teaching the pure Zig BMFF helper and public decoder path to reassemble sequential `jxlp` codestream fragments, including the high-bit last-fragment marker and interleaved non-codestream boxes; proved with a focused Zig container regression plus a direct external C smoke that builds a split `jxlp` container in memory and decodes it through the public API — 2026-04-15 ~11:05 AM EDT
- [x] Broaden the next profile/container gap again from `jxlc + jxlp` support toward richer BMFF box handling by adding the first staged metadata-box encode surface: public `JxlEncoderUseBoxes`, `JxlEncoderAddBox`, and `JxlEncoderCloseBoxes` now accept uncompressed non-reserved BMFF boxes, force container output when boxes are present, and place those boxes ahead of the codestream; proved with a direct external C smoke that injects an `xml ` box and a Zig guard test that `ProcessOutput` rejects open box streams — 2026-04-15 ~11:45 AM EDT
- [x] Broaden the next container/profile gap from staged uncompressed metadata boxes through CLI/public dogfooding: `cjxlz --xmp PATH` now stages an `xml ` BMFF box through the public encoder surface and produces container output automatically when boxes are present; proved with a direct CLI smoke that scans the encoded bytes for both the `xml ` box type and the literal XMP payload — 2026-04-15 ~3:10 PM EDT
- [x] Broaden the same metadata-box CLI surface from one hard-coded XMP payload to repeated generic uncompressed boxes: `cjxlz --box TYPE PATH` now stages arbitrary 4-byte BMFF box types alongside `--xmp`, reuses the same public `JxlEncoderAddBox` path, and proves multiple metadata boxes survive in one container via a direct CLI smoke that scans for both `xml ` and `Exif` payloads — 2026-04-15 ~4:05 PM EDT
- [x] Broaden the same metadata-box path onto the public decoder side with the first BMFF metadata extraction subset: container unwrap now preserves already-owned non-codestream boxes, `JxlDecoderProcessInput` emits `JXL_DEC_BOX` / `JXL_DEC_BOX_COMPLETE` for those metadata boxes, and the first `JxlDecoder{Set,Release}BoxBuffer`, `JxlDecoderGetBoxType`, `JxlDecoderGetBoxSize{Raw,Contents}`, and `JxlDecoderSetDecompressBoxes` surface now exists for the uncompressed path; proved with a direct external C smoke that round-trips `xml ` + `Exif` through the public encoder and then extracts both payloads through the public decoder — 2026-04-15 ~4:45 PM EDT
- [x] Broaden the same decoder-side metadata-box subset to real `brob` handling: `JxlDecoderSetDecompressBoxes(JXL_TRUE)` now transparently Brotli-decompresses `brob` payloads, `JxlDecoderGetBoxType(..., JXL_TRUE)` reports the underlying box type even in raw mode, and the box-buffer path now emits decompressed contents only when requested; proved with a self-contained external C smoke that synthesizes a `brob`-wrapped `xml ` box around a real `cjxlz` codestream and checks both raw and decompressed decoder behavior — 2026-04-15 ~5:20 PM EDT
- [x] Broaden the staged metadata-box encoder surface from uncompressed-only to real compressed metadata boxes: `JxlEncoderAddBox(..., compress_box = JXL_TRUE)` now emits a `brob` box whose contents are `underlying_type + Brotli(payload)`, and the resulting container round-trips through the new decoder-side decompression path; proved with a direct external C smoke that encodes a Brotli-compressed XMP box, checks the raw `brob` layout in the output bytes, and then decodes it back through `JxlDecoderSetDecompressBoxes(JXL_TRUE)` — 2026-04-15 ~5:30 PM EDT
- [x] Broaden the same BMFF parser from 32-bit box sizes only to the first 64-bit extended-size path: `container.extractCodestreamAndBoxes(...)` now accepts `size == 1` headers, computes payload offsets/sizes from the 64-bit large-size field, and the packaged `djxlz` now decodes the checked-in `testdata/jxl/boxes/square-extended-size-container.jxl` fixture successfully instead of rejecting it as unsupported — 2026-04-15 ~6:25 PM EDT
- [x] Broaden BMFF regression coverage from self-generated containers to checked-in upstream reference fixtures: the public decoder CLI/C-API smoke surface now exercises `testdata/jxl/jpeg_reconstruction/1x1_exif_xmp.jxl` directly and asserts that real `Exif` + `xml ` metadata boxes are observable through `JXL_DEC_BOX` / `JXL_DEC_BOX_COMPLETE`, so the metadata-box subset is no longer only validated against our own synthetic encodes — 2026-04-15 ~6:40 PM EDT
- [x] Broaden the next container/profile gap from the current metadata-box subset to the next honest decoder-side BMFF parity slice: preserve the public box stream in original order, including `JXL `, `ftyp`, and codestream boxes, instead of metadata-only sidecars; proved with a tightened pure-Zig container regression plus the affected public C `brob` / metadata / container smokes — 2026-04-30 ~estimated EDT
- [x] Broaden the next profile gap from “structured-only decoder export” to the first real ICC surface: add a deterministic built-in decoder-side sRGB ICC export for default structured RGB sRGB, expose it through `JxlDecoderGetICCProfileSize` and `JxlDecoderGetColorAsICCProfile`, and prove it with new helper unit tests plus a direct public C smoke — 2026-04-30 ~estimated EDT
- [x] Encoder perf follow-up option 1: extend `bench_weighted_predict.zig` with explicit `generic_null_props` vs `no_props` modes, add parity + stable-checksum coverage for the encoder-side `predictNoProps` path, and benchmark the two callsites; the longer `600x300 repeat=256` run came out essentially at parity, so the real win here is cleaner measurement rather than a kept speedup — 2026-03-07 ~12:45 PM EST
- [x] Encoder perf follow-up option 2: add `instrumented|minimal` bookkeeping modes to `bench_modular_encode_prep.zig`, keep the fully checked path for regression tests, log both scenarios in `./bm`, and keep it because the new `modular_encode_prep_minimal` scenario measured about `1.20x` faster than the instrumented path on `1024x768x3 repeat=24` while preserving identical sample and bit-count totals — 2026-03-07 ~1:30 PM EST
- [ ] Encoder perf follow-up option 3: start the first real modular writer slice and shift future optimization work from the synthetic scaffold to true bitstream-writing hot paths

## Phase 7: Extras
- [ ] JPEG recompression (jpegli)
- [ ] jxltranz transcoder
- [ ] Butteraugli / SSIMULACRA metrics
