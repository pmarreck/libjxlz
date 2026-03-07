const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	const root_module = b.createModule(.{
		.root_source_file = b.path("src/lib/root.zig"),
		.target = target,
		.optimize = optimize,
	});

	const lib = b.addLibrary(.{
		.name = "jxlz",
		.linkage = .static,
		.root_module = root_module,
	});

	b.installArtifact(lib);

	const lib_step = b.step("lib", "Build only the static library");
	lib_step.dependOn(&lib.step);

	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/lib/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_unit_tests = b.addRunArtifact(unit_tests);

	const bench_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_decode_runtime.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_bench_tests = b.addRunArtifact(bench_tests);
	const weighted_bench_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_weighted_predict.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_weighted_bench_tests = b.addRunArtifact(weighted_bench_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_bench_tests.step);
	test_step.dependOn(&run_weighted_bench_tests.step);
}
