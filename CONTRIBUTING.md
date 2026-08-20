# Contributing to libjxlz

libjxlz is a Zig reimplementation derived from upstream libjxl. Contributions
should keep the current bounded-parser, C-ABI, portability, and test contracts
intact.

## Security reports

Do not put suspected vulnerabilities in a public pull request. Follow
[SECURITY.md](SECURITY.md) and use GitHub private vulnerability reporting or
security@validate.pics.

## Ordinary changes

The public issue tracker is currently disabled. Open a focused draft pull
request against yolo, or coordinate with the maintainer before starting a large
or incompatible change.

Keep pull requests small enough to review. Explain the behavior being changed,
why it matters, and the evidence used to verify it.

## Tests and builds

Use test-driven development for behavioral changes:

1. Add a persistent test that fails for the missing or broken behavior.
2. Run it and record the red result.
3. Make the smallest implementation change that passes.
4. Run the focused control, then the complete gates.

The canonical commands are:

    ./test
    ./build

Use the repository's Nix development environment for direct Zig commands.
ReleaseSafe is the shipped default; ReleaseFast remains a required CI test
mode because parent projects may compile the module with their own optimize
setting.

Tests must be deterministic and isolated. Do not use sleeps as synchronization,
hide expected failures with shell errexit workarounds, weaken a corpus
denominator, or count a crash as a valid rejection.

## Code and API expectations

- Keep pure computation separate from filesystem, process, and terminal I/O.
- Preserve bounded reads and checked size arithmetic at public parser and C
  boundaries.
- Keep installed headers and exported archive symbols consistent.
- Preserve Linux x86_64/aarch64, macOS aarch64, and Windows x86_64/aarch64
  portability.
- Update PLAN.md and file-purpose annotations when behavior or file ownership
  changes.
- Do not include generated-agent attribution or co-author trailers in commits.

## Licensing and provenance

The project uses the BSD-3-Clause LICENSE and PATENTS grant. It is a derived
rewrite, not a clean-room implementation; NOTICE describes the upstream
lineage and copyright split.

By contributing, you agree that your contribution is provided under the
project's existing license and that you have the right to submit it. libjxlz
does not require Google's contributor license agreement.
