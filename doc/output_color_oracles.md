# Output color references

`gray_profile_oracle.cc` decodes the labeled 200x200 grayscale ICC file through
upstream's public decoder. It retains original/data ICC bytes, gray/RGB UINT8
pixels and gray FLOAT samples. Its packaged PAM output is byte-exact. The
16 files from `color_frame_oracle.cc` add gray alpha, RGB alpha, Modular and
VarDCT, with the actual frame mode and filter headers checked before export.

`transfer_frame_oracle.cc` produces 28 complete 17x11 codestreams. Each of
BT.709, linear, sRGB, PQ, DCI, HLG and explicit gamma appears in RGB and gray,
through both Modular and VarDCT. Intensity targets are 255 and 1000 nits.
It retains UINT8, FLOAT and preferred-linear FLOAT outputs from upstream.

The tests separate three sources of numeric differences:

- Whole images must stay within one UINT8 level. FLOAT uses an absolute bound
  of 0.0002, or 1/255 for PQ and HLG near-black amplification.
- Linear reconstruction uses an absolute bound of 0.0001 plus a relative
  bound of 0.00001. HDR samples can substantially exceed 1.
- Applying the transfer to upstream's own linear samples uses 0.0002. PQ also
  has a scalar reference from upstream's `TF_PQ_Base::EncodedFromDisplay`.
  For example, at 255 nits and linear input 0.0001582588, the direct formula
  returns about 0.04186425; upstream's SIMD approximation returns 0.04211871.

`transfer_stage_oracle.cc` invokes upstream's actual render stage with 24
signed/boundary inputs and four intensity targets (255, 334, 1000 and 10000).
The 2,016 component checks include signed zero, gamma thresholds and PQ's
low-intensity transition. PQ's scalar formula has a 0.000002 bound; other
stage comparisons use 0.0002, except sRGB above magnitude 1, where upstream's
rational approximation differs from the power formula (bound 1/255).
Zero results also have exact bit assertions.

HLG's luminance power uses upstream's range reduction and polynomial sequence.
Replacing it with a generic power function fails on negative reconstructed
luminance, including a complete grayscale file. The retained stage inputs
exercise that behavior directly.

These conversions run at the existing floating output boundary. Frame
reconstruction, filters and compositing continue to use `sf.Fixed`. The tests
retain both scalar and SIMD upstream results so future optimizations can be
checked against their actual numerical behavior.
