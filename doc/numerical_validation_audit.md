# Numerical decisions in strict validation

Source audit on September 8, 2026, starting from `6d64d6f7`. This is a targeted
decision-path audit, not a completed review of every decoder rejection site.
[INTENT.md](../INTENT.md) records Peter's validation-first, full-spec objective.

## Observed paths

| Path | Source observation | Consequence |
| --- | --- | --- |
| Public validation | `JxlValidate` calls `decodeCurrentFrame`, without requesting the output-buffer writer | Final output-packing equality is not itself a validation decision |
| Session decoding | `Session.decode` sets `force_render = true`; `finish` stores DC/reference layers and may convert and blend samples | Rendering cannot simply be disabled without checking later-frame dependencies |
| Structured RGB metadata | `ColorEncoding.readFromBitStream` calls `color_matrix.validateRgb`; matrix inversion, adaptation and ICC range checks use native floats | Numerical calculations can lead to `InvalidColorEncoding`, hence a corrupt verdict; threshold controls deserve priority |
| Quantization matrices | `decodeDC` compares a scaled F16 against a decimal threshold represented in integer arithmetic; weight checks use exponent fences | These are numerical acceptance decisions, distinct from display tolerance |
| Sample conversion | `loadFloat16Fixed`/`loadFloat32Fixed` reject nonfinite encodings; floating-sample paths also preserve special-value bit patterns | A rejection must be justified for the field and path; nonfinite image samples cannot all be presumed corrupt |
| References and patches | Reference slots, dimensions, bounds, blending indices and ANS completion are checked separately from sample arithmetic | Preserve these exact checks; sample precision cannot replace them |
| Error mapping | `GenericError` remains indeterminate, while typed container/color/JPEG errors map to corrupt | A decoder's nonzero exit alone does not establish a classified corruption finding |

Primary source paths are `src/capi_root.zig`,
`src/lib/codec/{decode_session,color_encoding,color_matrix,dec_frame,float_reference,patches}.zig`,
and `src/lib/base/float.zig`.

## Numerical follow-ups

Do not add a general per-sample error-bound field. First identify a decision
whose ambiguity requires one. Prefer exact integer comparisons for encoded
fields, or a proved static bound with wider intermediate arithmetic. Preserve
an indeterminate result when implementation precision cannot justify a verdict.

The current weight fences deliberately differ from upstream. The native tests
explicitly require exponent-based limits; upstream `lib/jxl/quant_weights.cc`
uses `1e-8f` and `1.0f / 1e-8f`, with signed or magnitude comparisons depending
on the field. This audit establishes a difference, not permission to change
either acceptance boundary. Verify the format requirement before revising it.

Structured RGB validation shares numerical helpers with output conversion.
Review determinant and ICC representability boundaries with independently
derived valid/invalid metadata before replacing the arithmetic. The existing
invalid-primary fixtures prove selected cases, not every boundary.

The pending floating-reference one-ULP failure is retained. Determine whether
the change reaches a validation branch or only alters samples, and check
multi-frame propagation before proposing a tolerance. No tolerance was widened
during this audit.

## Measurement limits

The existing labeled and mutation runners execute `djxlz`, not `JxlValidate`.
Both collapse all nonzero process exits into rejection. Their printed counts
cannot distinguish corrupt, unsupported, allocation failure or a crashed tool.
Replace that ambiguity before reporting them as strict-validation detection
rates. Preserve raw process outcomes on both implementations.

The existing mutation suite declares 15 bases and 270 mutants. Its sniper set
flips bit zero at five predetermined percentage offsets per file: 75 bit flips,
not an exhaustive sweep of all bits. Its shape smoke checks labels/counts but
does not yet verify changed bytes. Those are source observations, not a new
measured detection score.

Reference rejection is an investigation signal; reference acceptance is also
compatible with a missed format violation. Keep separately established invalid
controls and known-valid controls. A stricter native rejection needs a specific
reason, while unexplained disagreements remain visible for investigation.

The labeled-good classifier now reports reference disagreement even when the
native decoder accepts. Its control set covers both labels and all four paired
binary outcomes. The new case failed before the fix. The focused corpus rerun
accepted all eight labeled-good inputs and rejected four of five labeled
mutations; the fifth was accepted by both decoders. These are decoder outcomes,
not proof that the fifth mutation is valid or a strict-API detection percentage.

## First diagnostic repair

Required-zero byte-alignment padding already caused decoder rejection, but its
`GenericError` became an indeterminate public verdict. A persistent public test
witnessed that result before the repair. `NonzeroPadding` now maps to
`CORRUPT / NONZERO_PADDING`, exposed as `nonzero_padding` by the CLI. Other
generic errors remain unclassified; this change does not relabel them.

The bit-reader control exhausts 256 byte values at all seven partial-byte
boundaries (1,792 combinations). A native 1x1 grayscale stream supplies an
accepted base and three separate single-bit metadata-padding mutations through
the Zig API, C API and CLI controls. Upstream's corresponding check is
`BitReader::JumpToByteBoundary` in `lib/jxl/dec_bit_reader.h`; it explicitly
requires zero padding. This is a scoped improvement in diagnostic precision,
not a new claim about arbitrary bit-flip detection. The public offset remains
approximate where the caller cannot locate the exact rejected byte.

An independent pinned upstream decoder probe accepted the same 31-byte base and
rejected each of its three metadata-padding flips (byte 8, bits 5 through 7).
The first full unit run exposed a test helper that recognized only GenericError
as malformed JPEG reconstruction metadata. The helper now recognizes the typed
error as rejection and propagates other errors. Its exhaustive mutation and
truncation control passes with all existing oracle expectations unchanged.

The corrected canonical `./test` and `./build` both exited zero on September 8,
2026 at 17:39 EDT. This includes the full unit suite, all 106 CLI suites, and
Windows cross-compilation. The original failed run is retained separately from
the final logs at `/tmp/libjxlz-validation-padding-final-{test,build}-20260908.log`.
