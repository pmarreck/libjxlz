const std = @import("std");
const status = @import("status.zig");
const byte_order = @import("byte_order.zig");
const JxlError = status.JxlError;

/// 64-bit buffered bitstream reader with deferred refills.
/// Reads little-endian bitstreams. Zig port of jxl::BitReader.
///
/// Key design: maintains a 64-bit buffer with lazy refilling.
/// Fast path does an 8-byte LE load when enough data remains;
/// slow path loads byte-by-byte and tracks overread for Close() validation.
pub const BitReader = struct {
	const Self = @This();
	pub const kMaxBitsPerCall: usize = 56;
	const kBitsPerByte: usize = 8;

	buf: u64 = 0,
	bits_in_buf: usize = 0, // [0, 64)
	data: []const u8,
	pos: usize = 0, // byte position (replaces next_byte_ pointer)
	overread_bytes: u64 = 0,
	close_called: bool = false,
	checked_out_of_bounds_bits: u64 = 0,

	/// Initialize a BitReader from a byte slice. Performs an initial refill.
	pub fn init(data: []const u8) Self {
		var self = Self{
			.data = data,
		};
		self.refill();
		return self;
	}

	/// Fast-path refill: load 8 bytes LE when safe, else bounds-checked byte-by-byte.
	pub fn refill(self: *Self) void {
		if (self.pos + 8 > self.data.len) {
			self.boundsCheckedRefill();
		} else {
			// Safe to load 64 bits; insert valid bits above bits_in_buf.
			const loaded = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
			self.buf |= loaded << @intCast(self.bits_in_buf);

			// Advance by bytes fully absorbed into the buffer.
			self.pos += (63 - self.bits_in_buf) >> 3;

			// Set bits_in_buf to >= 56 while preserving lower 3 bits.
			self.bits_in_buf |= 56;
		}
	}

	/// Slow-path refill: load byte-by-byte, track overread.
	fn boundsCheckedRefill(self: *Self) void {
		const end = self.data.len;

		// Read whole bytes until we have [56, 64) bits
		while (self.bits_in_buf < 64 - kBitsPerByte) {
			if (self.pos >= end) break;
			self.buf |= @as(u64, self.data[self.pos]) << @intCast(self.bits_in_buf);
			self.pos += 1;
			self.bits_in_buf += kBitsPerByte;
		}

		// Add extra zero bytes to fill to [56, 64) bits
		const extra_bytes = (63 - self.bits_in_buf) / kBitsPerByte;
		self.overread_bytes += extra_bytes;
		self.bits_in_buf += extra_bytes * kBitsPerByte;
	}

	/// Returns the lowest `nbits` bits from the buffer without consuming them.
	/// It is legal to peek at more bits than present in the stream; those bits are zero.
	pub fn peekBits(self: *const Self, nbits: usize) u64 {
		std.debug.assert(nbits <= kMaxBitsPerCall);
		std.debug.assert(!self.close_called);
		if (nbits == 0) return 0;
		const mask = (@as(u64, 1) << @intCast(nbits)) - 1;
		return self.buf & mask;
	}

	/// Remove `num_bits` bits from the buffer.
	pub fn consume(self: *Self, num_bits: usize) void {
		std.debug.assert(!self.close_called);
		std.debug.assert(self.bits_in_buf >= num_bits);
		self.bits_in_buf -= num_bits;
		if (num_bits < 64) {
			self.buf >>= @intCast(num_bits);
		} else {
			self.buf = 0;
		}
	}

	/// Refill, peek, consume: the standard read operation.
	pub fn readBits(self: *Self, nbits: usize) u64 {
		std.debug.assert(!self.close_called);
		self.refill();
		const bits = self.peekBits(nbits);
		self.consume(nbits);
		return bits;
	}

	/// Skip over `skip` bits efficiently.
	pub fn skipBits(self: *Self, skip_param: usize) void {
		std.debug.assert(!self.close_called);
		var skip = skip_param;

		// Buffer is large enough
		if (skip <= self.bits_in_buf) {
			self.consume(skip);
			return;
		}

		// First deduct what we can satisfy from the buffer
		skip -= self.bits_in_buf;
		self.bits_in_buf = 0;
		self.buf = 0;

		// Skip whole bytes
		const whole_bytes = skip / kBitsPerByte;
		skip = skip % kBitsPerByte;

		if (whole_bytes > self.data.len -| self.pos) {
			// Overflow: skipping past end of stream
			self.pos = self.data.len;
			skip += kBitsPerByte;
		} else {
			self.pos += whole_bytes;
		}

		self.refill();
		self.consume(skip);
	}

	/// Returns the total number of bits consumed so far.
	pub fn totalBitsConsumed(self: *const Self) usize {
		return (self.pos + self.overread_bytes) * kBitsPerByte - self.bits_in_buf;
	}

	/// Returns total number of bytes in the input.
	pub fn totalBytes(self: *const Self) usize {
		return self.data.len;
	}

	/// Jump to the next byte boundary. Returns error if padding bits are non-zero.
	pub fn jumpToByteBoundary(self: *Self) JxlError!void {
		const remainder = self.totalBitsConsumed() % kBitsPerByte;
		if (remainder == 0) return;
		const padding_bits = kBitsPerByte - remainder;
		if (self.readBits(padding_bits) != 0) {
			return JxlError.GenericError;
		}
	}

	/// Returns whether all bits read so far have been within the input bounds.
	/// Records the checkpoint so Close() won't error for reads already validated.
	pub fn allReadsWithinBounds(self: *Self) bool {
		self.checked_out_of_bounds_bits = self.totalBitsConsumed();
		return self.totalBitsConsumed() <= self.totalBytes() * kBitsPerByte;
	}

	/// Close the bit reader. Must be called exactly once.
	/// Returns error if more bits were consumed than available and not previously checked.
	pub fn close(self: *Self) JxlError!void {
		std.debug.assert(!self.close_called);
		self.close_called = true;
		if (self.data.len == 0 and self.pos == 0) return;
		const total_consumed = self.totalBitsConsumed();
		const total_available = self.totalBytes() * kBitsPerByte;
		if (total_consumed > self.checked_out_of_bounds_bits and
			total_consumed > total_available)
		{
			return JxlError.GenericError;
		}
	}
};

