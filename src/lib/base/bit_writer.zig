// BitWriter foundation for encoder-side work.
// Matches BitReader's LSB-first byte layout so later encoder work can roundtrip.

const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;

pub const BitWriter = struct {
	pub const kMaxBitsPerCall: usize = 56;

	allocator: std.mem.Allocator,
	storage: std.ArrayList(u8) = .empty,
	bits_written: usize = 0,

	pub fn init(allocator: std.mem.Allocator) BitWriter {
		return .{
			.allocator = allocator,
			.storage = .empty,
		};
	}

	pub fn deinit(self: *BitWriter) void {
		self.storage.deinit(self.allocator);
	}

	pub fn bitsWritten(self: *const BitWriter) usize {
		return self.bits_written;
	}

	pub fn bytes(self: *const BitWriter) []const u8 {
		std.debug.assert(self.bits_written % 8 == 0);
		return self.storage.items[0 .. self.bits_written / 8];
	}

	/// Reserves byte storage for an upcoming bit burst while keeping unwritten
	/// bytes zeroed, so repeated `write` calls can avoid growth churn.
	pub fn ensureUnusedCapacityBits(self: *BitWriter, n_bits: usize) !void {
		const final_bits = self.bits_written + n_bits;
		const needed_bytes = std.mem.alignForward(usize, final_bits, 8) / 8;
		if (needed_bytes > self.storage.items.len) {
			const old_len = self.storage.items.len;
			try self.storage.resize(self.allocator, needed_bytes);
			@memset(self.storage.items[old_len..], 0);
		}
	}

	/// Writes little-endian bit patches in the same LSB-first byte layout that
	/// `BitReader` expects, making encode/decode roundtrips deterministic.
	pub fn write(self: *BitWriter, n_bits: usize, bits: u64) !void {
		std.debug.assert(n_bits <= kMaxBitsPerCall);
		if (n_bits == 0) return;

		const final_bits = self.bits_written + n_bits;
		try self.ensureUnusedCapacityBits(n_bits);

		var remaining = n_bits;
		var value = bits;
		var bit_pos = self.bits_written;
		while (remaining > 0) {
			const byte_index = bit_pos / 8;
			const intra_byte = bit_pos % 8;
			const take = @min(remaining, 8 - intra_byte);
			const mask = (@as(u64, 1) << @intCast(take)) - 1;
			self.storage.items[byte_index] |= @intCast((value & mask) << @intCast(intra_byte));

			value >>= @intCast(take);
			bit_pos += take;
			remaining -= take;
		}

		self.bits_written = final_bits;
	}

	pub fn zeroPadToByte(self: *BitWriter) !void {
		const remainder = self.bits_written % 8;
		if (remainder == 0) return;
		try self.write(8 - remainder, 0);
	}
};

const testing = std.testing;

test "BitWriter zero-pads to byte boundary" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	try writer.write(3, 0b101);
	try writer.zeroPadToByte();

	try testing.expectEqual(@as(usize, 8), writer.bitsWritten());
	try testing.expectEqualSlices(u8, &[_]u8{0b00000101}, writer.bytes());
}

test "BitWriter ensureUnusedCapacityBits reserves without exposing unwritten bytes" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	try writer.ensureUnusedCapacityBits(32);
	try writer.write(4, 0b1010);
	try writer.zeroPadToByte();

	try testing.expectEqual(@as(usize, 8), writer.bitsWritten());
	try testing.expectEqualSlices(u8, &[_]u8{0b00001010}, writer.bytes());
}

test "BitWriter round-trips a short sequence through BitReader" {
	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	try writer.write(1, 1);
	try writer.write(3, 0b110);
	try writer.write(8, 0xDB);
	try writer.write(4, 0x8);
	try writer.zeroPadToByte();

	var reader = BitReader.init(writer.bytes());
	try testing.expectEqual(@as(u64, 1), reader.readBits(1));
	try testing.expectEqual(@as(u64, 0b110), reader.readBits(3));
	try testing.expectEqual(@as(u64, 0xDB), reader.readBits(8));
	try testing.expectEqual(@as(u64, 0x8), reader.readBits(4));
	try reader.jumpToByteBoundary();
	try reader.close();
}

test "BitWriter random sequence round-trips through BitReader" {
	var prng = std.Random.DefaultPrng.init(42);
	const random = prng.random();

	var patches: std.ArrayList(struct { len: usize, bits: u64 }) = .empty;
	defer patches.deinit(testing.allocator);

	var total_bits: usize = 0;
	for (0..4096) |_| {
		const len = random.intRangeAtMost(usize, 1, BitWriter.kMaxBitsPerCall);
		const mask = if (len == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(len)) - 1;
		const bits = random.int(u64) & mask;
		try patches.append(testing.allocator, .{ .len = len, .bits = bits });
		total_bits += len;
	}

	var writer = BitWriter.init(testing.allocator);
	defer writer.deinit();

	for (patches.items) |patch| {
		try writer.write(patch.len, patch.bits);
	}
	try writer.zeroPadToByte();
	try testing.expectEqual(std.mem.alignForward(usize, total_bits, 8), writer.bitsWritten());

	var reader = BitReader.init(writer.bytes());
	for (patches.items) |patch| {
		try testing.expectEqual(patch.bits, reader.readBits(patch.len));
	}
	try reader.jumpToByteBoundary();
	try reader.close();
}
