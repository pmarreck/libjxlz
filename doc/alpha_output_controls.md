# Alpha output controls

`tests/unit/alpha_output_oracle.cc` encodes lossless images with the pinned
upstream API and records exact decoder bytes. The default input is RGB;
`gray` selects grayscale, a second argument `rotate` sets orientation 6,
and a third argument adds an actual preview. Preview construction rewrites
the metadata and preserves any container wrapper; upstream verifies both
preview and main output. `alpha_float_input_oracle.cc` supplies floating-point
encoded input, including negative colors and alpha below 2^-26.

The native matrix checks 672 decoder configurations across association and
unpremultiply flags, 8/16-bit integer and floating encoded samples, UINT8,
UINT16, FLOAT and FLOAT16 output, compatible channel counts, identity/rotated
output, and actual previews. Fixture identifier 17 means FLOAT16; 16 means
UINT16. Separate checks cover rewind/reset and oriented-buffer allocation
failures. These are exact byte comparisons to upstream output.

Upstream retains the associated-alpha metadata flag. Unpremultiplication
changes colors only when output includes alpha. It divides by alpha with a
minimum denominator of 2^-26, before sample quantization. UINT16 conversion
rounds ties to even. UINT8 dithering uses coordinates after reflection and
before transposition. The native conversion uses integer-backed binary32
arithmetic; floating values carry storage and public ABI samples.

Witnessed regressions included ignored unpremultiplication, alpha occupying
the green component of expanded grayscale, omitted wide-input dithering,
FLOAT normalization rounding, UINT16 halfway rounding and transposed dither
coordinates. `gray_quantization_oracle.cc` independently verifies the updated
10-bit grayscale output test through the public upstream encoder/decoder.

The prior normalization path for integer depths >=23 remains unchanged.
These controls do not establish every orientation with every floating value,
associated-alpha animation, or nonfinite input under unpremultiplication.
Other existing tests cover nonfinite alpha without that option.

Affected oriented UINT8 output retains FLOAT samples until quantization,
using four times the packed-pixel temporary storage of UINT8 samples. Identity
output needs no orientation temporary. Timing and whole-decoder memory costs
remain to be measured after the canonical gates finish.
