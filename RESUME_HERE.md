# Resume Here

## Current State
- Branch: `yolo`
- `HEAD`: `c222ecb0` `Make GIF animation smokes self-contained`
- Latest CI on `yolo`: green
	- Run `23923290170`
	- Commit `c222ecb08971efabe61aa4f48017983f8bf9acfc`
- Worktree at time of writing: only this handoff doc plus the small `PLAN.md` checkpoint correction are new local changes; the intentionally untracked local `testdata/` tree remains out of git.

## What Just Landed
1. `c7a5d40c` `Add animated decoder frame events`
- Public decoder now emits repeated `JXL_DEC_FRAME` and `JXL_DEC_FULL_IMAGE`.
- Added:
	- `JxlDecoderGetFrameHeader(...)`
	- `JxlDecoderGetFrameName(...)`
- Decoder C API now walks animated codestreams frame-by-frame instead of treating everything after metadata as one frame blob.
- New smoke:
	- `tests/cli/capi_decode_animation.c`
	- `tests/cli/capi_decode_animation.sh`

2. `c222ecb0` `Make GIF animation smokes self-contained`
- Fixed CI failure caused by the new GIF-based smokes depending on the intentionally untracked local `testdata/jxl/traffic_light.gif`.
- Added:
	- `tests/cli/make_traffic_light_gif.c`
- Both GIF smokes now generate their own deterministic animated GIF fixture into `$TMPDIR` before invoking `cjxlz`.

## Current Verified Behavior
### Decode
- Public C API decode remains modestly ahead of upstream on the checked harnesses.
- Animated codestreams can now be inspected frame-by-frame from C via:
	- `JXL_DEC_FRAME`
	- `JxlDecoderGetFrameHeader(...)`
	- `JxlDecoderGetFrameName(...)`

### Encode
- Narrow lossless modular encoder is real end-to-end for:
	- grayscale
	- RGB
	- alpha / extra-channel subsets
	- narrow multi-frame animation
- `cjxlz` can convert GIF animation to animated JXL through the public encoder FFI.

### Animation Dogfooding
- Forward path exists:
	- `GIF -> cjxlz -> animated JXL`
- Decoder metadata/frame iteration now exists:
	- `animated JXL -> public decoder events`
- Backward path does **not** exist yet:
	- `animated JXL -> GIF`

## Latest Accepted Benchmark Snapshot
From the latest accepted `./bm` run associated with the animated decoder slice:
- decode `full_corpus`:
	- `libjxlz=0.07221871375s`
	- `libjxl=0.077566901s`
	- `ref/our=1.074055x`
- decode `large_multigroup_rgb`:
	- `libjxlz=1.1068796977500002s`
	- `libjxl=1.1825407812500002s`
	- `ref/our=1.068355x`
- narrow encode harness:
	- `0.009690562500000001s`

## Immediate Next Target
Implement the first narrow `animated JXL -> GIF` path in `djxlz`.

This is the next logical step because:
1. We already have multi-frame JXL encode.
2. We already have GIF-to-JXL in `cjxlz`.
3. We now have decoder-side public frame iteration.
4. The missing piece for the first animation roundtrip story is decoder-driven GIF export.

## Recommended Narrow Slice
### Goal
Add `djxlz --output_format gif` for the coalesced displayed-frame path, with all file/container I/O in C and all codestream decode in the existing public C FFI.

### Keep It Narrow
First cut should support:
- animated or still JXL
- same canvas size for all emitted GIF frames
- loop count from `JxlBasicInfo.animation.num_loops`
- frame delay from `JxlFrameHeader.duration`
- displayed/coalesced frames only
- native decoder output through `JxlDecoder*`

First cut does **not** need to solve:
- reverse disposal optimization
- perfect palette compression
- staged sidecar extras during animation decode/export
- fancy GIF metadata beyond the Netscape loop extension + frame GCE delay/transparency
- Windows native GIF output support yet

## Concrete Plan For The Next Slice
1. Add a failing smoke, probably `tests/cli/djxlz_gif_animation_smoke.sh`.
- Generate the deterministic traffic-light GIF with `tests/cli/make_traffic_light_gif.c`.
- Convert it forward:
	- `cjxlz input.gif out.jxl`
- Convert it back:
	- `djxlz out.jxl out.gif --output_format gif`
- Re-feed the produced GIF through `cjxlz` and inspect the resulting JXL with `cjxlz_gif_info.zig`.
- Assert at least:
	- `100 1 0 4 300 100 300 100`
