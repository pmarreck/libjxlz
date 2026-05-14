const std = @import("std");

extern fn djxlz_main(argc: c_int, argv: [*][*:0]u8) c_int;

pub fn main(init: std.process.Init) void {
	const allocator = std.heap.c_allocator;
	const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
	const argv = allocator.alloc([*:0]u8, args.len) catch std.process.exit(2);
	defer allocator.free(argv);

	for (args, 0..) |arg, i| {
		argv[i] = @constCast(arg.ptr);
	}

	const rc = djxlz_main(@intCast(argv.len), argv.ptr);
	if (rc != 0) std.process.exit(@intCast(rc));
}
