# JPEG XL validation coverage ledger

Started September 9, 2026 from `7b12d9a4`. This is an initial inventory and a
constraint ledger, not a completed specification audit or a coverage percentage.
`PLAN.md` orders the work. `INTENT.md` defines the validation objective.

An implemented decoder path does not establish that every constraint on that
path is checked. Each completed requirement needs a normative source, an
implementation location, valid and invalid controls, and a public verdict.
Reference behavior is evidence to investigate; permissive reference acceptance
cannot override a demonstrated format violation. Exact clause references below
remain pending until checked against the applicable standard text.

## Format families

| Family | Implementation and existing controls | Remaining validation work |
| --- | --- | --- |
| Raw codestream and container | `container.zig`, public strict C/CLI controls; signature, extended sizes, ordering, fragmented streams and final-frame completion have landed | Clause inventory, remaining box/extension semantics, cross-box combinations and exact finding locations |
| Image and frame metadata | `image_metadata.zig`, `frame_header.zig`, `field_coders.zig`; preview, orientation and extra-channel paths exist | Enumerate field ranges, conditional fields, reserved/extension behavior and interactions; classify generic failures |
| Section tables and entropy | `toc.zig`, `dec_ans.zig`, `huffman.zig`; ANS/prefix and permutation controls exist | Complete consumption, overread/final-state and malformed-table constraints; preserve allocation failures |
| Modular coding | `modular/dec_ma.zig`, `encoding.zig`, `transform.zig`; predictors, RCT, palette and squeeze exist | MA property ranges, resource errors, transform invariants and independent malformed-stream controls |
| VarDCT | `dec_frame.zig`, `vardct_frame.zig`, coefficient/transform fixtures; all 27 strategies have implementation controls | Quantization boundary justification, malformed groups/orders, dependency combinations and typed findings |
| References and reconstruction stages | `decode_session.zig`, `frame_render.zig`, patches, noise, splines and floating-reference controls | Cross-feature constraints and numerical effects on later frames; contextual alpha-normalization regression in pending spot-color work |
| Color and ICC | `color_encoding.zig`, `color_matrix.zig`, `icc_codec.zig`, profile controls | Numerical validity boundaries and profile/metadata consistency; separate output-profile generation from input validation requirements |
| JPEG reconstruction | `jpeg_reconstruction.zig`, `jpeg_payloads.zig`, coefficients/writer/public controls | Clause and combination inventory beyond current fixtures; preserve exact reconstruction requirements |
| Public validation contract | `JxlValidate`, typed findings and resource options | Explicit achieved depth/limitations, allocator accounting, exact offsets and complete invariant classification |

These rows identify areas to audit. None is a declaration of full coverage.
Older unchecked feature bullets in `COVERAGE_GAMEPLAN.md` are historical and
must be reconciled against the implementation and recent `PLAN.md` checkpoints.

## Initial constraint records

| ID | Constraint or operational contract | Evidence and controls | Status |
| --- | --- | --- | --- |
| BIT-PADDING | Required-zero byte-alignment padding must contain zero bits | `base/bit_reader.zig`; upstream `dec_bit_reader.h`; 1,792 byte/boundary cases and three independent bit flips through Zig/C/CLI | Typed `NONZERO_PADDING` shipped in `7b12d9a4`; clause reference pending |
| MA-HEIGHT | Tree height is checked against the existing 2,048 limit | `modular/dec_ma.zig`; upstream `modular/encoding/dec_ma.cc`; controls immediately below, at and above the limit | Existing bound retained; normative clause review pending |
| MA-HEIGHT-RESOURCE | Allocation failure must not bypass a required validation check | Injected failing allocator on normal and over-height trees; single-leaf tree-decoder allocation sweep | Witnessed success on allocation failure; caller-allocator/OutOfMemory repair passed focused controls and full tests/build on September 9 |
| MA-SPLIT-RANGE | Investigate whether each split must leave possible values on both branches under ancestor constraints | Upstream propagates per-property ranges; native validator currently does not | Missing native check identified; specification justification and failing controls pending |
| NUM-COLOR | Structured RGB metadata rejection must follow justified numeric boundaries | `color_matrix.validateRgb`; existing selected invalid-primary controls | Boundary audit pending; see `numerical_validation_audit.md` |
| NUM-QUANT | Quantization rejection thresholds must follow format requirements | Native exponent fences differ from upstream decimal thresholds | Difference established; specification decision pending |

## Measurement and acceptance

The strict mutation matrix calls the shipped `jxlz validate` adapter to
`JxlValidate`, preserves raw oracle and validator process statuses, and records
per-case findings. Its corpus has 15 clean bases and 270 mutations. The gate
requires clean bases to validate, rejects operational/resource failures as test
failures, and records indeterminate mutations without counting them as detected
corruption. A per-case baseline makes verdict changes reviewable. Signature
mutations have a separate required-corruption check.

The initial measurement against the `7b12d9a4` package accepted all 15 bases.
For 270 mutants it recorded 38 corrupt, 226 indeterminate, 6 accepted, and zero
unsupported, resource or operational outcomes. These are strict API results,
not a claim that all 270 mutations are invalid. The detailed baseline is
`tests/corpus/strict_mutation_verdicts.tsv`.

Reference exit 1 is recorded as reference rejection, not proof of corruption.
Accepted mutations can be other valid streams. Independent byte-level checks
verify each declared shape before scoring it. Adversarial controls include
unchanged bytes, wrong offsets, multi-bit sniper changes, wrong truncation
lengths, wrong fill and modifications outside the declared region. The finite corpus
does not establish a universal bit-flip detection probability.

The official conformance corpus is not yet integrated as a scored native gate.
Use its independently supplied valid streams and declared output requirements,
then add constraint-specific malformed controls. Passing decoder conformance
alone would not prove complete corruption detection.

An exploratory acceptance probe used [libjxl/conformance](https://github.com/libjxl/conformance/tree/b1d0f990b03e57bf6d137c365cd5dc8b470b9191)
at that pinned commit. Its two level lists contain 40 case names and 27 distinct
input hashes. All 27 distinct inputs returned VALID using the `7b12d9a4` package.
The first pass accepted 37 cases within 30 seconds; three timeouts represented
two distinct inputs, both accepted on separate retries with a 180-second limit.
The duplicate progressive case was not independently retried. This measures
input acceptance, not the corpus's rendering precision requirements.

The unpacked archive hash is
`sha256-tpKnt44FgZUqzvk5YcMBmVsDCdvlA6Cz+KNYMTVUacc=`. Preserve its LICENSE and
testcases/README.md permissions and image credits when integrating the gate.
Raw case statuses and retry evidence are documented in
`/tmp/libjxlz-official-acceptance-20260909.md`.
