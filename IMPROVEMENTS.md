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

## Entropy Layer
- [ ] ans_common.zig: AliasTable.Lookup uses branching; C++ uses branchless CMOV via memcpy trick on little-endian. Consider @bitCast on packed struct for equivalent.
- [ ] huffman.zig: BuildHuffmanTable uses pointer arithmetic for 2nd-level tables. Consider using slice offsets instead for safety.
- [ ] huffman.zig: ReadSimpleCode sorting could use comptime-generated lookup tables for the 5 cases.
- [ ] inverse_mtf.zig: Currently scalar; C++ uses Highway SIMD for the shift. Zig @Vector could accelerate the move-to-front shuffle.
- [ ] dec_ans.zig: ANSSymbolReader branchless normalization matches C++ but could benchmark Zig's branch predictor behavior.
- [ ] dec_ans.zig: ReadHistogram hardcoded huff[128] table — could be comptime-generated from the code length distribution.
- [ ] dec_context_map.zig: Non-simple context map path (ANS-based) is stubbed. Wire up when DecodeHistograms is used in frame decoding.
- [ ] General: Entropy modules use std.mem.Allocator pervasively; consider arena allocators for frame-scoped decoding.

## SIMD (future)
- [ ] Zig @Vector + comptime dispatch could replace Highway's runtime CPU detection entirely.
- [ ] The 15 *-inl.h files are self-contained — each can be ported independently.
- [ ] DCT and ANS are the hottest paths — prioritize SIMD there.

## Architecture (future)
- [ ] Arena allocators for frame-scoped memory (C++ uses RAII).
- [ ] Zig's comptime could generate entropy coding tables at compile time.
- [ ] Thread pool: use std.Thread.Pool instead of C++ custom threading.
