const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;

	const root_module = b.createModule(.{
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
	});

	const lib = b.addLibrary(.{
		.name = "jxlz",
		.linkage = .static,
		.root_module = root_module,
	});
	lib.linkLibC();

	const install_lib = b.addInstallArtifact(lib, .{});

	const capi_lib = b.addLibrary(.{
		.name = "jxlz_capi",
		.linkage = .static,
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/capi_root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	capi_lib.linkLibC();

	const install_capi = b.addInstallArtifact(capi_lib, .{});

	const lib_step = b.step("lib", "Build only the static library");
	lib_step.dependOn(&install_lib.step);

	const capi_step = b.step("capi", "Build the libjxl-shaped C FFI static library");
	capi_step.dependOn(&install_capi.step);

	const djxlz = b.addExecutable(.{
		.name = "djxlz",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/cli/djxlz_root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	djxlz.addIncludePath(b.path("include"));
	djxlz.addIncludePath(b.path("lib/include"));
	djxlz.addCSourceFile(.{
		.file = b.path("src/cli/djxlz.c"),
		.flags = &.{"-std=c11"},
	});
	djxlz.linkLibrary(capi_lib);
	djxlz.linkLibC();
	if (optimize == .Debug) {
		djxlz.root_module.addCMacro("JXLZ_DEBUG_BUILD", "1");
	}

	const install_djxlz = b.addInstallArtifact(djxlz, .{});
	const djxlz_step = b.step("djxlz", "Build the C CLI that dogfoods the C FFI");
	djxlz_step.dependOn(&install_djxlz.step);

	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	unit_tests.linkLibC();

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
	const capi_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/capi_root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	capi_tests.linkLibC();

	const run_capi_tests = b.addRunArtifact(capi_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_bench_tests.step);
	test_step.dependOn(&run_weighted_bench_tests.step);
	test_step.dependOn(&run_capi_tests.step);
}
