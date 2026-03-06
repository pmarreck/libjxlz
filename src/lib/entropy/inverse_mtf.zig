// Inverse move-to-front transform.
// Transliterated from lib/jxl/inverse_mtf-inl.h
// Simplified: no SIMD for now (scalar path). IMPROVEMENT: add @Vector optimization later.

const std = @import("std");

fn moveToFront(v: *[256]u8, index: u8) void {
    const value = v[index];
    var i: usize = index;
    while (i > 0) : (i -= 1) {
        v[i] = v[i - 1];
    }
    v[0] = value;
}

/// Applies the inverse move-to-front transform in-place.
pub fn inverseMoveToFrontTransform(data: []u8) void {
    var mtf: [256]u8 = undefined;
    for (0..256) |i| {
        mtf[i] = @intCast(i);
    }
    for (data) |*d| {
        const index = d.*;
        d.* = mtf[index];
        if (index != 0) moveToFront(&mtf, index);
    }
}

// ── Tests ──

const testing = std.testing;

test "inverseMoveToFrontTransform identity" {
    // All zeros = identity (first element stays first)
    var data = [_]u8{ 0, 0, 0, 0, 0 };
    inverseMoveToFrontTransform(&data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, &data);
}

test "inverseMoveToFrontTransform sequence" {
    // Input [0,1,2,3] -> output [0,1,2,3] (each selects next unvisited)
    var data = [_]u8{ 0, 1, 2, 3 };
    inverseMoveToFrontTransform(&data);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3 }, &data);
}

test "inverseMoveToFrontTransform repeat" {
    // Input [1,0,0] -> MTF starts as [0,1,2,...]
    // Step 0: index=1 -> value=1, MTF becomes [1,0,2,...]
    // Step 1: index=0 -> value=1, MTF stays [1,0,2,...]
    // Step 2: index=0 -> value=1, MTF stays [1,0,2,...]
    var data = [_]u8{ 1, 0, 0 };
    inverseMoveToFrontTransform(&data);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1 }, &data);
}

test "inverseMoveToFrontTransform known values" {
    // Encode "ABRACADABRA" (65,66,82,65,67,65,68,65,66,82,65)
    // as MTF indices, then verify inverse recovers original.
    // MTF: [0..255] initially
    // 'A'=65: index=65, MTF->A front. output[0]=65
    // 'B'=66: index=66, MTF->B front. output[1]=66
    // 'R'=82: index=83, MTF->R front. output[2]=82
    // 'A'=65: index=3, MTF->A front. output[3]=65
    // etc.
    var data = [_]u8{ 65, 66, 83, 3, 69, 3, 70, 3, 5, 6, 3 };
    inverseMoveToFrontTransform(&data);
    try testing.expectEqualSlices(u8, "ABRACADABRA", &data);
}
