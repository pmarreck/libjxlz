# Assorted-source corruption validation, September 12, 2026

Ten clean sources and 1,280 seeded mutations were replayed against the previous
package (`c37b27ea`) and the context-map/MA-tree and container-version changes.
All ten clean sources passed both packages. Nine INDETERMINATE results became
CORRUPT and one VALID became UNSUPPORTED; every other verdict stayed unchanged.
Three corruption-finding improvements were single-bit mutations.

| Mode (320 trials each) | CORRUPT before → after | VALID before → after | INDETERMINATE before → after | UNSUPPORTED before → after |
| --- | --- | --- | --- | --- |
| Single bit | 20 → 23 | 69 → 69 | 231 → 228 | 0 → 0 |
| Complement one byte | 25 → 29 | 40 → 39 | 255 → 251 | 0 → 1 |
| Replace eight bytes | 23 → 24 | 18 → 18 | 279 → 278 | 0 → 0 |
| Truncate | 319 → 320 | 0 → 0 | 1 → 0 | 0 → 0 |
| Total | 387 → 396 | 127 → 126 | 766 → 757 | 0 → 1 |

Neither run had crashes, timeouts, resource failures or operational failures.
These are sampled mutation outcomes, not a sensitivity
estimate over independently labeled corrupt data. Accepted mutations can be
valid alternate streams. The remaining 757 indeterminate cases all report
`unclassified_decoder_error`; none count as detected corruption. Passing ten
clean controls does not prove zero false positives across the format.

