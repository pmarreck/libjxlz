const std = @import("std");

extern fn cjxlz_main(argc: c_int, argv: [*][*:0]u8) c_int;

pub fn main() void {
	const allocator = std.heap.c_allocator;
	const args = std.process.argsAlloc(allocator) catch std.process.exit(2);
	defer std.process.argsFree(allocator, args);
	const argv = allocator.alloc([*:0]u8, args.len) catch std.process.exit(2);
	defer allocator.free(argv);

	for (args, 0..) |arg, i| {
		argv[i] = arg.ptr;
	}

	const rc = cjxlz_main(@intCast(argv.len), argv.ptr);
	if (rc != 0) std.process.exit(@intCast(rc));
}
