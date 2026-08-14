# Current-state review — libjxlz

**Date:** 2026-08-14 EDT
**Scope:** strict JPEG XL validation, public C ABI, canonical controls, resource
bounds, and the documentation needed before jpegz, validate, or tiffz rely on
libjxlz. Retained upstream C++ source was reviewed only where it affects the
local build or cross-oracle.

## Release decision

Do not treat libjxlz as a trusted strict JPEG XL parser for parent projects
yet. The public decoder has a released-input use-after-free, the validator can
classify malformed bytes as UNSUPPORTED, and VALID does not guarantee public
decoder output.

Priority before feature coverage or encoder work:

1. Make input ownership and JxlDecoderReleaseInput safe.
2. Make strict verdicts sound and decide what VALID promises.
3. Add a strict-validation mutation matrix with clean exit classification and
   working-set limits.
4. Reconcile installed headers, exported symbols, and memory-manager behavior.

## 1. Inconsistent, incomplete, or undefined functionality

### CRITICAL — UNSUPPORTED comes from an unvalidated frame prefix

JxlValidate calls peekFrameEncoding and immediately returns UNSUPPORTED at
src/capi_root.zig:1322-1325. The helper does not validate the full frame header
at src/lib/codec/frame_header.zig:560-566. A damaged or truncated prefix can
therefore be reported as a valid unsupported feature, contrary to the
distinction promised by lib/include/jxl/validate.h:65-70. The recorded
sunset_logo mutation in COVERAGE_GAMEPLAN.md demonstrates the problem.

Parse a complete frame header before this verdict, or return INDETERMINATE for
a prefix-only feature decision. Add packaged-C controls for a malformed prefix
and the recorded mutation.

### CRITICAL — VALID does not imply public-decoder success

Validation returns VALID after FrameDecoder.decodeFrame at
src/capi_root.zig:1337-1349. The public decoder also requires
writeFrameDecoderOutput at src/capi_root.zig:1218-1223. sunset_logo.jxl is the
measured counterexample in COVERAGE_GAMEPLAN.md:97-107.

Run output-independent render checks during validation, or narrow and document
the success contract.

### WARNING — successful decoder settings are inert

JxlDecoderSetKeepOrientation, JxlDecoderSetUnpremultiplyAlpha,
JxlDecoderSetRenderSpotcolors, and JxlDecoderSetCoalescing store flags at
src/capi_root.zig:1476-1505, but no code reads them. Reject these calls until
they affect output, or implement and test each setting.

### WARNING — encoder version encoding disagrees with its header

JxlEncoderVersion returns 0x00010000 at src/capi_root.zig:374-376, while
lib/include/jxl/encode.h:34-39 specifies decimal major * 1000000 + minor *
1000 + patch. Version 0.1.0 should report 1000.

## 2. Inadequate test coverage

### CRITICAL — the oracle mutation gate never calls JxlValidate

tests/lib/mutation_detection.bash:168-190 runs djxlz, not the public strict
validator. The small C control at tests/cli/capi_strict_validate.c:69-107 does
not run generated mutations. The current gameplan records that all 264
oracle-rejected CLI mutants would return INDETERMINATE from JxlValidate.

Add a package-linked strict-validation matrix over the same base/mutant set.
Require VALID bases and typed outcomes for oracle-rejected mutations.

### WARNING — validation limits and Windows consumer boundaries lack controls

The C control does not cover max_pixels, max_frames, a too-small options
struct, or null input with non-zero size at src/capi_root.zig:1279-1284,
1312-1316, and 1333-1334. tests/cli/windows_cross_compile_smoke.sh:96-114
does not compile an external C consumer of validate.h.

## 3. Futile or gameable test coverage

### CRITICAL — crashes count as mutation detections

tests/lib/mutation_detection.bash:175-190 treats every non-zero djxlz exit as
a detection. The labelled corpus does the same at
tests/lib/labeled_corpus_matrix.bash:155-160,195-210. A signal exit can improve
the claimed score.

Reuse the classifier in tests/cli/fuzz_repro_regression_smoke.sh:43-67. Only
the defined clean-rejection status counts; acceptance, timeout, signal, and
other statuses must fail with the input identified.

### WARNING — labelled corrupt cases do not require oracle rejection

The corrupt branch ignores the oracle status. bicycles_corrupt_5.jxl is
accepted by stock djxl, but a generic libjxlz rejection would count as a
detection. Record oracle-rejected clean rejections, accepted may-ignore cases,
and mismatches separately.

## 4. Test speed and isolation

### WARNING — canonical CLI tests repeat Nix work

