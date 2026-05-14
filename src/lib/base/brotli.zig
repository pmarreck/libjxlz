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
	return decompressWithC(allocator, compressed);
}

fn decompressWithC(allocator: std.mem.Allocator, compressed: []const u8) JxlError![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	errdefer out.deinit(allocator);

	const state = c.BrotliDecoderCreateInstance(null, null, null) orelse return error.OutOfMemory;
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
		const produced = chunk.len - available_out;
		if (produced != 0) try out.appendSlice(allocator, chunk[0..produced]);

		switch (result) {
			c.BROTLI_DECODER_RESULT_SUCCESS => {
				if (available_in != 0) return error.GenericError;
				return out.toOwnedSlice(allocator);
			},
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT => continue,
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT => return error.GenericError,
			c.BROTLI_DECODER_RESULT_ERROR => return error.GenericError,
			else => return error.GenericError,
		}
	}
}

const testing = std.testing;

test "windows targets keep the Brotli backend available" {
	if (builtin.target.os.tag != .windows) return;
	try testing.expect(have_c_brotli);
}
