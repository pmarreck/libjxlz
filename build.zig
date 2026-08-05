const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(
		std.builtin.OptimizeMode,
		"optimize",
		"Optimization mode (default: ReleaseSafe)",
	) orelse .ReleaseSafe;
	// Single-test isolation. The compiled test binary rejects `--test-filter`
	// because it is a build-system flag, so without this option a single test
	// cannot be run alone -- which is the decisive experiment when a failure is
	// suspected of cross-test contamination.
	const test_filter = b.option([]const u8, "test-filter", "Only run tests whose fully-qualified name contains this substring");
	const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
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

	// Static libraries must add brotli's headers for `@cImport` but must NOT link
	// its shared objects. Zig materializes linked shared libraries as members of
	// the resulting archive, so consumers of `libjxlz_capi.a` then hit
	// "archive member ... is neither ET_REL nor LLVM bitcode" (seen on the
	// aarch64 CI runners) or an outright architecture mismatch when
	// cross-compiling with a host-specific BROTLI_LIB_DIR. Every executable and
	// test links brotli itself, and the C smoke tests already pass
	// `pkg-config --libs`, so nothing downstream loses the symbols.
	const addBrotliIncludes = struct {
		fn apply(mod: *std.Build.Module, include_dir: ?[]const u8) void {
			if (include_dir) |path| {
				mod.addIncludePath(.{ .cwd_relative = path });
			}
		}
	}.apply;

	const root_module = b.createModule(.{
		.root_source_file = b.path("src/root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	addBrotliIncludes(root_module, brotli_include_dir);

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
	addBrotliIncludes(capi_module, brotli_include_dir);

	const capi_lib = b.addLibrary(.{
		.name = "jxlz_capi",
		.linkage = .static,
		.root_module = capi_module,
	});

	// External C consumers link this archive with the system linker (clang), not
	// `zig cc`, so Zig's compiler_rt is never pulled in on their behalf. Optimize
	// modes that keep safety on emit `__zig_probe_stack` calls into the archive,
	// which then fail to resolve at link time. Bundling compiler_rt keeps the
	// published C FFI linkable in every optimize mode.
	capi_lib.bundle_compiler_rt = true;

	const install_capi = b.addInstallArtifact(capi_lib, .{});
	b.getInstallStep().dependOn(&install_capi.step);

	// Merge generated and source public headers into one consumer include root.
	// C callers should never need repository-relative `-Iinclude -Ilib/include`.
	const install_generated_headers = b.addInstallDirectory(.{
		.source_dir = b.path("include"),
		.install_dir = .header,
		.install_subdir = "",
	});
	const install_public_headers = b.addInstallDirectory(.{
		.source_dir = b.path("lib/include"),
		.install_dir = .header,
		.install_subdir = "",
	});
	b.getInstallStep().dependOn(&install_generated_headers.step);
	b.getInstallStep().dependOn(&install_public_headers.step);

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

	// Unified subcommand front end. It compiles the two single-purpose CLI
	// translation units alongside its own dispatcher and calls their
	// `djxlz_main`/`cjxlz_main` entry points, so decode and encode have exactly
	// one implementation rather than a fork. Every other symbol in those files
	// is already `static`, so there is nothing to collide.
	const jxlz_mod = b.createModule(.{
		.root_source_file = b.path("src/cli/jxlz_root.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	jxlz_mod.addIncludePath(b.path("include"));
	jxlz_mod.addIncludePath(b.path("lib/include"));
	jxlz_mod.addCSourceFiles(.{
		.files = &.{ "src/cli/jxlz.c", "src/cli/djxlz.c", "src/cli/cjxlz.c" },
		.flags = &.{"-std=c11"},
	});
	jxlz_mod.linkLibrary(capi_lib);
	linkBrotliModule(jxlz_mod, brotli_include_dir, brotli_lib_dir);
	if (png_input) {
		jxlz_mod.addCMacro("JXLZ_HAVE_PNG_INPUT", "1");
		jxlz_mod.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
	}
	if (gif_input) {
		jxlz_mod.addCMacro("JXLZ_HAVE_GIF_INPUT", "1");
	}
	if (gif_output) {
		jxlz_mod.addCMacro("JXLZ_HAVE_GIF_OUTPUT", "1");
	}
	if (gif_input or gif_output) {
		if (gif_include_dir) |path| {
			jxlz_mod.addIncludePath(.{ .cwd_relative = path });
		}
		if (gif_lib_dir) |path| {
			jxlz_mod.addLibraryPath(.{ .cwd_relative = path });
		}
		jxlz_mod.linkSystemLibrary("gif", .{});
	}
	if (target.result.os.tag != .windows and png_input) {
		jxlz_mod.linkSystemLibrary("m", .{});
	}
	if (optimize == .Debug) {
		jxlz_mod.addCMacro("JXLZ_DEBUG_BUILD", "1");
	}
	const jxlz = b.addExecutable(.{
		.name = "jxlz",
		.root_module = jxlz_mod,
	});

	const install_jxlz = b.addInstallArtifact(jxlz, .{});
	b.getInstallStep().dependOn(&install_jxlz.step);
	const jxlz_step = b.step("jxlz", "Build the unified subcommand CLI");
	jxlz_step.dependOn(&install_jxlz.step);

	// Benchmark targets reach the codec through the same modules as the library,
	// so they need Brotli wiring too. Zig only analyses a function body when it
	// is referenced, which previously hid this: nothing on the benchmark paths
	// called into `brotli.zig`, so its `@cImport` was never forced. Validating
	// `brob` payloads during container parsing made the call reachable and the
	// missing include path surfaced as a `brotli/decode.h` not-found error.
	const encode_prep_bench_mod = b.createModule(.{
		.root_source_file = b.path("bench_modular_encode_prep.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(encode_prep_bench_mod, brotli_include_dir, brotli_lib_dir);
	const encode_prep_bench = b.addExecutable(.{
		.name = "bench_modular_encode_prep",
		.root_module = encode_prep_bench_mod,
	});
	const install_encode_prep_bench = b.addInstallArtifact(encode_prep_bench, .{});
	b.getInstallStep().dependOn(&install_encode_prep_bench.step);
	const encode_prep_bench_step = b.step("encode-prep-bench", "Build the modular encode prep benchmark");
	encode_prep_bench_step.dependOn(&install_encode_prep_bench.step);

	const encode_codestream_bench_mod = b.createModule(.{
		.root_source_file = b.path("bench_modular_encode_codestream.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(encode_codestream_bench_mod, brotli_include_dir, brotli_lib_dir);
	const encode_codestream_bench = b.addExecutable(.{
		.name = "bench_modular_encode_codestream",
		.root_module = encode_codestream_bench_mod,
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
		.filters = test_filters,
	});

	const run_unit_tests = b.addRunArtifact(unit_tests);

	const bench_tests_mod = b.createModule(.{
		.root_source_file = b.path("bench_decode_runtime.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(bench_tests_mod, brotli_include_dir, brotli_lib_dir);
	const bench_tests = b.addTest(.{
		.root_module = bench_tests_mod,
		.filters = test_filters,
	});

	const run_bench_tests = b.addRunArtifact(bench_tests);
	const weighted_bench_tests_mod = b.createModule(.{
		.root_source_file = b.path("bench_weighted_predict.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(weighted_bench_tests_mod, brotli_include_dir, brotli_lib_dir);
	const weighted_bench_tests = b.addTest(.{
		.root_module = weighted_bench_tests_mod,
		.filters = test_filters,
	});

	const run_weighted_bench_tests = b.addRunArtifact(weighted_bench_tests);
	const encode_prep_bench_tests_mod = b.createModule(.{
		.root_source_file = b.path("bench_modular_encode_prep.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(encode_prep_bench_tests_mod, brotli_include_dir, brotli_lib_dir);
	const encode_prep_bench_tests = b.addTest(.{
		.root_module = encode_prep_bench_tests_mod,
		.filters = test_filters,
	});

	const run_encode_prep_bench_tests = b.addRunArtifact(encode_prep_bench_tests);
	const encode_codestream_bench_tests_mod = b.createModule(.{
		.root_source_file = b.path("bench_modular_encode_codestream.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	linkBrotliModule(encode_codestream_bench_tests_mod, brotli_include_dir, brotli_lib_dir);
	const encode_codestream_bench_tests = b.addTest(.{
		.root_module = encode_codestream_bench_tests_mod,
		.filters = test_filters,
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
		.filters = test_filters,
	});

	const run_capi_tests = b.addRunArtifact(capi_tests);
	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit_tests.step);
	test_step.dependOn(&run_bench_tests.step);
	test_step.dependOn(&run_weighted_bench_tests.step);
	test_step.dependOn(&run_encode_prep_bench_tests.step);
	test_step.dependOn(&run_encode_codestream_bench_tests.step);
	test_step.dependOn(&run_capi_tests.step);

	// `test-compile` builds every test binary but does not run them. The
	// Nix flake check uses this on Linux so it can invoke each binary via
	// Nix's actual dynamic linker — Zig 0.16 bakes an FHS loader path
	// (/lib64/ld-linux-x86-64.so.2 or /lib/ld-linux-aarch64.so.1) that
	// doesn't exist inside the Nix build sandbox, which is what produced
	// the `FileNotFound` failure when `zig build test` tried to spawn the
	// compiled test binaries.
	const test_compile_step = b.step("test-compile", "Compile test binaries without running them");
	test_compile_step.dependOn(&b.addInstallArtifact(unit_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "unit_tests",
	}).step);
	test_compile_step.dependOn(&b.addInstallArtifact(bench_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "bench_tests",
	}).step);
	test_compile_step.dependOn(&b.addInstallArtifact(weighted_bench_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "weighted_bench_tests",
	}).step);
	test_compile_step.dependOn(&b.addInstallArtifact(encode_prep_bench_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "encode_prep_bench_tests",
	}).step);
	test_compile_step.dependOn(&b.addInstallArtifact(encode_codestream_bench_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "encode_codestream_bench_tests",
	}).step);
	test_compile_step.dependOn(&b.addInstallArtifact(capi_tests, .{
		.dest_dir = .{ .override = .{ .custom = "test-bins" } },
		.dest_sub_path = "capi_tests",
	}).step);
}
