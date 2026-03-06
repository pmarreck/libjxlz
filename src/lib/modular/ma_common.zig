// MA tree context IDs and constants.
// Transliterated from lib/jxl/modular/encoding/ma_common.h

pub const MATreeContext = enum(usize) {
    split_val = 0,
    property = 1,
    predictor = 2,
    offset = 3,
    multiplier_log = 4,
    multiplier_bits = 5,
};

pub const kNumTreeContexts: usize = 6;
pub const kMaxTreeSize: usize = 1 << 22;