- This avoids needing a separate GIF reader helper for the first smoke.

2. Broaden `djxlz` CLI surface.
- Add `gif` to `--output_format`.
- Infer `gif` from `.gif` output suffix.
- Keep existing PPM/PGM/PAM behavior unchanged.

3. Add narrow GIF output build plumbing.
- Likely add `gif_output` build option in `build.zig`, default `true` for native builds.
- Keep Windows cross smoke honest by disabling GIF output there, analogous to `gif_input` / `png_input`.

4. Implement decoder-driven GIF writing in `src/cli/djxlz.c`.
- Subscribe to:
	- `JXL_DEC_BASIC_INFO`
	- `JXL_DEC_FRAME`
	- `JXL_DEC_FULL_IMAGE`
- Allocate output buffer once the basic info is known.
- Reuse the public decoder FFI only.
- On each `JXL_DEC_FRAME`, store current duration / name / last-flag info.
- On each `JXL_DEC_FULL_IMAGE`, quantize the decoded frame and emit one GIF frame.

5. Use `giflib` in C only.
- Similar scope discipline as the existing GIF input path in `src/cli/cjxlz.c`.
- Favor local palettes per frame to keep the first slice simpler.
- Handle binary transparency in the first cut if alpha is present.
- Coalesced frames mean we can avoid disposal reconstruction on output.

6. Run:
- targeted new smoke
- `./test`
- `./bm`
- only then commit

## Expected Technical Risks
1. giflib API details
- I had not yet finished looking up the exact write-side giflib calls when this handoff was written.
- The compile errors from the new smoke-driven implementation should be used to lock those down rather than guessing.

2. RGBA/grayscale output mapping
- `djxlz` currently has a still-image-oriented output path.
- For GIF export, decode may need a small helper that expands 1/2/3/4-channel decoder output into RGBA before quantization.

3. Quantization quality
- First cut should optimize for correctness and timing/loop preservation, not for perfect palette size or image quality.
- Local per-frame palette quantization is the simplest honest starting point.

4. Windows compile-only coverage
- If giflib output support complicates Windows cross builds, gate it behind `-Dgif_output=false` in the checked-in Windows smoke rather than pretending it is portable before it is.

## Relevant Files For The Next Slice
### Decoder / Public API
- `src/capi_root.zig`
- `lib/include/jxl/decode.h`
- `src/lib/codec/dec_frame.zig`

### Decoder CLI
- `src/cli/djxlz.c`
- `src/cli/djxlz_root.zig`

### Existing GIF Encode/Input Path To Reuse Conceptually
- `src/cli/cjxlz.c`
	- especially the GIF read/coalescing code around `parse_gif_animation(...)`

### Existing Animation/GIF Test Helpers
- `cjxlz_gif_info.zig`
- `tests/cli/make_traffic_light_gif.c`
- `tests/cli/cjxlz_gif_smoke.sh`
- `tests/cli/capi_decode_animation.sh`
- `tests/cli/cjxlz_animation_smoke.sh`

### Build / Packaging
- `build.zig`
- `flake.nix`
- `tests/cli/windows_cross_compile_smoke.sh`

## Commands That Were Most Recently Useful
- Check CI:
```bash
gh run list --branch yolo --limit 5 --json databaseId,headSha,status,conclusion,workflowName,displayTitle,createdAt,updatedAt
```
- Run full suite:
```bash
./test
```
- Run benchmarks:
```bash
./bm
```
- Run the two GIF-related smokes that previously broke CI:
```bash
nix develop -c bash tests/cli/cjxlz_gif_smoke.sh
nix develop -c bash tests/cli/capi_decode_animation.sh
```

## Notes About CI
- The old failures were:
	- `23921610074` on `3053d396`
	- `23922213846` on `c7a5d40c`
- Both were the same issue: missing untracked GIF fixture.
- The fix commit is:
	- `c222ecb0`
- The green run proving that fix is:
	- `23923290170`

## If You Resume After Reboot
1. Confirm branch and cleanliness:
```bash
git branch --show-current
git status --short
```
2. Confirm latest CI:
```bash
gh run list --branch yolo --limit 3 --json databaseId,headSha,status,conclusion,displayTitle
```
3. Start the failing smoke for `djxlz --output_format gif`.
4. Keep the slice narrow.
5. Do not skip the final `./test` and `./bm` before committing.
