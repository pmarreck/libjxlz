# Floating sample effects

Full-resolution, non-XYB Modular images can preserve binary32 samples through
Gaborish, EPF, patches, YCbCr conversion and reference-frame blending. Stored
samples include signed zero, subnormals, infinities and NaNs. Integer image
paths keep their existing Fixed arithmetic.

`src/lib/base/binary32.zig` stores u32 bits and calls Zig's integer compiler
runtime arithmetic. Its f32/f64 arguments carry those bits across the ABI;
runtime arithmetic does not use native floating-point instructions. Compile-time
constants may use Zig floating-point evaluation. Zig 0.16's binary32 divider
flushes subnormal results, so that case uses integer binary64 widening/division
and binary32 narrowing. Every finite binary32 ratio fits normal binary64 range.

`binary32_test.zig` compares 20 by 20 boundary pairs and 200,000 seeded pairs
against strict native IEEE add, subtract, multiply and divide: 801,600 component
checks. Results require exact bits except NaNs, where class and quietness are
checked. This is sampled evidence, not exhaustive proof of all operand pairs.

The retained upstream generators in `tests/unit` supply complete encoded files
and decoded FLOAT output. They inspect actual frame headers before emitting
fixtures, so an encoder option alone cannot establish the intended coverage.

| Generator | Cases |
| --- | --- |
| `float_reference_oracle.cc` | 10 files; five frame blend modes, alpha/no alpha, crops, coalesced output and separate layers |
| `float_mixed_reference_oracle.cc` | 20 files; RGB-to-YCbCr and YCbCr-to-RGB references, all five modes, alpha/no alpha |
| `float_alpha_oracle.cc` | 10 files; integer color with nonfinite floating alpha, five modes and association/clamp states |
| `float_filter_oracle.cc` | 8 files; Gaborish off/on crossed with zero through three EPF iterations |
| `float_patch_oracle.cc` | 16 files; all eight patch modes with/without alpha and three overlapping placements |
| `float_blending_oracle.cc` | 64 configurations, 4,352 components; all eight modes, zero through two extras and numeric boundaries |

Public API tests repeat reference, mixed-reference and alpha files with and
without coalescing, then rewind and repeat. Patch files also rewind. Copied
samples require exact bits; computed NaNs require NaN class, and computed finite
values use each test's stated tolerance. Infinity and zero signs are checked.
Core tests inject every allocation failure for reference replacement, filters
and patches. Existing finite filter, blend, patch and aliasing controls remain.

Compile generators against the pinned in-tree upstream libjxl, using the same
private-header build flags as `float_filter_oracle.cc`. Fixtures are generated
artifacts; change their generators and regenerate rather than editing expected
pixels. The public API supplies the output oracle independently of libjxlz.

The arithmetic ABI probe is `src/binary32_abi_probe.zig`. For each target, run:

```sh
nix develop -c zig build-lib src/binary32_abi_probe.zig -O ReleaseFast \
  -target TARGET -static -fcompiler-rt -femit-bin=/tmp/binary32-TARGET.a
```

Static builds passed for x86_64-linux-musl, aarch64-linux-musl,
x86_64-windows-gnu, aarch64-windows-gnu and aarch64-macos. All seven compiler
runtime helper definitions were present in each archive. Selected x86_64 helper
disassembly contained no native scalar or packed floating arithmetic. This
checks cross-compilation and symbol availability, not runtime execution on
those other platforms or every instruction in the whole decoder. The helpers
use the C calling convention without naming libc as their provider. The probe
builds without `-lc` on all five targets; the standalone Windows core check
first caught the unnecessary libc dependency in the original declarations.

Remaining nonfinite coverage includes resampling, subsampled YCbCr, noise,
splines and VarDCT/XYB extra channels. JPEG reconstruction is a separate
unfinished feature. These tests do not establish full JPEG XL conformance.

Image allocation now rejects dimension products that overflow usize before
calling the allocator. The dimension-set regression first reproduced the
ReleaseSafe panic, then passed with checked products.
