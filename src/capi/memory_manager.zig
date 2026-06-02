const std = @import("std");

pub const jpegxl_alloc_func = *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque;
pub const jpegxl_free_func = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const JxlMemoryManager = extern struct {
	@"opaque": ?*anyopaque,
	alloc: ?jpegxl_alloc_func,
	free: ?jpegxl_free_func,
};

/// Validates the optional C memory-manager pair so all public constructors and
/// buffer-returning APIs share the same ownership contract.
pub fn validate(mm: ?*const JxlMemoryManager) bool {
	if (mm) |manager| {
		if ((manager.alloc == null) != (manager.free == null)) return false;
	}
	return true;
}

/// Allocates and initializes a C API implementation object, using a custom
/// memory manager only when both alloc/free callbacks are present.
pub fn createValue(comptime T: type, mm: ?*const JxlMemoryManager, value: T) ?*T {
	if (!validate(mm)) return null;
	if (mm) |manager| {
		if (manager.alloc != null) {
			const raw = manager.alloc.?(manager.@"opaque", @sizeOf(T)) orelse return null;
			const ptr: *T = @ptrCast(@alignCast(raw));
			ptr.* = value;
			return ptr;
		}
	}

	const ptr = std.heap.c_allocator.create(T) catch return null;
	ptr.* = value;
	return ptr;
}

/// Frees an implementation object through the same allocator family that
/// created it, after the caller has released object-specific owned fields.
pub fn destroyValue(comptime T: type, ptr: *T, mm: ?JxlMemoryManager) void {
	if (mm) |manager| {
		if (manager.alloc != null and manager.free != null) {
			manager.free.?(manager.@"opaque", ptr);
			return;
		}
	}
	std.heap.c_allocator.destroy(ptr);
}

/// Copies Zig-owned bytes into caller-owned storage using the optional C memory
/// manager, bridging pure-Zig codec results to stable FFI ownership semantics.
pub fn exportOwnedBytes(
	mm: ?*const JxlMemoryManager,
	bytes: []const u8,
	out_ptr: *?[*]u8,
	out_size: *usize,
) bool {
	if (!validate(mm)) return false;

	if (bytes.len == 0) {
		out_ptr.* = null;
		out_size.* = 0;
		return true;
	}

	if (mm) |manager| {
		if (manager.alloc != null) {
			const raw = manager.alloc.?(manager.@"opaque", bytes.len) orelse return false;
			const dst: [*]u8 = @ptrCast(raw);
			@memcpy(dst[0..bytes.len], bytes);
			out_ptr.* = dst;
			out_size.* = bytes.len;
			return true;
		}
	}

	const owned = std.heap.c_allocator.alloc(u8, bytes.len) catch return false;
	@memcpy(owned, bytes);
	out_ptr.* = owned.ptr;
	out_size.* = owned.len;
	return true;
}

const TestState = struct {
	alloc_count: usize = 0,
	free_count: usize = 0,
};

fn testAlloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
	const state: *TestState = @ptrCast(@alignCast(ctx.?));
	state.alloc_count += 1;
	return std.c.malloc(size);
}

fn testFree(ctx: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
	const state: *TestState = @ptrCast(@alignCast(ctx.?));
	state.free_count += 1;
	std.c.free(ptr);
}

test "validate rejects half-specified memory managers" {
	try std.testing.expect(validate(null));
	var good = JxlMemoryManager{ .@"opaque" = null, .alloc = testAlloc, .free = testFree };
	try std.testing.expect(validate(&good));
	var missing_free = JxlMemoryManager{ .@"opaque" = null, .alloc = testAlloc, .free = null };
	try std.testing.expect(!validate(&missing_free));
	var missing_alloc = JxlMemoryManager{ .@"opaque" = null, .alloc = null, .free = testFree };
	try std.testing.expect(!validate(&missing_alloc));
}

test "exportOwnedBytes copies through custom allocator" {
	var state = TestState{};
	var mm = JxlMemoryManager{ .@"opaque" = &state, .alloc = testAlloc, .free = testFree };
	var out: ?[*]u8 = null;
	var size: usize = 0;
	try std.testing.expect(exportOwnedBytes(&mm, &.{ 1, 2, 3 }, &out, &size));
	try std.testing.expectEqual(@as(usize, 1), state.alloc_count);
	try std.testing.expectEqual(@as(usize, 3), size);
	try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, out.?[0..size]);
	mm.free.?(mm.@"opaque", out.?);
	try std.testing.expectEqual(@as(usize, 1), state.free_count);
}
