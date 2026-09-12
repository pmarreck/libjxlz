# Seeded corruption-probe pilot, September 11, 2026

The sibling tool can measure strict validator outcomes without integrating an
in-process probe. This pilot contains 256 sampled mutations across two fixtures;
it does not establish full JPEG XL specification coverage or a universal
bit-flip detection probability.

## Results

Each mode has 32 trials on each fixture. Replays are verification of the same
cases and are not additional samples.

| Mutation mode | Trials | CORRUPT | VALID | INDETERMINATE |
| --- | ---: | ---: | ---: | ---: |
| Single-bit sniper | 64 | 11 | 24 | 29 |
| Byte complement bolter | 64 | 24 | 6 | 34 |
| Eight-byte shotgun | 64 | 13 | 13 | 38 |
| Truncation | 64 | 64 | 0 | 0 |
| Total | 256 | 112 | 43 | 101 |

All 101 indeterminate findings were `unclassified_decoder_error`. No sampled
mutation produced an unsupported verdict, resource failure, crash, timeout or
operational error. Both pristine fixtures passed baseline validation and the
final two-file specificity check. Accepted mutations may be valid streams;
their acceptance alone does not demonstrate a validator defect.

The 4x4 fixture produced 60 corrupt, 39 valid and 29 indeterminate outcomes.
The multi-section fixture produced 52 corrupt, 4 valid and 72 indeterminate
outcomes. The tool reports both runs as COMPLETE WITH EXCEPTIONS because the
adapter maps indeterminate results to warnings. Its rejection-rate denominator
excludes warnings; use the counts above when discussing all attempted mutations.

## Verdict adapter and controls

`jxlz validate` exits 1 for both corruption and indeterminate results. Direct
exit-code scoring would count all 101 indeterminate cases as rejection.
The pilot adapter parses the seven-field strict output using the existing
`tests/lib/strict_mutation_matrix.bash` parser and classifier, then maps:

- VALID to exit 0, accepted;
- CORRUPT to exit 1, rejected;
- indeterminate, unsupported and resource failures to exit 2, warning;
- malformed output, contradictory statuses and abnormal child exits to exit 3,
  operational error.

Raw native status, findings and classification are retained in event stderr
and per-invocation logs. Probe deadlines remain timeouts. Ten adapter controls
first witnessed eight failures with direct exit forwarding, then passed with
the strict mapping. They cover both valid/corrupt controls, the inconclusive
classes, malformed output, unexpected stderr and abnormal child exit.

## Reproduction and provenance

Settings: seed `0x20260911`, 32 rounds per mode, eight-byte shotgun window,
two-second validator deadline, safe restoration enabled. The first run used two
workers; the final pinned replay used one. Mutation parameters, outcomes and
raw findings matched for all 256 trials. The tool's paired history comparison
also passed. Source SHA-256 hashes were unchanged after all runs.

Validator code is the tested `c37b27ea4a5930d435e5694367d472c08f5b0c58` slice,
using `/nix/store/lxf82g7114sm6si0ryvwmsv1yla759h5-libjxlz-0.1.0/bin/jxlz`.
The artifact was built before that commit's documentation checkpoint; its
binary hash is recorded in the evidence directory.

The first probe executable was
`/nix/store/swm4n6c5vns8hgmrkks6hdjlkacmqb77-corruption-probe-0.1.0/bin/corruption-probe`.
The sibling checkout changed during evaluation. The final replay therefore used
an isolated archive of commit `591e8d1f836997ec235d5b055e6cfd48dc48e95e`, with
the installed tool's pinned LuaJIT environment and random module. Its newer
exit-map option cannot distinguish two native verdicts sharing exit 1, so the
strict adapter remains necessary.

| Fixture | Bytes | SHA-256 |
| --- | ---: | --- |
| `src/lib/testdata/lossless_4x4.jxl` | 83 | `9a99bc9265cb56767ba9075742570043e3625063e6b6672a9aa6f23943846cb7` |
| `src/lib/testdata/lossless_600x10_multisection.jxl` | 90 | `fd9245253ffafac510961f52569abf012f9f26ae562f5b1c2dccb0886951f32e` |

Evidence directory: `/tmp/libjxlz-corruption-probe-20260911.bW1SZL`.
It contains the adapter, failing/passing controls, immutable probe snapshot,
JSON/Markdown reports, NDJSON events, histories, paired comparisons and hashes.
Final reports are under `pinned-lossless_4x4/` and
`pinned-lossless_600x10_multisection/`.

## Excluded fixture and next work

The 81-byte `splines.jxl` fixture timed out during pristine baseline validation
at two seconds and again in a separate 15-second native check. No spline
mutation score was generated. The initial three-file specificity checks each
recorded that timeout; the final specificity corpus contains the two accepted
fixtures only. This exclusion is a validation-cost follow-up, not evidence of
corruption or a false rejection.

Next: keep the existing typed-verdict distinction, investigate the spline
baseline cost, and use paired runs after the queued nested-LZ77 and MA-range
repairs. Broader independent valid fixtures and constraint-specific invalid
controls are required before making broader coverage claims.