// ============================================================================
// Tests
// ============================================================================

test "reads single bits" {
	// byte 0b10110100 = 0xB4
	// LSB-first: bits are 0,0,1,0,1,1,0,1
	var data = [_]u8{0xB4};
	var br = BitReader.init(&data);
	try std.testing.expectEqual(@as(u64, 0), br.readBits(1)); // bit 0
	try std.testing.expectEqual(@as(u64, 0), br.readBits(1)); // bit 1
	try std.testing.expectEqual(@as(u64, 1), br.readBits(1)); // bit 2
	try std.testing.expectEqual(@as(u64, 0), br.readBits(1)); // bit 3
	try std.testing.expectEqual(@as(u64, 1), br.readBits(1)); // bit 4
	try std.testing.expectEqual(@as(u64, 1), br.readBits(1)); // bit 5
	try std.testing.expectEqual(@as(u64, 0), br.readBits(1)); // bit 6
	try std.testing.expectEqual(@as(u64, 1), br.readBits(1)); // bit 7
	try br.close();
}

test "reads multi-bit values" {
	// [0xCD, 0xAB] -> readBits(16) should give 0xABCD (little-endian)
	var data = [_]u8{ 0xCD, 0xAB };
	var br = BitReader.init(&data);
	try std.testing.expectEqual(@as(u64, 0xABCD), br.readBits(16));
	try br.close();
}

test "totalBitsConsumed tracks" {
	var data = [_]u8{ 0xFF, 0xFF };
	var br = BitReader.init(&data);
	try std.testing.expectEqual(@as(usize, 0), br.totalBitsConsumed());
	_ = br.readBits(3);
	try std.testing.expectEqual(@as(usize, 3), br.totalBitsConsumed());
	_ = br.readBits(5);
	try std.testing.expectEqual(@as(usize, 8), br.totalBitsConsumed());
	try br.close();
}

test "jumpToByteBoundary" {
	// 3 bits of data then 5 zero-padding bits
	var data = [_]u8{0x05}; // 0b00000101 — low 3 bits are 101, upper 5 are 0
	var br = BitReader.init(&data);
	_ = br.readBits(3); // read the 3 data bits
	try br.jumpToByteBoundary(); // should consume 5 zero-padding bits
	try std.testing.expectEqual(@as(usize, 8), br.totalBitsConsumed());
	try br.close();
}

test "overread returns zeros and close errors" {
	var data = [_]u8{0xFF};
	var br = BitReader.init(&data);
	// Read the 8 valid bits
	try std.testing.expectEqual(@as(u64, 0xFF), br.readBits(8));
	// Read 8 more — should get zeros (overread)
	try std.testing.expectEqual(@as(u64, 0), br.readBits(8));
	// Close should return error because we read past end
	try std.testing.expectError(JxlError.GenericError, br.close());
}

test "empty input" {
	var data = [_]u8{};
	var br = BitReader.init(&data);
	try br.close();
}

