const std = @import("std");
const JxlError = @import("status.zig").JxlError;
const builtin = @import("builtin");

const have_c_brotli = true;
const c = @cImport({
	@cInclude("brotli/decode.h");
	@cInclude("brotli/encode.h");
});

/// Compresses metadata payloads with the same low Brotli effort upstream uses
/// for `brob` boxes so encoded metadata stays compact without becoming a hot path.
pub fn compress(allocator: std.mem.Allocator, input: []const u8) JxlError![]u8 {
	return compressWithC(allocator, input);
}

fn compressWithC(allocator: std.mem.Allocator, input: []const u8) JxlError![]u8 {
	const max_size = c.BrotliEncoderMaxCompressedSize(input.len);
	var encoded = try allocator.alloc(u8, max_size);
	errdefer allocator.free(encoded);

	var encoded_size = max_size;
	const ok = c.BrotliEncoderCompress(
		4,
		c.BROTLI_DEFAULT_WINDOW,
		c.BROTLI_MODE_GENERIC,
		input.len,
		if (input.len == 0) null else input.ptr,
		&encoded_size,
		encoded.ptr,
	);
	if (ok == 0) return error.GenericError;

	const trimmed = try allocator.alloc(u8, encoded_size);
	@memcpy(trimmed, encoded[0..encoded_size]);
	allocator.free(encoded);
	return trimmed;
}

/// Decompresses a Brotli payload of unknown final size by streaming into a
/// growable buffer, which is exactly what `brob` metadata boxes require.
pub fn decompress(allocator: std.mem.Allocator, compressed: []const u8) JxlError![]u8 {
	return decompressBounded(allocator, compressed, std.math.maxInt(usize));
}

/// Rejects output beyond the caller's byte limit before growing the result.
pub fn decompressBounded(allocator: std.mem.Allocator, compressed: []const u8, limit: usize) JxlError![]u8 {
	return decompressWithMemory(allocator, compressed, limit, null, null, null);
}

fn decompressWithMemory(
	allocator: std.mem.Allocator,
	compressed: []const u8,
	limit: usize,
	allocate: c.brotli_alloc_func,
	free: c.brotli_free_func,
	opaque_pointer: ?*anyopaque,
) JxlError![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	errdefer out.deinit(allocator);

	const state = c.BrotliDecoderCreateInstance(allocate, free, opaque_pointer) orelse return error.OutOfMemory;
	defer c.BrotliDecoderDestroyInstance(state);

	var available_in: usize = compressed.len;
	var next_in: [*c]const u8 = if (compressed.len == 0) null else compressed.ptr;

	while (true) {
		var chunk: [4096]u8 = undefined;
		var available_out: usize = chunk.len;
		var next_out: [*c]u8 = chunk[0..].ptr;
		const result = c.BrotliDecoderDecompressStream(
			state,
			&available_in,
			&next_in,
			&available_out,
			&next_out,
			null,
		);
		if (result == c.BROTLI_DECODER_RESULT_ERROR) return decoderError(c.BrotliDecoderGetErrorCode(state));
		const produced = chunk.len - available_out;
		if (produced > limit - out.items.len) return error.GenericError;
		if (produced != 0) try out.appendSlice(allocator, chunk[0..produced]);

		switch (result) {
			c.BROTLI_DECODER_RESULT_SUCCESS => {
				if (available_in != 0) return error.GenericError;
				return out.toOwnedSlice(allocator);
			},
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT => continue,
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT => return error.GenericError,
			else => return error.BrotliDecoderFailure,
		}
	}
}

const testing = std.testing;

fn decoderError(code: c.BrotliDecoderErrorCode) JxlError {
	return switch (code) {
		c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES,
		c.BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS,
		c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP,
		c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1,
		c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2,
		c.BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES,
		=> error.OutOfMemory,
		c.BROTLI_DECODER_ERROR_FORMAT_DISTANCE...c.BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE => error.GenericError,
		else => error.BrotliDecoderFailure,
	};
}

test "Brotli errors distinguish allocation format and operational failures" {
	// Numeric codes from Brotli 1.2 decode.h, including reserved holes and statuses.
	const expected = [_]JxlError{
		error.BrotliDecoderFailure, // -31: unreachable
		error.OutOfMemory, // -30: block type trees
		error.BrotliDecoderFailure, error.BrotliDecoderFailure,
		error.OutOfMemory, error.OutOfMemory, error.OutOfMemory, // -27..-25
		error.BrotliDecoderFailure, error.BrotliDecoderFailure,
		error.OutOfMemory, error.OutOfMemory, // -22..-21
		error.BrotliDecoderFailure, error.BrotliDecoderFailure, error.BrotliDecoderFailure, error.BrotliDecoderFailure,
	} ++ ([_]JxlError{error.GenericError} ** 16) ++ ([_]JxlError{error.BrotliDecoderFailure} ** 4);
	for (expected, 0..) |err, index| {
		try testing.expectEqual(err, decoderError(@as(c_int, @intCast(index)) - 31));
	}
}

test "windows targets keep the Brotli backend available" {
	if (builtin.target.os.tag != .windows) return;
	try testing.expect(have_c_brotli);
}

test "Brotli native allocation failures propagate and release prior allocations" {
	const NativeMemory = struct {
		extern "c" fn malloc(usize) ?*anyopaque;
		extern "c" fn free(?*anyopaque) void;
		attempts: usize = 0,
		fail_at: usize,
		live: usize = 0,

		fn allocate(context: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
			const self: *@This() = @ptrCast(@alignCast(context.?));
			const attempt = self.attempts;
			self.attempts += 1;
			if (attempt == self.fail_at) return null;
			const ptr = malloc(size) orelse return null;
			self.live += 1;
			return ptr;
		}

		fn release(context: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
			const self: *@This() = @ptrCast(@alignCast(context.?));
			if (ptr != null) self.live -= 1;
			free(ptr);
		}
	};
	const input = "native allocation control " ** 1024;
	const compressed = try compress(testing.allocator, input);
	defer testing.allocator.free(compressed);
	var fail_at: usize = 0;
	while (fail_at < 64) : (fail_at += 1) {
		var memory: NativeMemory = .{ .fail_at = fail_at };
		const result = decompressWithMemory(testing.allocator, compressed, input.len, NativeMemory.allocate, NativeMemory.release, &memory);
		if (result) |decoded| {
			defer testing.allocator.free(decoded);
			try testing.expectEqualStrings(input, decoded);
			try testing.expectEqual(@as(usize, 0), memory.live);
			try testing.expect(fail_at > 1);
			return;
		} else |err| {
			try testing.expectEqual(@as(usize, 0), memory.live);
			try testing.expectEqual(error.OutOfMemory, err);
		}
	}
	return error.TestUnexpectedResult;
}
