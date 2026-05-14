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
	const gif_output = b.option(bool, "gif_output", "Enable GIF output support in djxlz (default: true)") orelse true;
	const brotli_include_dir = b.graph.environ_map.get("BROTLI_INCLUDE_DIR");
	const brotli_lib_dir = b.graph.environ_map.get("BROTLI_LIB_DIR");
	const gif_include_dir = b.graph.environ_map.get("GIF_INCLUDE_DIR");
	const gif_lib_dir = b.graph.environ_map.get("GIF_LIB_DIR");

	const linkBrotliModule = struct {
		fn apply(mod: *std.Build.Module, include_dir: ?[]const u8, lib_dir: ?[]const u8) void {
			if (include_dir) |path| {
				mod.addIncludePath(.{ .cwd_relative = path });
			}
			if (lib_dir) |path| {
				mod.addLibraryPath(.{ .cwd_relative = path });
			}
			mod.linkSystemLibrary("brotlienc", .{});
			mod.linkSystemLibrary("brotlidec", .{});
			mod.linkSystemLibrary("brotlicommon", .{});
		}
	}.apply;

	const root_module = b.createModule(.{
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(root_module, brotli_include_dir, brotli_lib_dir);

	const lib = b.addLibrary(.{
		.name = "jxlz",
		.linkage = .static,
		.root_module = root_module,
	});

	const install_lib = b.addInstallArtifact(lib, .{});
	b.getInstallStep().dependOn(&install_lib.step);

	const capi_module = b.createModule(.{
		.root_source_file = b.path("src/capi_root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(capi_module, brotli_include_dir, brotli_lib_dir);

	const capi_lib = b.addLibrary(.{
		.name = "jxlz_capi",
		.linkage = .static,
		.root_module = capi_module,
	});

	const install_capi = b.addInstallArtifact(capi_lib, .{});
	b.getInstallStep().dependOn(&install_capi.step);

	const lib_step = b.step("lib", "Build only the static library");
	lib_step.dependOn(&install_lib.step);

	const capi_step = b.step("capi", "Build the libjxl-shaped C FFI static library");
	capi_step.dependOn(&install_capi.step);

	const djxlz_mod = b.createModule(.{
		.root_source_file = b.path("src/cli/djxlz_root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	djxlz_mod.addIncludePath(b.path("include"));
	djxlz_mod.addIncludePath(b.path("lib/include"));
	djxlz_mod.addCSourceFile(.{
		.file = b.path("src/cli/djxlz.c"),
		.flags = &.{"-std=c11"},
	});
	djxlz_mod.linkLibrary(capi_lib);
	linkBrotliModule(djxlz_mod, brotli_include_dir, brotli_lib_dir);
	if (gif_output) {
		djxlz_mod.addCMacro("JXLZ_HAVE_GIF_OUTPUT", "1");
		if (gif_include_dir) |path| {
			djxlz_mod.addIncludePath(.{ .cwd_relative = path });
		}
		if (gif_lib_dir) |path| {
			djxlz_mod.addLibraryPath(.{ .cwd_relative = path });
		}
		djxlz_mod.linkSystemLibrary("gif", .{});
	}
	if (optimize == .Debug) {
		djxlz_mod.addCMacro("JXLZ_DEBUG_BUILD", "1");
	}
	const djxlz = b.addExecutable(.{
		.name = "djxlz",
		.root_module = djxlz_mod,
	});

	const install_djxlz = b.addInstallArtifact(djxlz, .{});
	b.getInstallStep().dependOn(&install_djxlz.step);
	const djxlz_step = b.step("djxlz", "Build the C CLI that dogfoods the C FFI");
	djxlz_step.dependOn(&install_djxlz.step);

	const cjxlz_mod = b.createModule(.{
		.root_source_file = b.path("src/cli/cjxlz_root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	cjxlz_mod.addIncludePath(b.path("include"));
	cjxlz_mod.addIncludePath(b.path("lib/include"));
	cjxlz_mod.addCSourceFile(.{
		.file = b.path("src/cli/cjxlz.c"),
		.flags = &.{"-std=c11"},
	});
	cjxlz_mod.linkLibrary(capi_lib);
	linkBrotliModule(cjxlz_mod, brotli_include_dir, brotli_lib_dir);
	if (png_input) {
		cjxlz_mod.addCMacro("JXLZ_HAVE_PNG_INPUT", "1");
		cjxlz_mod.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
	}
	if (gif_input) {
		cjxlz_mod.addCMacro("JXLZ_HAVE_GIF_INPUT", "1");
		if (gif_include_dir) |path| {
			cjxlz_mod.addIncludePath(.{ .cwd_relative = path });
		}
		if (gif_lib_dir) |path| {
			cjxlz_mod.addLibraryPath(.{ .cwd_relative = path });
		}
		cjxlz_mod.linkSystemLibrary("gif", .{});
	}
	if (target.result.os.tag != .windows and png_input) {
		cjxlz_mod.linkSystemLibrary("m", .{});
	}
	if (optimize == .Debug) {
		cjxlz_mod.addCMacro("JXLZ_DEBUG_BUILD", "1");
	}
	const cjxlz = b.addExecutable(.{
		.name = "cjxlz",
		.root_module = cjxlz_mod,
	});

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

	const unit_tests_mod = b.createModule(.{
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(unit_tests_mod, brotli_include_dir, brotli_lib_dir);
	const unit_tests = b.addTest(.{
		.root_module = unit_tests_mod,
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
	const capi_tests_mod = b.createModule(.{
		.root_source_file = b.path("src/capi_root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(capi_tests_mod, brotli_include_dir, brotli_lib_dir);
	const capi_tests = b.addTest(.{
		.root_module = capi_tests_mod,
	});

	const run_capi_tests = b.addRunArtifact(capi_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_bench_tests.step);
	test_step.dependOn(&run_weighted_bench_tests.step);
	test_step.dependOn(&run_encode_prep_bench_tests.step);
	test_step.dependOn(&run_encode_codestream_bench_tests.step);
	test_step.dependOn(&run_capi_tests.step);
}
