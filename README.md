# libjxlz

[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/pmarreck/libjxlz/libjxlz_ci.yml?branch=main&label=GitHub%20Actions)](https://github.com/pmarreck/libjxlz/actions/workflows/libjxlz_ci.yml)
[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Flibjxlz)](https://garnix.io/repo/pmarreck/libjxlz)

<img src="doc/jxl.svg" width="100" align="right" alt="JXL logo">

`libjxlz` is a Zig rewrite of `libjxl`, aimed at becoming the fastest practical
JPEG XL encoder/decoder while preserving a `libjxl`-shaped C FFI and dogfooded C
CLI tooling.

It is a derived rewrite, not a clean-room implementation. Upstream lineage,
copyright split, and attribution notes are summarized in [`NOTICE`](NOTICE).

Current status is decoder-first:
- pure Zig lossless/modular decode core
- first `libjxl`-shaped decoder C API slice
- `djxlz`, a C CLI that talks only through that C API
- CI coverage for Linux `x86_64`/`aarch64`, macOS `aarch64`, and Windows
  `x86_64` cross-compilation
- checked-in public-API benchmark harness against upstream `libjxl`
- first encoder-side modular prepass benchmark/profiling scaffold

Recent optimization and documentation work in this repo was produced by Peter
Marreck with Codex (`gpt-5.4-xhigh`, per session attribution request).

## Current Wins

As of March 7, 2026, the checked-in public C API benchmark (`./bm`) shows a real
decode lead over upstream `libjxl` on this Apple Silicon development machine:

- full committed corpus: `73.1 ms` vs `77.7 ms` (`~1.06x` faster)
- large modular multigroup fixture: `1.085 s` vs `1.173 s` (`~1.08x` faster)

The benchmark harness is in
[`tests/benchmark/decode_public_api.c`](tests/benchmark/decode_public_api.c),
and the history log is in
[`tests/benchmark/public_api_decode_history.tsv`](tests/benchmark/public_api_decode_history.tsv).

The first encoder-side benchmark scaffold is in
[`bench_modular_encode_prep.zig`](bench_modular_encode_prep.zig), with history
logged in
[`tests/benchmark/modular_encode_prep_history.tsv`](tests/benchmark/modular_encode_prep_history.tsv).

An upstream-facing summary of the kept optimizations, including which ones are
portable back to C/C++ and where Zig helped or hurt, is in
[`doc/upstream_optimization_notes.md`](doc/upstream_optimization_notes.md).

## Current Capabilities

- Decodes committed lossless/modular JPEG XL fixtures end to end.
- Exposes a first decoder-focused `libjxl`-shaped C ABI including:
  `JxlSignatureCheck`, `JxlDecoderCreate`, `JxlDecoderReset`,
  `JxlDecoderDestroy`, `JxlDecoderSubscribeEvents`, `JxlDecoderSetInput`,
  `JxlDecoderReleaseInput`, `JxlDecoderCloseInput`, `JxlDecoderGetBasicInfo`,
  `JxlDecoderImageOutBufferSize`, `JxlDecoderSetImageOutBuffer`, and
  `JxlDecoderProcessInput`.
- Ships `djxlz`, a C CLI that uses only that public C API.
- Runs strict correctness and benchmark checks via `./test` and `./bm`.
- Exposes a first encoder profiling scaffold for modular predictor selection and
  residual tokenization, with `--print-profile` support for predictor-hit mixes.

## Current Limitations

- This is not yet a full drop-in replacement for upstream `libjxl`.
- Encoding is not implemented yet; there is no `cjxlz` yet.
- The decoder is currently single-threaded.
- `JxlDecoderSetParallelRunner` is present for API-shape compatibility, but it
  is currently a no-op in `src/capi_root.zig`.

## Threading

There is no real parallel decode path in `libjxlz` today.

Could there be? Yes. The obvious targets are:

- parallel group decode once global state is ready
- row/chunk parallel inverse transforms
- parallel output conversion / packing

The current code shape already makes this plausible because group decoding and
transform undo are mostly isolated phases. The main missing piece is a real
runner-backed execution model behind the existing C API surface.

## Build And Test

```bash
./build
./test
./bm
```

For a debug build:

```bash
./build --debug
```

To build the current C CLI explicitly:

```bash
nix develop -c zig build djxlz -Doptimize=ReleaseFast
```

## CLI Usage

Decode a JPEG XL file with the current dogfooding C CLI:

```bash
zig-out/bin/djxlz input.jxl output.ppm
```

`djxlz` currently focuses on decode, basic output formatting, and exercising the
public C FFI. It is not yet intended to mirror every upstream `djxl` feature.

## Additional Documentation

- [`doc/upstream_optimization_notes.md`](doc/upstream_optimization_notes.md)
- [`doc/benchmarking.md`](doc/benchmarking.md)
- [`doc/building_and_testing.md`](doc/building_and_testing.md)
- [`NOTICE`](NOTICE)
- [`CODE_MINIMAP.md`](CODE_MINIMAP.md)
- [`PLAN.md`](PLAN.md)

## License

This software is available under a 3-clause BSD license which can be found in
the [LICENSE](LICENSE) file, with an "Additional IP Rights Grant" as outlined in
the [PATENTS](PATENTS) file. The derivative-work attribution note for this fork
is in [NOTICE](NOTICE).
