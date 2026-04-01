# libjxlz

[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/pmarreck/libjxlz/libjxlz_ci.yml?branch=yolo&label=GitHub%20Actions)](https://github.com/pmarreck/libjxlz/actions/workflows/libjxlz_ci.yml)
[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Flibjxlz)](https://garnix.io/repo/pmarreck/libjxlz)

<img src="doc/jxl.svg" width="100" align="right" alt="JXL logo">

`libjxlz` is a Zig rewrite of `libjxl`, aimed at becoming the fastest practical
JPEG XL encoder/decoder while preserving a `libjxl`-shaped C FFI and dogfooded C
CLI tooling.

It is a derived rewrite, not a clean-room implementation. Upstream lineage,
copyright split, and attribution notes are summarized in [`NOTICE`](NOTICE).

Current status is lossless-modular first:
- pure Zig lossless/modular decode core
- first `libjxl`-shaped decoder C API slice
- `djxlz`, a C CLI that talks only through that C API
- first narrow `libjxl`-shaped encoder C API slice
- `cjxlz`, a C CLI that talks only through that C API
- CI coverage for Linux `x86_64`/`aarch64`, macOS `aarch64`, and Windows
  `x86_64` cross-compilation
- checked-in public-API benchmark harness against upstream `libjxl`
- checked-in narrow encode benchmark harness for the current lossless modular path

Recent optimization and documentation work in this repo was produced by Peter
Marreck with Codex (`gpt-5.4-xhigh`, per session attribution request).

## Current Wins

As of April 1, 2026, the checked-in public C API benchmark (`./bm`) shows a real
decode lead over upstream `libjxl` on this Apple Silicon development machine:

- full committed corpus: `70.8 ms` vs `77.0 ms` (`~1.09x` faster)
- large modular multigroup fixture: `1.081 s` vs `1.175 s` (`~1.09x` faster)

The benchmark harness is in
[`tests/benchmark/decode_public_api.c`](tests/benchmark/decode_public_api.c),
and the history log is in
[`tests/benchmark/public_api_decode_history.tsv`](tests/benchmark/public_api_decode_history.tsv).

The current narrow encode benchmark is in
[`bench_modular_encode_codestream.zig`](bench_modular_encode_codestream.zig),
with history logged in
[`tests/benchmark/modular_encode_codestream_history.tsv`](tests/benchmark/modular_encode_codestream_history.tsv).

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
- Exposes a narrow encoder-focused `libjxl`-shaped C ABI including:
  `JxlEncoderCreate`, `JxlEncoderReset`, `JxlEncoderDestroy`,
  `JxlEncoderFrameSettingsCreate`, `JxlEncoderSetBasicInfo`,
  `JxlEncoderSetColorEncoding`, `JxlEncoderAddImageFrame`,
  `JxlEncoderSetExtraChannelInfo`, `JxlEncoderSetExtraChannelName`,
  `JxlEncoderSetExtraChannelBuffer`, `JxlEncoderCloseInput`, and
  `JxlEncoderProcessOutput`.
- Ships `cjxlz`, a C CLI that uses only that public C API and currently accepts
  native-build PNG input plus raw `P5`/`P6`/`P7` PNM/PAM.
- Runs strict correctness and benchmark checks via `./test` and `./bm`.
- Encodes a real narrow lossless modular static-image path for grayscale/RGB,
  alpha, and selected extra-channel metadata/forms.

## Current Limitations

- This is not yet a full drop-in replacement for upstream `libjxl`.
- Encoding is still a narrow lossless modular subset, not full `cjxl` parity.
- There is no lossy/VarDCT encoder path yet.
- There is no JPEG recompression/transcode path yet.
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
nix develop -c zig build cjxlz -Doptimize=ReleaseFast
```

## CLI Usage

Decode a JPEG XL file with the current dogfooding C CLI:

```bash
zig-out/bin/djxlz input.jxl output.ppm
```

`djxlz` currently focuses on decode, basic output formatting, and exercising the
public C FFI. It is not yet intended to mirror every upstream `djxl` feature.

Encode a simple image with the current dogfooding C CLI:

```bash
zig-out/bin/cjxlz input.png output.jxl
```

`cjxlz` currently focuses on the narrow lossless modular public-API path. It
accepts native-build PNG input plus raw `P5`/`P6`/narrow `P7` PNM/PAM and is
not yet intended to mirror every upstream `cjxl` feature.

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