An independent djxl v0.12.0 replay of all 1,280 cases accepted 126 and rejected
1,154, with no exceptional process outcomes. It accepted every clean source.
All 396 native CORRUPT cases and all 757 INDETERMINATE cases were rejected by
djxl. One initially native VALID case disagreed: `oracle_gray16.jxl`, bolter
round 8, byte offset 25 complemented with XOR 255. This changes the container
`ftyp` version from 0 to 16,711,680. The final package reports UNSUPPORTED with
feature `container_box`; the codestream itself was unchanged. The
[upstream v0.12 version check](https://github.com/libjxl/libjxl/blob/v0.12.0/lib/jxl/decode.cc)
recognizes versions 0 and 1. Unknown versions do not justify a corruption claim.
All 126 final native VALID cases pass djxl.

The original September 11 two-source/256-case pilot was also replayed with its
original seed and timeout. Its totals improved from 112 to 119 CORRUPT and
101 to 94 INDETERMINATE, with 43 VALID unchanged. Every changed verdict was
INDETERMINATE → CORRUPT; mutation-description fields matched in both replays.

## Changes and controls

- Reject LZ77 in recursive context maps with at most two entries before further
  recursion. Depth-zero and depth-one encoded trees remain accepted; the
  independently checked depth-two counterexample now reports
  `invalid_context_map`.
- Check MA splits against ancestor bounds for the same property. A depth-first
  traversal restores bounds between siblings, with storage bounded by tree
  height and property count in addition to the existing height-check array.
  Contradictory branches report `invalid_ma_tree`. Encoded valid and invalid
  controls were independently checked with upstream DecodeTree. Signed limits,
  independent properties, siblings and allocation failures have controls.
- Give unused context-map cluster IDs a specific `invalid_context_map` finding.
  Reject missing simple-map entry bits as truncation before checking cluster IDs.
  A one-byte map requiring nine bits previously returned success.
- Stop claiming validity for unknown container versions. Unit and public tests
  first witnessed acceptance of versions above 1; they now require UNSUPPORTED
  and preserve valid whole-codestream controls at versions 0 and 1. Public tests
  also verify a following valid call clears the unsupported feature.

Focused tests witnessed the old acceptance or generic errors before the repairs;
all 30 focused controls then passed. Permanent CLI controls replay the native
4×4 mutation at byte 15, bit 5 and the grayscale mutation at byte 265, XOR 255.
Both fail against the old package and pass against the new one, with clean
controls accepted. The existing 15-base, 270-mutation gate is unchanged at
82 CORRUPT, 182 INDETERMINATE and 6 VALID.

The full unit run found one stale tree-size fixture that repeatedly split the
same property at zero. Giving each depth an independent property preserves its
2,047-node size and VarDCT budget assertion while making all ancestor paths
possible. Its focused rerun passed. Final full-suite and shipment results are
tracked with this change. Full `./test` passed all 112 CLI suites and Windows
cross-compilation on September 12 at 10:46 EDT; `./build` and the 40-case/27-input
conformance acceptance gate also passed. Log paths are recorded in PLAN.md.

The small-map restriction has supporting evidence in
[Sneyers et al., section 8.2.1](https://arxiv.org/html/2506.05987v1#S8.SS2.SSS1).
MA range validation follows the explicit upstream `ValidateTree` constraint.
Exact normative clause mapping remains open for both; upstream acceptance or
rejection alone is not a general invalidity oracle. No numeric tolerance or
floating-point computation was added to validation.

## Reproduction and provenance

Artifacts are in `/tmp/libjxlz-validation-20260912.5AznEW`: source inputs and
encoded bases, generator, pinned adapter, per-invocation native output, before,
initial after and final reports/events, and `final-transitions.json`. The event comparison excludes
only process observations and compares every mutation-description field. All
ten current source hashes match the before-run reports after generation replay.
The complete artifact directory was copied to
`/mnt/devcache/projects/libjxlz-0d943c99bed2/completed-20260912/libjxlz-validation-20260912.5AznEW`;
an independent recursive comparison found no differences.

Probe revision: `591e8d1f836997ec235d5b055e6cfd48dc48e95e`, retained in
`/tmp/libjxlz-corruption-probe-20260911.bW1SZL/probe-source-591e8d1`.
Both runs use seed `0x20260912`, 32 rounds per mode, eight-byte shotgun, five-second
timeout, two jobs and safe mode. The strict adapter maps only CORRUPT to probe
rejection; indeterminate outcomes remain warnings. Probe confidence intervals
exclude warnings and therefore must not be described as corruption sensitivity.

Before package: `/nix/store/lxf82g7114sm6si0ryvwmsv1yla759h5-libjxlz-0.1.0`.
Initial after package: `/nix/store/jysnzi38x53i88xii7r6vhkvxmdn4n79-libjxlz-0.1.0`.
Final measured package: `/nix/store/sgf37f49cmbkqmz1whvjiz7cy041fkrd-libjxlz-0.1.0`.

Three found sources come from libjxl/conformance revision
`b1d0f990b03e57bf6d137c365cd5dc8b470b9191`, the same corpus pinned by the acceptance
gate. Two are existing native test fixtures. Five fresh sources were encoded
with upstream cjxl v0.12.0, effort 3, and decoded successfully by upstream djxl
before probing:

- 32×24 RGB integer pattern, lossless and distance 1 VarDCT.
- 32×16 grayscale, 16-bit integer samples, lossless.
- 24×24 RGBA integer pattern with varying alpha, lossless.
- 300×260 RGB integer pattern crossing modular groups, lossless.

The retained generator writes PNM/PAM samples with integer Perl expressions;
there is no native-encoder dependency. A regeneration completed all five oracle
encodes/decodes, then stopped when recopying a read-only official fixture. The
hash comparison verified all ten bases remained identical to the measured
baseline; that copy failure was not a validation result.

| Source | Bytes | SHA-256 |
| --- | --- | --- |
| native_lossless_4x4.jxl | 83 | `9a99bc9265cb56767ba9075742570043e3625063e6b6672a9aa6f23943846cb7` |
| native_lossless_600x10_multisection.jxl | 90 | `fd9245253ffafac510961f52569abf012f9f26ae562f5b1c2dccb0886951f32e` |
| official_bench_oriented_brg.jxl | 184341 | `e223fed907c6238622b2b6ec1c80609050c9d2db4d759cf3ca6f0db304cbb82a` |
| official_delta_palette.jxl | 107899 | `00e24cc453cdf84897d62b0aafc7a9f7024205bbce1922e99d7ad0003759ae7c` |
| official_grayscale.jxl | 1069 | `78fbbba852e99946d187dcf0bcbd7fb0e7c22be2f0852523aaae6ed91e7e3c39` |
| oracle_alpha.jxl | 2478 | `46b6f616295a01b3355de126f75888f7a8d9e6ff4434825c39930b5d141f05d3` |
| oracle_gray16.jxl | 1141 | `c3d8410c030b1bfb0a9a1d365e061e19c6f29f9db2aacc8de72572b0a0ba1959` |
| oracle_multigroup.jxl | 252202 | `677d819c64e6b4d1b6c80c56ccd8ef95397ab84c5b126fb7df70fa9440e4e0e6` |
| oracle_rgb_lossless.jxl | 2425 | `b8d51f4f28bcf2c33fd87a3b9f4a2977b98bf3d110a07429702be134caed3cc6` |
| oracle_rgb_vardct.jxl | 1028 | `13aeeab8e147b98cf57aa619a4028aba54be104e641393ff36275475a90f5d1e` |
