# Container and frame completion controls

`tests/cli/capi_container.c` runs unchanged against upstream libjxl 0.12 and
the installed native C archive. It checks a valid raw stream and container,
a missing final-frame marker, missing `ftyp`, an incorrect major brand,
mixed whole/partial codestream boxes, an empty codestream and an invalid
codestream signature. It requires a completed frame for the valid controls
and a clean decoder error for malformed inputs; unexpected statuses and
exhausting the bounded event loop fail the check.

The control subscribes to box events as well as full-image events. Without
box events, upstream can finish after the final codestream before inspecting
trailing boxes. Whole-container validation requires visiting those boxes.

`src/capi/final_frame_test.zig` also checks open and closed input separately:
an unfinished stream requests more input while open and errors when closed.
Strict validation reports truncation after one decoded frame. The 39-byte
control is the retained coverage probe; clearing byte 9 removes its final
frame marker.

`src/capi/container_validation_test.zig` checks strict verdicts for malformed
boxes and short or invalid embedded signatures. Lower-level container tests
cover duplicate or misplaced `ftyp`, short brands, mixed `jxlc`/`jxlp` in
both orders, extended lengths and invalid offsets. Typed container errors
remain distinct from allocation and Brotli backend failures.

The small public controls do not replace the existing large corpus,
allocation-failure tests or container mutation checks.
