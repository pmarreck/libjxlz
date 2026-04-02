const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseFast)",
	) orelse .ReleaseFast;
	const png_input = b.option(bool, "png_input", "Enable PNG input support in cjxlz (default: true)") orelse true;
	const gif_input = b.option(bool, "gif_input", "Enable GIF input support in cjxlz (default: true)") orelse true;
	const gif_include_dir = std.process.getEnvVarOwned(b.allocator, "GIF_INCLUDE_DIR") catch null;
	const gif_lib_dir = std.process.getEnvVarOwned(b.allocator, "GIF_LIB_DIR") catch null;
	defer if (gif_include_dir) |path| b.allocator.free(path);
	defer if (gif_lib_dir) |path| b.allocator.free(path);

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
	b.getInstallStep().dependOn(&install_lib.step);

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
	b.getInstallStep().dependOn(&install_capi.step);

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
	b.getInstallStep().dependOn(&install_djxlz.step);
	const djxlz_step = b.step("djxlz", "Build the C CLI that dogfoods the C FFI");
	djxlz_step.dependOn(&install_djxlz.step);

	const cjxlz = b.addExecutable(.{
		.name = "cjxlz",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/cli/cjxlz_root.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	cjxlz.addIncludePath(b.path("include"));
	cjxlz.addIncludePath(b.path("lib/include"));
	cjxlz.addCSourceFile(.{
		.file = b.path("src/cli/cjxlz.c"),
		.flags = &.{"-std=c11"},
	});
	cjxlz.linkLibrary(capi_lib);
	cjxlz.linkLibC();
	if (png_input) {
		cjxlz.root_module.addCMacro("JXLZ_HAVE_PNG_INPUT", "1");
		cjxlz.linkSystemLibrary2("libpng", .{ .use_pkg_config = .force });
	}
	if (gif_input) {
		cjxlz.root_module.addCMacro("JXLZ_HAVE_GIF_INPUT", "1");
		if (gif_include_dir) |path| {
			cjxlz.addIncludePath(.{ .cwd_relative = path });
		}
		if (gif_lib_dir) |path| {
			cjxlz.root_module.addLibraryPath(.{ .cwd_relative = path });
		}
		cjxlz.linkSystemLibrary("gif");
	}
	if (target.result.os.tag != .windows and png_input) {
		cjxlz.linkSystemLibrary("m");
	}
	if (optimize == .Debug) {
		cjxlz.root_module.addCMacro("JXLZ_DEBUG_BUILD", "1");
	}

	const install_cjxlz = b.addInstallArtifact(cjxlz, .{});
	b.getInstallStep().dependOn(&install_cjxlz.step);
	const cjxlz_step = b.step("cjxlz", "Build the C encoder CLI that dogfoods the C FFI");
	cjxlz_step.dependOn(&install_cjxlz.step);

	const encode_prep_bench = b.addExecutable(.{
		.name = "bench_modular_encode_prep",
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_modular_encode_prep.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	const install_encode_prep_bench = b.addInstallArtifact(encode_prep_bench, .{});
	b.getInstallStep().dependOn(&install_encode_prep_bench.step);
	const encode_prep_bench_step = b.step("encode-prep-bench", "Build the modular encode prep benchmark");
	encode_prep_bench_step.dependOn(&install_encode_prep_bench.step);

	const encode_codestream_bench = b.addExecutable(.{
		.name = "bench_modular_encode_codestream",
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_modular_encode_codestream.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	const install_encode_codestream_bench = b.addInstallArtifact(encode_codestream_bench, .{});
	b.getInstallStep().dependOn(&install_encode_codestream_bench.step);
	const encode_codestream_bench_step = b.step("encode-codestream-bench", "Build the modular encode codestream benchmark");
	encode_codestream_bench_step.dependOn(&install_encode_codestream_bench.step);

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
	const encode_prep_bench_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_modular_encode_prep.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_encode_prep_bench_tests = b.addRunArtifact(encode_prep_bench_tests);
	const encode_codestream_bench_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("bench_modular_encode_codestream.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});

	const run_encode_codestream_bench_tests = b.addRunArtifact(encode_codestream_bench_tests);
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
	test_step.dependOn(&run_encode_prep_bench_tests.step);
	test_step.dependOn(&run_encode_codestream_bench_tests.step);
	test_step.dependOn(&run_capi_tests.step);
}