The 93 scripts enter nix develop individually at tests/lib/test_runner.bash:36-42;
83 look up the package and 82 evaluate the system. Build the package and resolve
the system once in ./test, then pass immutable overrides through the helper.

### WARNING — the C++ ICC oracle can be stale

tests/cli/capi_compressed_icc_cross_oracle.sh:42-62 skips its CMake/Ninja build
when a shared-TMPDIR archive exists. It is not keyed to source, flags, or
compiler. Use a per-run directory or a keyed build cache.

## 5. Superfluous or duplicated functionality

### WARNING — installed headers advertise absent symbols

build.zig:95-108 installs the upstream header set, but the partial archive does
not export many declarations, including JxlDecoderSetCms, image callbacks,
extra/JPEG buffers, JxlEncoderGetError, and JxlEncoderAddJPEGFrame. Consumers
compile and then fail to link.

Publish a symbol-complete libjxlz header subset, or explicit unsupported stubs.
Add a package ABI test that compares installed declarations with archive exports.

### WARNING — most C API smokes use source headers

Thirty-nine C smokes use source include paths while linking the package archive.
tests/cli/capi_strict_validate_smoke.sh:12-24 is the exception. Compile every
public-C smoke against the package include directory.

## 6. Code organization

### WARNING — the Zig validator depends on the C adapter

src/validation.zig:1-15 imports capi_root.zig, and the validation loop mutates
DecoderImpl through a C handle at src/capi_root.zig:1301-1307. Extract a pure
bounded validation core so both public APIs become thin adapters.

### WARNING — one 5,466-line C API root couples unrelated surfaces

src/capi_root.zig combines decoder scheduling, encoder state, ICC utilities,
strict validation, and embedded tests. Decoder lifecycle uses scattered flags
and reset paths at :237-296, :1117-1154, :1408-1420, and :1747-1838. Split
decoder, encoder, and validator adapters before broadening the ABI.

## 7. Algorithmic complexity and resource bounds

### CRITICAL — MA-tree filtering is quadratic

src/lib/modular/context_predict.zig:217 uses orderedRemove(0) for BFS. Each
removal shifts the queue. The filter runs per channel/group through
src/lib/modular/encoding.zig:484-494,928-948, while untrusted trees can reach
2^22 nodes at src/lib/modular/ma_common.zig:14. Use a head index or deque.

### CRITICAL — max_pixels does not bound validation memory

JxlValidate caps width times height at src/capi_root.zig:1312-1316, then
creates i32 planes per colour and extra channel at
src/lib/modular/modular_image.zig:102-114 and
src/lib/codec/dec_frame.zig:327-355. The default permits multi-GiB base planes
and substantially more for extras. Add a checked decoded-byte working-set
budget before image allocation.

### WARNING — brob validation has no decompressed-output cap

src/lib/codec/container.zig:189-192 validates every brob, and the Brotli
wrapper grows output without a cap at src/lib/base/brotli.zig:46-80. Apply a
metadata-decompression budget.

## 8. Files and documentation with unclear purpose

### WARNING — the published security route belongs to upstream libjxl

CONTRIBUTING.md:5 sends reporters to SECURITY.md, which identifies libjxl,
uses its CPE, and directs mail to Google's libjxl-security@google.com at
SECURITY.md:1-7,47. doc/vuln_playbook.md:5 repeats that destination. Replace
these with a libjxlz-owned reporting and supported-version policy. Do not
delete security guidance without a replacement.

### WARNING — README promotes upstream C++ manuals as local guidance

README.md:147-149 links doc/benchmarking.md and doc/building_and_testing.md,
which direct readers to CMake and ci.sh. Local commands are ./build, ./test,
and ./bm.

### ADVISORY — classify historical and upstream documentation

docs/plans/2026-03-06-*, IMPROVEMENTS.md, PROJECT_OVERVIEW.md, and the prior
CODE_REVIEW.md are historical or stale planning material. BUILDING*.md,
CHANGELOG.md, CODE_OF_CONDUCT.md, much of doc/, and plugin/tool READMEs are
retained upstream C++ reference documentation. Keep the latter while the CMake
cross-oracle remains, but label the distinction. AGENTS_previous.md is ignored
and superseded by AGENTS.md. zig-pkg/ is generated package-test output.

## 9. Language and boundary handling

### WARNING — a legal custom allocator can violate alignment assumptions

src/capi/memory_manager.zig:23-30 applies alignCast to callback memory, while
lib/include/jxl/memory_manager.h:23-31 allows arbitrary alignment. A conforming
byte allocator can trap object construction. Keep an aligned internal header
with the original pointer, or narrow the header contract.

