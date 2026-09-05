# Wide Modular property controls

Valid 32-bit floating sample payloads can make signed Modular neighbor sums
and differences exceed i32. Upstream's generic path computes these in i64, then stores the
low 32 bits in its tree properties. Checked narrowing caused a decoder panic.
Absolute values also need that storage rule, including abs(INT32_MIN).

`tests/unit/wide_property_oracle.cc` calls upstream `Predict` and
`PrecomputeReferences` directly over a 7x4, two-channel image containing signed
extrema, zeros and opposite signs. It retains all 20 properties at each pixel.
Zig tests classify each observed value at its own threshold and one below it,
across the generic decoder and the compact property path. Reference-channel
values and gradient residuals are covered. Symbols are injected independently
of entropy decoding; an incorrect context selection changes the decoded sample.

The initial generic and compact checks both fail with integer-cast panics.
Replacing checked narrowing with low-bit truncation passes the controls.
The wide previous-gradient accumulator remains valid because the following
subtraction also retains only its low 32 bits; the upstream boundary controls
check this equivalence.

The complete-image test exposed a second behavior after the casts were fixed.
Upstream's gradient-only lookup path clamps the wide gradient to [-8192, 8191]
before selecting a context. That differs from its generic path when the sum
exceeds i32. The encoder uses the same fast path, so applying generic wrapping
to these files selects the wrong entropy context and fails the final ANS state.
The decoder now applies wide clamping only to trees that upstream admits to
this lookup path. `gradient_lookup_oracle.cc` supplies 600 independent admission
decisions spanning nested split boundaries, properties, predictors, offsets and
multipliers. This is compatibility with upstream's observed path selection;
the generic property controls continue to require wrapping.

`tests/unit/float_filter_oracle.cc` creates eight upstream-accepted 31x19
floating Modular files, with actual Gaborish and EPF header settings checked.
Case zero is unfiltered and reproduces the original property panic. Its complete
FLOAT output, including infinities, a NaN payload and signed zero, is compared
bit for bit through the public decoder, then repeated after rewind.
Cases one through seven are retained for the pending nonfinite filtering work;
they are not yet claimed as supported.

Build the property generator from the upstream checkout with the same private
library configuration used by the other retained C++ oracles (NDEBUG and no
RTTI), linking libjxl, its CMS, Highway and Brotli. Regenerate the two fixtures
by redirecting each generator's stdout; a nonzero exit means generation failed.
