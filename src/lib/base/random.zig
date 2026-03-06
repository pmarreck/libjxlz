const std = @import("std");

/// Xorshift128+ RNG, matching the C++ jxl::Rng implementation.
pub const Rng = struct {
	s: [2]u64,

	/// Initialize with the same constants as C++.
	pub fn init(seed: u64) Rng {
		return .{ .s = .{
			0x94D049BB133111EB,
			0xBF58476D1CE4E5B9 +% seed,
		} };
	}

	/// Xorshift128+ core — returns next pseudo-random u64.
	pub fn next(self: *Rng) u64 {
		var s1 = self.s[0];
		const s0 = self.s[1];
		const bits = s1 +% s0;
		self.s[0] = s0;
		s1 ^= s1 << 23;
		s1 ^= s0 ^ (s1 >> 18) ^ (s0 >> 5);
		self.s[1] = s1;
		return bits;
	}

	/// Uniformly distributed i64 in [begin, end).
	pub fn uniformI(self: *Rng, begin: i64, end: i64) i64 {
		std.debug.assert(end > begin);
		const range: u64 = @intCast(end - begin);
		return @as(i64, @intCast(self.next() % range)) + begin;
	}

	/// Uniformly distributed u64 in [begin, end).
	pub fn uniformU(self: *Rng, begin: u64, end: u64) u64 {
		std.debug.assert(end > begin);
		return self.next() % (end - begin) + begin;
	}

	/// Uniformly distributed f32 in [begin, end). 23 bits of randomness.
	pub fn uniformF(self: *Rng, begin: f32, end: f32) f32 {
		// Bits of a random [1, 2) float.
		const u: u32 = @as(u32, @truncate(self.next() >> (64 - 23))) | 0x3F800000;
		const f: f32 = @bitCast(u);
		return (end - begin) * (f - 1.0) + begin;
	}

	/// Bernoulli trial with probability p.
	pub fn bernoulli(self: *Rng, p: f32) bool {
		return self.uniformF(0, 1) < p;
	}

	/// Fisher-Yates shuffle.
	pub fn shuffle(self: *Rng, comptime T: type, items: []T) void {
		if (items.len <= 1) return;
		for (0..items.len - 1) |i| {
			const a = self.uniformU(i, items.len);
			const tmp = items[a];
			items[a] = items[i];
			items[i] = tmp;
		}
	}
};

test "deterministic output for same seed" {
	var rng1 = Rng.init(42);
	var rng2 = Rng.init(42);
	for (0..10) |_| {
		try std.testing.expectEqual(rng1.next(), rng2.next());
	}
}

test "different seeds produce different output" {
	var rng1 = Rng.init(0);
	var rng2 = Rng.init(1);
	// At least one of the first 10 values should differ
	var any_differ = false;
	for (0..10) |_| {
		if (rng1.next() != rng2.next()) any_differ = true;
	}
	try std.testing.expect(any_differ);
}

test "uniformI stays in range" {
	var rng = Rng.init(123);
	for (0..1000) |_| {
		const v = rng.uniformI(-10, 10);
		try std.testing.expect(v >= -10);
		try std.testing.expect(v < 10);
	}
}

test "uniformU stays in range" {
	var rng = Rng.init(456);
	for (0..1000) |_| {
		const v = rng.uniformU(5, 100);
		try std.testing.expect(v >= 5);
		try std.testing.expect(v < 100);
	}
}

test "uniformF stays in range" {
	var rng = Rng.init(789);
	for (0..1000) |_| {
		const v = rng.uniformF(0.0, 1.0);
		try std.testing.expect(v >= 0.0);
		try std.testing.expect(v < 1.0);
	}
}

test "shuffle preserves elements" {
	var rng = Rng.init(42);
	var items = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
	rng.shuffle(u32, &items);

	// Sort and verify all elements are preserved
	std.mem.sort(u32, &items, {}, std.sort.asc(u32));
	for (items, 1..) |v, i| {
		try std.testing.expectEqual(@as(u32, @intCast(i)), v);
	}
}