test "skipBits works" {
	// 4 bytes: 0xAA, 0xBB, 0xCC, 0xDD
	// As a 32-bit LE value: 0xDDCCBBAA
	// Skip 16 bits (0xBBAA), then read 16 bits -> should get 0xDDCC
	var data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
	var br = BitReader.init(&data);
	br.skipBits(16);
	try std.testing.expectEqual(@as(u64, 0xDDCC), br.readBits(16));
	try br.close();
}

test "allReadsWithinBounds" {
	var data = [_]u8{ 0xFF, 0xFF };
	var br = BitReader.init(&data);
	_ = br.readBits(8);
	try std.testing.expect(br.allReadsWithinBounds());
	// Read past end
	_ = br.readBits(8);
	_ = br.readBits(8); // overread
	try std.testing.expect(!br.allReadsWithinBounds());
	// Close should succeed because we called allReadsWithinBounds
	// which set checked_out_of_bounds_bits to the current position
	try br.close();
}

test "large sequential reads" {
	// 64 bytes of incrementing pattern
	var data: [64]u8 = undefined;
	for (0..64) |i| {
		data[i] = @intCast(i);
	}
	var br = BitReader.init(&data);

	// Read multiple 56-bit chunks (kMaxBitsPerCall)
	// First 7 bytes: 0x06050403020100
	const chunk1 = br.readBits(56);
	try std.testing.expectEqual(@as(u64, 0x06050403020100), chunk1);

	// Next 7 bytes: 0x0D0C0B0A090807
	const chunk2 = br.readBits(56);
	try std.testing.expectEqual(@as(u64, 0x0D0C0B0A090807), chunk2);

	try br.close();
}

test "reads across refill boundary" {
	// Set up data where a read spans the boundary between refills.
	// With 9 bytes, initial refill loads ~7 bytes (56 bits).
	// Read 50 bits, then read 22 bits (which requires a refill mid-way).
	var data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99 };
	var br = BitReader.init(&data);

	// Read 50 bits
	const first = br.readBits(50);
	// Verify: first 50 bits of LE stream 0x8877665544332211
	const full_le: u64 = 0x8877665544332211;
	const expected_first = full_le & ((@as(u64, 1) << 50) - 1);
	try std.testing.expectEqual(expected_first, first);

	// Read 22 more bits (needs refill since we only had ~56 bits initially)
	const second = br.readBits(22);
	// Next 22 bits starting at bit 50
	// But we also need byte 8 (0x99) — the full 9-byte LE value doesn't fit in u64.
	// Actually 9 bytes > 8 bytes, so let's compute carefully.
	// After consuming 50 bits, 6 bits remain in buf from first load.
	// Refill loads byte 8 (0x99), giving us enough bits.
	// Bits 50..71 of the 9-byte stream:
	// Byte 6 = 0x77 (bits 48-55), byte 7 = 0x88 (bits 56-63), byte 8 = 0x99 (bits 64-71)
	// Bits 50-55: upper 6 bits of 0x77 = 0x77 >> 2 = 0x1D (but masked to 6 bits = 0b011101 = 0x1D)
	// Bits 56-63: 0x88 = 0b10001000
	// Bits 64-71: 0x99 = 0b10011001
	// So bits 50..71 = (0x99 << 14) | (0x88 << 6) | (0x77 >> 2)
	// But we only have bits 50..71 which is 22 bits
	const expected_second: u64 = (@as(u64, 0x99) << 14) | (@as(u64, 0x88) << 6) | (@as(u64, 0x77) >> 2);
	const mask_22 = (@as(u64, 1) << 22) - 1;
	try std.testing.expectEqual(expected_second & mask_22, second);

	try br.close();
}

test "peekBits does not consume" {
	var data = [_]u8{0xAB};
	var br = BitReader.init(&data);
	// Peek should not advance position
	try std.testing.expectEqual(@as(u64, 0xAB), br.peekBits(8));
	try std.testing.expectEqual(@as(usize, 0), br.totalBitsConsumed());
	// Read same bits
	try std.testing.expectEqual(@as(u64, 0xAB), br.readBits(8));
	try std.testing.expectEqual(@as(usize, 8), br.totalBitsConsumed());
	try br.close();
}

test "jumpToByteBoundary non-zero padding errors" {
	// byte 0xFF — read 3 bits (all 1s), then jumpToByteBoundary should fail
	// because remaining 5 bits are all 1s (non-zero padding)
	var data = [_]u8{0xFF};
	var br = BitReader.init(&data);
	_ = br.readBits(3);
	try std.testing.expectError(JxlError.GenericError, br.jumpToByteBoundary());
	try br.close();
}