### WARNING — C enum values reach exhaustive Zig switches unchecked

src/capi/pixel_format.zig:25-31 and src/capi_root.zig:1642-1644,1661-1663,
1683-1685 convert C-controlled enums without a rejection path. Validate them
before switching so bad C input returns JXL_DEC_ERROR.

## 10. Memory safety and resource leaks

### CRITICAL — released input remains referenced by frame_data

ensureParsed stores frame_data as a caller-owned raw-codestream slice at
src/capi_root.zig:1196-1199. JxlDecoderReleaseInput clears the visible input
pointer and returns zero at :1520-1526, allowing the caller to free it. Later
parsing/output reads frame_data at :1038-1058,1218-1222. JxlDecoderRewind also
clears input without clearing derived state.

Copy or retain input until reset, or accurately track the unconsumed suffix.
Clear all input-derived slices on release and rewind. This is the first blocker.

### WARNING — error paths leak container and image allocations

extractCodestreamAndBoxes can leak a duplicated jxlc after a later parse failure
at src/lib/codec/container.zig:202-208,221-252. appendOwnedBox leaks a duplicate
on append failure at :141-146. Image.create leaks partially created channels
on allocation/append failure at src/lib/modular/modular_image.zig:102-115. Add
ownership-transfer errdefer cleanup at each boundary.

## 11. FFI boundary correctness

### CRITICAL — streaming C callers can trigger the released-input use-after-free

The issue in section 10 violates the streaming contract in
lib/include/jxl/decode.h:602-638. Full-buffer tests hide it. Add a C control
that supplies two chunks, releases the first, and continues after invalidating
its memory.

### WARNING — custom JxlMemoryManager ownership stops at the top-level object

Decoder/encoder state, frames, queues, boxes, and pixel copies use
std.heap.c_allocator after accepting a manager at
src/capi_root.zig:390-457,1139-1161,1864-1879. This contradicts
lib/include/jxl/memory_manager.h:47-59. Thread the manager through all
per-instance allocations or reject non-null managers.

## 12. Error handling gaps

### CRITICAL — C image-buffer sizing can overflow before allocation

rowStrideBytes multiplies untrusted width, channels, and sample size without
checked arithmetic at src/capi/pixel_format.zig:35-39. Callers multiply again
by height at src/capi_root.zig:1728-1729,2112-2113 and
src/capi/output_buffer.zig:87-88. Use checked multiplication and alignment
addition throughout buffer sizing and writing.

### WARNING — short trailing BMFF data is accepted

The container loop exits with 1–7 bytes remaining at
src/lib/codec/container.zig:214,245-254, allowing VALID with an incomplete
trailing box header. Require exact container consumption.

### WARNING — typed failures collapse to GenericError

TOC/context-map/MA parsing maps truncation and OOM to GenericError at
src/lib/codec/toc.zig:85-121, src/lib/entropy/dec_context_map.zig:65-82, and
src/lib/modular/dec_ma.zig:162-185. MA-tree validation returns success if its
page-allocator allocation fails at src/lib/modular/dec_ma.zig:50-75. Preserve
NotEnoughBytes and OutOfMemory, add a typed malformed-input error, and use the
caller allocator.

## 13. Database access

Not applicable. This repository has no database or ORM layer.

## Documentation cleanup disposition

| Material | Disposition |
| --- | --- |
| HANDOFF-20260805103315EDT.md | Moved to system Trash after review. It described completed August 6 work as pending. |
| PLAN.md | Refreshed during this audit: removed the obsolete bicycles failure and 3/8 matrix claims; added strict-parser blockers. More historical pruning remains useful. |
| COVERAGE_GAMEPLAN.md | Current priority source. Keep. |
| SECURITY.md, CONTRIBUTING.md, doc/vuln_playbook.md | Replace the upstream-only reporting route before public parent integration. This needs Peter's security contact and supported-version policy. |
| README.md | Update before release: remove or label April ReleaseFast benchmark claims, fix ./build --debug to ./build debug, and distinguish local docs from upstream C++ references. |
| docs/plans/2026-03-06-*, IMPROVEMENTS.md, PROJECT_OVERVIEW.md | Archive or consolidate after retaining decisions useful to the current coverage plan. |
| upstream C++ docs | Retain while the CMake-based cross-oracle remains; mark them as upstream reference rather than libjxlz instructions. |

## Next review gate

After the first four release priorities are fixed, run the strict corpus matrix
through the packaged C API, a released-input lifetime control, full ./test,
./build, the package ABI/header check, and a Mechatron target that executes the
shell controls rather than only Zig units.
