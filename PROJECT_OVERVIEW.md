# libjxlz

A Zig reimplementation of the JPEG XL (ISO 18181) reference codec, targeting
equivalent or better performance than the original C++ libjxl.

## Terminology
- **JXL**: JPEG XL image format
- **ANS**: Asymmetric Numeral Systems (entropy coding)
- **MA tree**: Meta-Adaptive tree (modular integer coding)
- **XYB**: Perceptual color space used by JXL
- **DCT**: Discrete Cosine Transform
- **Highway**: Google's SIMD abstraction library (being replaced by Zig @Vector)
- **cjxl/djxl**: Original compress/decompress CLI tools
- **cjxlz/djxlz**: Our Zig-based equivalents
