# Improvement Notes

Items spotted during transliterative port — do NOT implement inline.
Revisit after full port is complete and all tests pass.

## Foundation Layer
- [ ] byte_order.zig: C++ has extensive #if branches for endianness. Zig's std.mem.readInt handles natively. Verify codegen is equivalent.
- [ ] bit_reader.zig: Consider comptime specialization for common bit widths (C++ uses template<size_t N> for PeekFixedBits).
- [ ] bit_reader.zig: BMI2 `_bzhi_u64` in PeekBits — Zig @Vector or inline asm could match this on x86.
- [ ] common.zig: C++ UninitializedAllocator pattern could map to Zig's undefined initialization — benchmark.
- [ ] random.zig: Consider using Zig's comptime to generate lookup tables for geometric distribution.
- [ ] rect.zig: C++ RectT is templated over T (size_t, int64_t). Our Rect is usize-only. May need signed variant for encoder.
- [ ] General: All base modules use runtime assertions (std.debug.assert). Consider comptime validation where possible.

## SIMD (future)
- [ ] Zig @Vector + comptime dispatch could replace Highway's runtime CPU detection entirely.
- [ ] The 15 *-inl.h files are self-contained — each can be ported independently.
- [ ] DCT and ANS are the hottest paths — prioritize SIMD there.

## Architecture (future)
- [ ] Arena allocators for frame-scoped memory (C++ uses RAII).
- [ ] Zig's comptime could generate entropy coding tables at compile time.
- [ ] Thread pool: use std.Thread.Pool instead of C++ custom threading.
