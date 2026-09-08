# libjxlz intent

Build a native Zig JPEG XL implementation for precise data validation and
corruption detection in the `jpegz → tiffz → validate` stack. Complete coverage
of the JPEG XL specification remains required. Preserve the longer-term goal
of an efficient encoder/decoder with a C API and C command-line tools.

Peter reaffirmed these priorities on September 8, 2026. Validation accuracy and
useful invalidity findings take priority over matching reference-renderer output
bit for bit. Upstream can be permissive: its acceptance does not override a
demonstrated format violation. Investigate disagreements against the relevant
format constraint and preserve the evidence.

Detect single-bit corruption wherever the format supplies enough information.
A bit change can also produce another valid stream; validation alone cannot
recover that history. Report measured detection counts with their denominators,
input classes and mutation method. Do not present a deterministic corpus score
as a universal probability. Keep supported-valid, corrupt, unsupported and
operationally indeterminate outcomes distinguishable.

Prefer integer computation with explicit precision, scale and truncation.
IEEE 754 computation needs demonstrated necessity; encoded floating-point
storage and ABI types do not by themselves require floating-point arithmetic.
Keep exact format decisions and promised lossless reconstruction exact.
Operation-specific bounds may be appropriate for approximate image output.
Add runtime uncertainty tracking only when it has a demonstrated benefit to a
validation decision. Measure CPU and wall time rather than assuming a speedup.

Evidence of success includes full-spec feature coverage, known-valid acceptance
controls, constraint-specific malformed inputs, independently checked mutation
shapes, accurate public findings, allocation-failure controls, and builds for
Linux and Windows on x86_64/aarch64 plus macOS aarch64. These are goals; no
complete-coverage or universal detection claim is established here.

See [PLAN.md](PLAN.md) for current work,
[PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) for terminology, and
[the numerical validation audit](doc/numerical_validation_audit.md) for the
first decision-path findings under this priority.
