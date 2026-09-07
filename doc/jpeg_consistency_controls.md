# JPEG reconstruction consistency

Strict validation prepares JPEG reconstruction as well as decoding pixels when
a reconstruction box is present. This exercises coefficient recovery and JPEG
serialization. Proven incompatibility with Modular encoding is malformed input;
resource and unclassified decoder failures remain indeterminate.

`src/capi/jpeg_consistency_test.zig` attaches an existing reconstruction record
and its unchanged Exif/XMP payloads to the independently decoded 2x2 Modular
control. Both original inputs validate. Their incompatible combination used to
validate too, although public JPEG output rejected it. The strict regression
witnessed VALID before the fix and CORRUPT/MALFORMED afterward.

The same incompatible pair is checked through upstream and native JPEG output
by `tests/cli/capi_jpeg_consistency.c`. Its Lua generator copies the retained
JPEG fixture, preserves metadata boxes and puts the replacement codestream
after them. This order ensures reconstruction metadata is available before
frame decoding. The generator runs using the LuaJIT declared in the dev shell.
The C program requires a reconstruction event and a clean decoder error for
the incompatible control; an unexpected status fails.

Strict validation also accepts three retained natural JPEG transcodes and
all 160 sequential/progressive coefficient controls. Existing byte-exact
writer controls remain separate. Reconstruction uses a second decoding pass
and retains the prepared JPEG until the validation decoder is destroyed.
The added cost has not yet been benchmarked.
