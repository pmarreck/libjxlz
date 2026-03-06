// ANS and prefix coding parameters.
// Transliterated from lib/jxl/ans_params.h

pub const ans_log_tab_size: u5 = 12;
pub const ans_tab_size: u32 = 1 << ans_log_tab_size;
pub const ans_tab_mask: u32 = ans_tab_size - 1;

/// Largest possible symbol to be encoded by either ANS or prefix coding.
pub const prefix_max_alphabet_size: u32 = 4096;
pub const ans_max_alphabet_size: u32 = 256;

/// Max number of bits for prefix coding.
pub const prefix_max_bits: u5 = 15;

/// Initial state, used as CRC.
pub const ans_signature: u32 = 0x13;

const std = @import("std");
const testing = std.testing;

test "ANS parameter relationships" {
    try testing.expectEqual(@as(u32, 4096), ans_tab_size);
    try testing.expectEqual(@as(u32, 4095), ans_tab_mask);
    try testing.expectEqual(ans_tab_size - 1, ans_tab_mask);
    try testing.expectEqual(@as(u32, 1) << ans_log_tab_size, ans_tab_size);
}
