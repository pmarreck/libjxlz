# JPEG reconstruction controls

The production decoder reconstructs JPEG bytes with Zig coefficient recovery,
marker serialization and metadata insertion. It does not link upstream libjxl.
Upstream remains the independent development reference for these tests.

`jpeg_writer_test.zig` compares complete original JPEG bytes for 80 sequential,
80 progressive, 16 marker/padding and two long progressive EOB cases. The long
cases each have 33,024 blocks, crossing the 32,767-block run limit, with and
without buffered refinement bits. The generator transcodes JPEGs made by
upstream's JPEG writer, then parses those JPEGs independently before encoding
JPEG XL. The coefficient tests separately compare all quantized coefficients.

`jpeg_payloads_test.zig` checks Exif/XMP restoration and a profile split across
two ICC markers. Allocation-failure sweeps cover output growth, refinement
buffers and compressed metadata. `jpeg_output_test.zig` compares the public
API against three original JPEGs and upstream event traces; it also checks
small buffers, rewind, missing/duplicate/mismatched metadata and pixel fallback.
The CLI C test links the installed headers and archive, reconstructs the retained
Exif/XMP JPEG and repeats through rewind and reset.

To reproduce fixtures, build the retained C++ sources against this checkout's
pinned upstream library. Private JPEG structures require matching build defines
(`-DNDEBUG -fno-rtti` for the current Release build). From the repository root:

```bash
jpeg_writer_oracle testdata/jxl/jpeg_reconstruction/bicycles_restarts.jpg --synthetic > progressive.zig
jpeg_writer_oracle testdata/jxl/jpeg_reconstruction/bicycles_restarts.jpg --details > details.zig
jpeg_writer_oracle testdata/jxl/jpeg_reconstruction/bicycles_restarts.jpg --eob > eob.zig
jpeg_writer_oracle testdata/jxl/jpeg_reconstruction/sideways_bench.jpg --metadata > metadata.zig
jpeg_output_oracle testdata/jxl/jpeg_reconstruction/1x1_exif_xmp.jpg testdata/jxl/jpeg_reconstruction/bicycles_restarts.jpg testdata/jxl/jpeg_reconstruction/sideways_bench.jpg | awk '/^\/\/|^pub const (events_|remaining_|bytes_|jpeg_|dimensions_)/' > jpeg_output_fixture.zig
```

These controls establish the listed cases. They do not by themselves establish
full JPEG XL conformance or justify removing all differential tests.
