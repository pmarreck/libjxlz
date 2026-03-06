# Phase 1: Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Set up Zig build infrastructure and port the `lib/jxl/base/` foundation layer — the bottom of the dependency tree that everything else builds on.

**Architecture:** Pure Zig library with `std.testing` tests. No I/O, no FFI yet — just the core types and utilities. Every C++ base module maps to a Zig source file under `src/lib/base/`.

**Tech Stack:** Zig 0.15.x, Nix flake (Garnix CI), Bash scripts for `./build` and `./test`

**Reference C++ files:** `lib/jxl/base/` (~2,900 lines across 24 headers)

---

### Task 1: Build Infrastructure — `build.zig`

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`

**Step 1: Write `build.zig.zon`**

```zig
.{
    .name = .libjxlz,
    .version = "0.1.0",
    .fingerprint = 0xDEADBEEF,
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 2: Write `build.zig`**

Minimal build that creates a static library from `src/lib/root.zig` and a test step. Uses ReleaseFast by default per AGENTS.md.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const lib = b.addLibrary(.{
        .name = "jxlz",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

**Step 3: Create minimal root module**

Create `src/lib/root.zig`:
```zig
pub const base = struct {
    pub const status = @import("base/status.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
```

Create `src/lib/base/status.zig` as a placeholder:
```zig
pub const StatusCode = enum(i32) {
    not_enough_bytes = -1,
    ok = 0,
    generic_error = 1,
    unsupported = 2,
};

test "StatusCode values" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(i32, 0), @intFromEnum(StatusCode.ok));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(StatusCode.generic_error));
}
```

**Step 4: Verify build and test**

Run: `zig build test -Doptimize=Debug`
Expected: PASS

**Step 5: Commit**

```
feat: initial build.zig and status.zig placeholder
```

---

### Task 2: `./build` and `./test` Bash Scripts

**Files:**
- Create: `build` (executable)
- Create: `test` (executable)

**Step 1: Write `./build`**

```bash
#!/usr/bin/env bash
set -u

MODE=""
for arg in "$@"; do
	case "$arg" in
		--test) MODE="test" ;;
		--debug) MODE="debug" ;;
	esac
done

case "$MODE" in
	test)
		exec nix develop -c zig build test -Doptimize=Debug
		;;
	debug)
		exec nix develop -c zig build -Doptimize=Debug
		;;
	*)
		exec nix develop -c zig build -Doptimize=ReleaseFast
		;;
esac
```

**Step 2: Write `./test`**

```bash
#!/usr/bin/env bash
set -u

ERRORS=0

echo "=== Zig unit tests ==="
if ! nix develop -c zig build test -Doptimize=Debug 2>&1; then
	ERRORS=$((ERRORS + 1))
fi

if [ -d tests/cli ]; then
	echo "=== CLI tests ==="
	for t in tests/cli/*.sh; do
		if ! bash "$t"; then
			ERRORS=$((ERRORS + 1))
		fi
	done
fi

if [ "$ERRORS" -gt 0 ]; then
	echo "FAILED: $ERRORS test suite(s) failed"
fi
exit "$ERRORS"
```

**Step 3: Make executable and verify**

Run: `chmod +x build test && ./test`
Expected: Zig unit tests pass

**Step 4: Commit**

```
feat: add build and test scripts
```

---

### Task 3: Update `flake.nix` for Zig

**Files:**
- Modify: `flake.nix`

**Step 1: Add Zig + hyperfine to flake.nix**

The flake should keep the existing C++ dev dependencies (for building the original to benchmark against) AND add Zig:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Zig (new)
            zig
            # Benchmarking
            hyperfine
            # Original C++ build deps (keep for benchmarks)
            clang
            cmake
            pkg-config
            gtest
            ninja
            libpng
            giflib
            lcms2
            brotli
          ];
          shellHook = ''
            export CC=clang
            export CXX=clang++
          '';
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "libjxlz";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          buildPhase = ''
            export HOME=$TMPDIR
            zig build -Doptimize=ReleaseFast
          '';
          installPhase = ''
            mkdir -p $out/lib $out/include
            cp zig-out/lib/* $out/lib/ 2>/dev/null || true
          '';
        };

        checks.${system} = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "libjxlz-test";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build test -Doptimize=Debug || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };
      }
    );
}
```

**Step 2: Verify**

Run: `nix develop -c zig version`
Expected: prints Zig 0.15.x

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: tests pass

**Step 3: Commit**

```
feat: update flake.nix with Zig, hyperfine, and Garnix checks
```

---

### Task 4: Port `status.zig` — Status and StatusOr types

**Files:**
- Modify: `src/lib/base/status.zig`

**C++ source:** `lib/jxl/base/status.h` (388 lines)

This is the error handling foundation. The C++ uses a `Status` class (wrapper around `StatusCode` enum) and `StatusOr<T>` (like Rust's `Result<T, Status>`). In Zig, this maps naturally to error unions.

**Step 1: Write failing test**

```zig
const std = @import("std");
const testing = std.testing;
const status = @import("base/status.zig");

test "StatusCode enum values match C++" {
    try testing.expectEqual(@as(i32, -1), @intFromEnum(status.StatusCode.not_enough_bytes));
    try testing.expectEqual(@as(i32, 0), @intFromEnum(status.StatusCode.ok));
    try testing.expectEqual(@as(i32, 1), @intFromEnum(status.StatusCode.generic_error));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(status.StatusCode.unsupported));
}

test "Status from bool" {
    const ok = status.Status.fromBool(true);
    try testing.expect(ok.isOk());
    try testing.expect(!ok.isFatalError());

    const err = status.Status.fromBool(false);
    try testing.expect(!err.isOk());
    try testing.expect(err.isFatalError());
}

test "Status error propagation via Zig error union" {
    const result = tryDecodeHeader();
    try testing.expectError(status.JxlError.GenericError, result);
}

fn tryDecodeHeader() status.JxlError!void {
    return status.JxlError.GenericError;
}
```

Run: `zig build test -Doptimize=Debug`
Expected: FAIL (Status type not yet implemented)

**Step 2: Implement status.zig**

```zig
/// Error handling types mirroring libjxl's Status/StatusCode.
/// In Zig, StatusOr<T> is replaced by `JxlError!T` (error union).
pub const StatusCode = enum(i32) {
    not_enough_bytes = -1,
    ok = 0,
    generic_error = 1,
    unsupported = 2,
};

/// Zig error set corresponding to JXL status codes.
/// Use as return type: `JxlError!T` replaces C++ StatusOr<T>.
/// Use as return type: `JxlError!void` replaces C++ Status.
pub const JxlError = error{
    GenericError,
    Unsupported,
    NotEnoughBytes,
};

/// Maps StatusCode to JxlError for FFI boundary conversions.
pub const Status = struct {
    code: StatusCode,

    pub fn fromBool(ok: bool) Status {
        return .{ .code = if (ok) .ok else .generic_error };
    }

    pub fn fromCode(code: StatusCode) Status {
        return .{ .code = code };
    }

    pub fn isOk(self: Status) bool {
        return self.code == .ok;
    }

    pub fn isFatalError(self: Status) bool {
        return @intFromEnum(self.code) > 0;
    }

    /// Convert to Zig error union for idiomatic error propagation.
    pub fn toError(self: Status) JxlError!void {
        return switch (self.code) {
            .ok => {},
            .generic_error => JxlError.GenericError,
            .unsupported => JxlError.Unsupported,
            .not_enough_bytes => JxlError.NotEnoughBytes,
        };
    }

    /// Convert from Zig error back to Status (for FFI boundary).
    pub fn fromError(err: JxlError) Status {
        return .{ .code = switch (err) {
            JxlError.GenericError => .generic_error,
            JxlError.Unsupported => .unsupported,
            JxlError.NotEnoughBytes => .not_enough_bytes,
        } };
    }
};
```

**Step 3: Run tests**

Run: `zig build test -Doptimize=Debug`
Expected: PASS

**Step 4: Commit**

```
feat: port status.zig — StatusCode, JxlError, Status type
```

---

### Task 5: Port `bits.zig` — Bit manipulation utilities

**Files:**
- Create: `src/lib/base/bits.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/bits.h` (148 lines)

**Step 1: Write failing tests** (translated from `lib/jxl/bits_test.cc`)

```zig
const std = @import("std");
const testing = std.testing;
const bits = @import("base/bits.zig");

test "num zero bits above MS1 - zero input" {
    try testing.expectEqual(@as(u6, 32), bits.num0BitsAboveMS1Bit(@as(u32, 0)));
    try testing.expectEqual(@as(u7, 64), bits.num0BitsAboveMS1Bit(@as(u64, 0)));
}

test "num zero bits below LS1 - zero input" {
    try testing.expectEqual(@as(u6, 32), bits.num0BitsBelowLS1Bit(@as(u32, 0)));
    try testing.expectEqual(@as(u7, 64), bits.num0BitsBelowLS1Bit(@as(u64, 0)));
}

test "num zero bits above MS1 - nonzero" {
    try testing.expectEqual(@as(u6, 31), bits.num0BitsAboveMS1Bit(@as(u32, 1)));
    try testing.expectEqual(@as(u6, 30), bits.num0BitsAboveMS1Bit(@as(u32, 2)));
    try testing.expectEqual(@as(u7, 63), bits.num0BitsAboveMS1Bit(@as(u64, 1)));
    try testing.expectEqual(@as(u7, 62), bits.num0BitsAboveMS1Bit(@as(u64, 2)));
    try testing.expectEqual(@as(u6, 0), bits.num0BitsAboveMS1Bit(@as(u32, 0x80000000)));
    try testing.expectEqual(@as(u7, 0), bits.num0BitsAboveMS1Bit(@as(u64, 0x8000000000000000)));
}

test "num zero bits below LS1 - nonzero" {
    try testing.expectEqual(@as(u6, 0), bits.num0BitsBelowLS1Bit(@as(u32, 1)));
    try testing.expectEqual(@as(u7, 0), bits.num0BitsBelowLS1Bit(@as(u64, 1)));
    try testing.expectEqual(@as(u6, 1), bits.num0BitsBelowLS1Bit(@as(u32, 2)));
    try testing.expectEqual(@as(u7, 1), bits.num0BitsBelowLS1Bit(@as(u64, 2)));
    try testing.expectEqual(@as(u6, 31), bits.num0BitsBelowLS1Bit(@as(u32, 0x80000000)));
    try testing.expectEqual(@as(u7, 63), bits.num0BitsBelowLS1Bit(@as(u64, 0x8000000000000000)));
}

test "floorLog2Nonzero" {
    const expected = [7]u6{ 0, 1, 1, 2, 2, 2, 2 };
    for (expected, 1..) |exp, i| {
        try testing.expectEqual(exp, bits.floorLog2Nonzero(@as(u32, @intCast(i))));
    }
    try testing.expectEqual(@as(u6, 31), bits.floorLog2Nonzero(@as(u32, 0x80000000)));
    try testing.expectEqual(@as(u6, 31), bits.floorLog2Nonzero(@as(u32, 0xFFFFFFFF)));
    try testing.expectEqual(@as(u7, 63), bits.floorLog2Nonzero(@as(u64, 0x8000000000000000)));
    try testing.expectEqual(@as(u7, 63), bits.floorLog2Nonzero(@as(u64, 0xFFFFFFFFFFFFFFFF)));
}

test "ceilLog2Nonzero" {
    const expected = [7]u6{ 0, 1, 2, 2, 3, 3, 3 };
    for (expected, 1..) |exp, i| {
        try testing.expectEqual(exp, bits.ceilLog2Nonzero(@as(u32, @intCast(i))));
    }
    try testing.expectEqual(@as(u6, 31), bits.ceilLog2Nonzero(@as(u32, 0x80000000)));
    try testing.expectEqual(@as(u6, 32), bits.ceilLog2Nonzero(@as(u32, 0x80000001)));
    try testing.expectEqual(@as(u6, 32), bits.ceilLog2Nonzero(@as(u32, 0xFFFFFFFF)));
}
```

Run: `zig build test -Doptimize=Debug`
Expected: FAIL

**Step 2: Implement bits.zig**

```zig
/// Bit manipulation utilities — CLZ, CTZ, floor/ceil log2.
/// Zig builtins (@clz, @ctz) replace the C++ compiler intrinsics.
const std = @import("std");

/// Count leading zeros. Returns bit_width for x == 0.
pub fn num0BitsAboveMS1Bit(x: anytype) std.math.Log2Int(@TypeOf(x)) {
    // Zig's @clz is undefined for 0 in some contexts but actually
    // returns bit_width, matching C++ Num0BitsAboveMS1Bit behavior.
    // However to be safe with the type system:
    const T = @TypeOf(x);
    const bits = @typeInfo(T).int.bits;
    if (x == 0) return @intCast(bits);
    return @clz(x);
}

/// Count trailing zeros. Returns bit_width for x == 0.
pub fn num0BitsBelowLS1Bit(x: anytype) std.math.Log2Int(@TypeOf(x)) {
    const T = @TypeOf(x);
    const bits = @typeInfo(T).int.bits;
    if (x == 0) return @intCast(bits);
    return @ctz(x);
}

/// Floor of base-2 logarithm. Undefined for x == 0.
pub fn floorLog2Nonzero(x: anytype) std.math.Log2Int(@TypeOf(x)) {
    const T = @TypeOf(x);
    const bits = @typeInfo(T).int.bits;
    std.debug.assert(x != 0);
    return @intCast(bits - 1 - @as(usize, @intCast(@clz(x))));
}

/// Ceiling of base-2 logarithm. Undefined for x == 0.
pub fn ceilLog2Nonzero(x: anytype) std.math.Log2Int(@TypeOf(x)) {
    const floor = floorLog2Nonzero(x);
    if ((x & (x - 1)) == 0) return floor; // power of two
    return floor + 1;
}
```

**Step 3: Update root.zig to include bits**

Add `pub const bits = @import("base/bits.zig");` to the base struct.

**Step 4: Run tests**

Run: `zig build test -Doptimize=Debug`
Expected: PASS

**Step 5: Commit**

```
feat: port bits.zig — CLZ, CTZ, floor/ceil log2
```

---

### Task 6: Port `common.zig` — Shared constants and helpers

**Files:**
- Create: `src/lib/base/common.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/common.h` (170 lines)

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const common = @import("base/common.zig");

test "roundUpBitsToByteMultiple" {
    try testing.expectEqual(@as(usize, 0), common.roundUpBitsToByteMultiple(0));
    try testing.expectEqual(@as(usize, 8), common.roundUpBitsToByteMultiple(1));
    try testing.expectEqual(@as(usize, 8), common.roundUpBitsToByteMultiple(7));
    try testing.expectEqual(@as(usize, 8), common.roundUpBitsToByteMultiple(8));
    try testing.expectEqual(@as(usize, 16), common.roundUpBitsToByteMultiple(9));
}

test "roundUpToBlockDim" {
    try testing.expectEqual(@as(usize, 0), common.roundUpToBlockDim(0));
    try testing.expectEqual(@as(usize, 8), common.roundUpToBlockDim(1));
    try testing.expectEqual(@as(usize, 8), common.roundUpToBlockDim(8));
    try testing.expectEqual(@as(usize, 16), common.roundUpToBlockDim(9));
}

test "divCeil" {
    try testing.expectEqual(@as(usize, 0), common.divCeil(@as(usize, 0), @as(usize, 3)));
    try testing.expectEqual(@as(usize, 1), common.divCeil(@as(usize, 1), @as(usize, 3)));
    try testing.expectEqual(@as(usize, 1), common.divCeil(@as(usize, 3), @as(usize, 3)));
    try testing.expectEqual(@as(usize, 2), common.divCeil(@as(usize, 4), @as(usize, 3)));
}

test "roundUpTo" {
    try testing.expectEqual(@as(usize, 0), common.roundUpTo(0, 8));
    try testing.expectEqual(@as(usize, 8), common.roundUpTo(1, 8));
    try testing.expectEqual(@as(usize, 8), common.roundUpTo(8, 8));
    try testing.expectEqual(@as(usize, 16), common.roundUpTo(9, 8));
}

test "clamp1" {
    try testing.expectEqual(@as(i32, 0), common.clamp1(@as(i32, -5), 0, 10));
    try testing.expectEqual(@as(i32, 5), common.clamp1(@as(i32, 5), 0, 10));
    try testing.expectEqual(@as(i32, 10), common.clamp1(@as(i32, 15), 0, 10));
}

test "safeAdd" {
    const r1 = common.safeAdd(5, 10);
    try testing.expectEqual(@as(u64, 15), r1.?);

    const r2 = common.safeAdd(0xFFFFFFFFFFFFFFFF, 1);
    try testing.expectEqual(@as(?u64, null), r2);
}
```

Run: `zig build test -Doptimize=Debug`
Expected: FAIL

**Step 2: Implement common.zig**

```zig
/// Shared constants and helper functions mirroring lib/jxl/base/common.h.
pub const bits_per_byte: usize = 8;
pub const pi: f64 = 3.14159265358979323846264338327950288;
pub const inv_log2e: f32 = 0.6931471805599453;
pub const default_intensity_target: f32 = 255;

pub const Color = [3]f32;

pub fn roundUpBitsToByteMultiple(b: usize) usize {
    return (b + 7) & ~@as(usize, 7);
}

pub fn roundUpToBlockDim(dim: usize) usize {
    return (dim + 7) & ~@as(usize, 7);
}

pub fn safeAdd(a: u64, b: u64) ?u64 {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

pub fn divCeil(a: anytype, b: anytype) @TypeOf(a) {
    if (a == 0) return 0;
    return (a + b - 1) / b;
}

pub fn roundUpTo(what: usize, align: usize) usize {
    return divCeil(what, align) * align;
}

pub fn clamp1(val: anytype, low: anytype, hi: anytype) @TypeOf(val) {
    return if (val < low) low else if (val > hi) hi else val;
}

pub fn piMultiplied(comptime T: type, multiplier: T) T {
    return @as(T, @floatCast(pi)) * multiplier;
}
```

**Step 3: Update root.zig, run tests**

Run: `zig build test -Doptimize=Debug`
Expected: PASS

**Step 4: Commit**

```
feat: port common.zig — constants, divCeil, clamp, roundUp
```

---

### Task 7: Port `byte_order.zig` — Endian load/store

**Files:**
- Create: `src/lib/base/byte_order.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/byte_order.h` (274 lines)

Zig's `std.mem.readInt` handles endianness natively, so this becomes much simpler.

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const bo = @import("base/byte_order.zig");

test "loadLE16" {
    const bytes = [_]u8{ 0x34, 0x12 };
    try testing.expectEqual(@as(u16, 0x1234), bo.loadLE16(&bytes));
}

test "loadBE16" {
    const bytes = [_]u8{ 0x12, 0x34 };
    try testing.expectEqual(@as(u16, 0x1234), bo.loadBE16(&bytes));
}

test "loadLE32" {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try testing.expectEqual(@as(u32, 0x12345678), bo.loadLE32(&bytes));
}

test "loadBE32" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try testing.expectEqual(@as(u32, 0x12345678), bo.loadBE32(&bytes));
}

test "loadLE64" {
    const bytes = [_]u8{ 0xEF, 0xCD, 0xAB, 0x90, 0x78, 0x56, 0x34, 0x12 };
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), bo.loadLE64(&bytes));
}

test "loadBE64" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF };
    try testing.expectEqual(@as(u64, 0x1234567890ABCDEF), bo.loadBE64(&bytes));
}

test "store/load round-trip LE32" {
    var buf: [4]u8 = undefined;
    bo.storeLE32(0xDEADBEEF, &buf);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), bo.loadLE32(&buf));
}

test "store/load round-trip BE32" {
    var buf: [4]u8 = undefined;
    bo.storeBE32(0xDEADBEEF, &buf);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), bo.loadBE32(&buf));
}

test "loadBEFloat / loadLEFloat" {
    // IEEE 754: 1.0f = 0x3F800000
    const be_bytes = [_]u8{ 0x3F, 0x80, 0x00, 0x00 };
    try testing.expectEqual(@as(f32, 1.0), bo.loadBEFloat(&be_bytes));

    const le_bytes = [_]u8{ 0x00, 0x00, 0x80, 0x3F };
    try testing.expectEqual(@as(f32, 1.0), bo.loadLEFloat(&le_bytes));
}
```

Run: `zig build test -Doptimize=Debug`
Expected: FAIL

**Step 2: Implement byte_order.zig**

```zig
/// Endian-aware load/store for 16/32/64-bit integers and floats.
/// Wraps std.mem.readInt/writeInt for clarity and C++ API parity.
const std = @import("std");

pub fn loadLE16(p: *const [2]u8) u16 {
    return std.mem.readInt(u16, p, .little);
}

pub fn loadBE16(p: *const [2]u8) u16 {
    return std.mem.readInt(u16, p, .big);
}

pub fn loadLE32(p: *const [4]u8) u32 {
    return std.mem.readInt(u32, p, .little);
}

pub fn loadBE32(p: *const [4]u8) u32 {
    return std.mem.readInt(u32, p, .big);
}

pub fn loadLE64(p: *const [8]u8) u64 {
    return std.mem.readInt(u64, p, .little);
}

pub fn loadBE64(p: *const [8]u8) u64 {
    return std.mem.readInt(u64, p, .big);
}

pub fn storeLE16(val: u16, p: *[2]u8) void {
    std.mem.writeInt(u16, p, val, .little);
}

pub fn storeBE16(val: u16, p: *[2]u8) void {
    std.mem.writeInt(u16, p, val, .big);
}

pub fn storeLE32(val: u32, p: *[4]u8) void {
    std.mem.writeInt(u32, p, val, .little);
}

pub fn storeBE32(val: u32, p: *[4]u8) void {
    std.mem.writeInt(u32, p, val, .big);
}

pub fn storeLE64(val: u64, p: *[8]u8) void {
    std.mem.writeInt(u64, p, val, .little);
}

pub fn storeBE64(val: u64, p: *[8]u8) void {
    std.mem.writeInt(u64, p, val, .big);
}

pub fn loadLEFloat(p: *const [4]u8) f32 {
    return @bitCast(loadLE32(p));
}

pub fn loadBEFloat(p: *const [4]u8) f32 {
    return @bitCast(loadBE32(p));
}

pub fn bswapFloat(x: f32) f32 {
    const u: u32 = @bitCast(x);
    return @bitCast(@byteSwap(u));
}
```

**Step 3: Update root.zig, run tests**

Expected: PASS

**Step 4: Commit**

```
feat: port byte_order.zig — endian load/store for 16/32/64-bit
```

---

### Task 8: Port `random.zig` — Xorshift128+ RNG

**Files:**
- Create: `src/lib/base/random.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/random.h` (99 lines)

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const Rng = @import("base/random.zig").Rng;

test "Rng deterministic output for seed 0" {
    var rng = Rng.init(0);
    const v1 = rng.next();
    const v2 = rng.next();
    // Same seed must produce same sequence
    var rng2 = Rng.init(0);
    try testing.expectEqual(v1, rng2.next());
    try testing.expectEqual(v2, rng2.next());
}

test "Rng different seeds produce different output" {
    var rng1 = Rng.init(0);
    var rng2 = Rng.init(1);
    try testing.expect(rng1.next() != rng2.next());
}

test "Rng uniformI range" {
    var rng = Rng.init(42);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const val = rng.uniformI(10, 20);
        try testing.expect(val >= 10 and val < 20);
    }
}

test "Rng uniformF range" {
    var rng = Rng.init(42);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const val = rng.uniformF(0.0, 1.0);
        try testing.expect(val >= 0.0 and val < 1.0);
    }
}

test "Rng shuffle preserves elements" {
    var rng = Rng.init(7);
    var arr = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    rng.shuffle(u32, &arr);
    // All elements still present
    var sum: u32 = 0;
    for (arr) |v| sum += v;
    try testing.expectEqual(@as(u32, 45), sum);
}
```

Run: `zig build test -Doptimize=Debug`
Expected: FAIL

**Step 2: Implement random.zig**

```zig
/// Xorshift128+ PRNG matching libjxl's jxl::Rng exactly.
/// Deterministic across platforms (no std.Random dependency).
const std = @import("std");

pub const Rng = struct {
    s: [2]u64,

    pub fn init(seed: u64) Rng {
        return .{ .s = .{
            0x94D049BB133111EB,
            0xBF58476D1CE4E5B9 +% seed,
        } };
    }

    pub fn next(self: *Rng) u64 {
        var s1 = self.s[0];
        const s0 = self.s[1];
        const bits = s1 +% s0;
        self.s[0] = s0;
        s1 ^= s1 << 23;
        s1 ^= s0 ^ (s1 >> 18) ^ (s0 >> 5);
        self.s[1] = s1;
        return bits;
    }

    pub fn uniformI(self: *Rng, begin: i64, end: i64) i64 {
        std.debug.assert(end > begin);
        const range: u64 = @intCast(end - begin);
        return @as(i64, @intCast(self.next() % range)) + begin;
    }

    pub fn uniformU(self: *Rng, begin: u64, end: u64) u64 {
        std.debug.assert(end > begin);
        return self.next() % (end - begin) + begin;
    }

    pub fn uniformF(self: *Rng, begin: f32, end: f32) f32 {
        // Bits of a random [1, 2) float
        const u: u32 = @truncate(self.next() >> (64 - 23));
        const bits = u | 0x3F800000;
        const f: f32 = @bitCast(bits);
        return (end - begin) * (f - 1.0) + begin;
    }

    pub fn bernoulli(self: *Rng, p: f32) bool {
        return self.uniformF(0, 1) < p;
    }

    pub fn shuffle(self: *Rng, comptime T: type, items: []T) void {
        if (items.len <= 1) return;
        for (0..items.len - 1) |i| {
            const a = @as(usize, @intCast(self.uniformU(i, items.len)));
            std.mem.swap(T, &items[a], &items[i]);
        }
    }
};
```

**Step 3: Update root.zig, run tests**

Expected: PASS

**Step 4: Commit**

```
feat: port random.zig — Xorshift128+ RNG matching libjxl
```

---

### Task 9: Port `rect.zig` — Rectangular region

**Files:**
- Create: `src/lib/base/rect.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/rect.h` (186 lines)

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const Rect = @import("base/rect.zig").Rect;

test "Rect basic construction" {
    const r = Rect.init(10, 20, 100, 200);
    try testing.expectEqual(@as(usize, 10), r.x0());
    try testing.expectEqual(@as(usize, 20), r.y0());
    try testing.expectEqual(@as(usize, 100), r.xsize());
    try testing.expectEqual(@as(usize, 200), r.ysize());
    try testing.expectEqual(@as(usize, 110), r.x1());
    try testing.expectEqual(@as(usize, 220), r.y1());
}

test "Rect clamped construction" {
    const r = Rect.initClamped(10, 20, 100, 200, 50, 100);
    try testing.expectEqual(@as(usize, 10), r.x0());
    try testing.expectEqual(@as(usize, 20), r.y0());
    try testing.expectEqual(@as(usize, 40), r.xsize()); // clamped: 50-10
    try testing.expectEqual(@as(usize, 80), r.ysize()); // clamped: 100-20
}

test "Rect intersection" {
    const a = Rect.init(0, 0, 100, 100);
    const b = Rect.init(50, 50, 100, 100);
    const c = a.intersection(b);
    try testing.expectEqual(@as(usize, 50), c.x0());
    try testing.expectEqual(@as(usize, 50), c.y0());
    try testing.expectEqual(@as(usize, 50), c.xsize());
    try testing.expectEqual(@as(usize, 50), c.ysize());
}

test "Rect isInside" {
    const outer = Rect.init(0, 0, 100, 100);
    const inner = Rect.init(10, 10, 20, 20);
    try testing.expect(inner.isInside(outer));
    try testing.expect(!outer.isInside(inner));
}

test "Rect shiftLeft" {
    const r = Rect.init(2, 3, 4, 5);
    const shifted = r.shiftLeft(1, 1);
    try testing.expectEqual(@as(usize, 4), shifted.x0());
    try testing.expectEqual(@as(usize, 6), shifted.y0());
    try testing.expectEqual(@as(usize, 8), shifted.xsize());
    try testing.expectEqual(@as(usize, 10), shifted.ysize());
}

test "Rect translate" {
    const r = Rect.init(10, 20, 5, 5);
    const t = r.translate(3, -5);
    try testing.expectEqual(@as(usize, 13), t.x0());
    try testing.expectEqual(@as(usize, 15), t.y0());
}
```

**Step 2: Implement rect.zig**

```zig
/// Rectangular region in images. Mirrors lib/jxl/base/rect.h.
/// Used to reference sub-regions across images of different resolutions.
const std = @import("std");
const common = @import("common.zig");

pub const Rect = struct {
    x0_: usize,
    y0_: usize,
    xsize_: usize,
    ysize_: usize,

    pub fn init(xbegin: usize, ybegin: usize, xsize: usize, ysize: usize) Rect {
        return .{ .x0_ = xbegin, .y0_ = ybegin, .xsize_ = xsize, .ysize_ = ysize };
    }

    pub fn initClamped(
        xbegin: usize, ybegin: usize,
        xsize_max: usize, ysize_max: usize,
        xend: usize, yend: usize,
    ) Rect {
        return .{
            .x0_ = xbegin,
            .y0_ = ybegin,
            .xsize_ = clampedSize(xbegin, xsize_max, xend),
            .ysize_ = clampedSize(ybegin, ysize_max, yend),
        };
    }

    pub fn empty() Rect {
        return init(0, 0, 0, 0);
    }

    pub fn x0(self: Rect) usize { return self.x0_; }
    pub fn y0(self: Rect) usize { return self.y0_; }
    pub fn xsize(self: Rect) usize { return self.xsize_; }
    pub fn ysize(self: Rect) usize { return self.ysize_; }
    pub fn x1(self: Rect) usize { return self.x0_ + self.xsize_; }
    pub fn y1(self: Rect) usize { return self.y0_ + self.ysize_; }

    pub fn intersection(self: Rect, other: Rect) Rect {
        const nx0 = @max(self.x0_, other.x0_);
        const ny0 = @max(self.y0_, other.y0_);
        const nx1 = @min(self.x1(), other.x1());
        const ny1 = @min(self.y1(), other.y1());
        return .{
            .x0_ = nx0,
            .y0_ = ny0,
            .xsize_ = if (nx1 > nx0) nx1 - nx0 else 0,
            .ysize_ = if (ny1 > ny0) ny1 - ny0 else 0,
        };
    }

    pub fn translate(self: Rect, x_offset: i64, y_offset: i64) Rect {
        return .{
            .x0_ = @intCast(@as(i64, @intCast(self.x0_)) + x_offset),
            .y0_ = @intCast(@as(i64, @intCast(self.y0_)) + y_offset),
            .xsize_ = self.xsize_,
            .ysize_ = self.ysize_,
        };
    }

    pub fn isInside(self: Rect, other: Rect) bool {
        return self.x0_ >= other.x0_ and self.x1() <= other.x1() and
            self.y0_ >= other.y0_ and self.y1() <= other.y1();
    }

    pub fn shiftLeft(self: Rect, shiftx: u6, shifty: u6) Rect {
        return .{
            .x0_ = self.x0_ << shiftx,
            .y0_ = self.y0_ << shifty,
            .xsize_ = self.xsize_ << shiftx,
            .ysize_ = self.ysize_ << shifty,
        };
    }

    pub fn shiftLeftUniform(self: Rect, shift: u6) Rect {
        return self.shiftLeft(shift, shift);
    }

    pub fn ceilShiftRight(self: Rect, shiftx: u6, shifty: u6) !Rect {
        if ((self.x0_ % (@as(usize, 1) << shiftx) != 0) or
            (self.y0_ % (@as(usize, 1) << shifty) != 0))
            return error.InvalidAlignment;
        return .{
            .x0_ = self.x0_ >> shiftx,
            .y0_ = self.y0_ >> shifty,
            .xsize_ = common.divCeil(self.xsize_, @as(usize, 1) << shiftx),
            .ysize_ = common.divCeil(self.ysize_, @as(usize, 1) << shifty),
        };
    }

    fn clampedSize(begin: usize, size_max: usize, end: usize) usize {
        if (begin + size_max <= end) return size_max;
        return if (end > begin) end - begin else 0;
    }
};
```

**Step 3: Run tests**

Expected: PASS

**Step 4: Commit**

```
feat: port rect.zig — Rect region type
```

---

### Task 10: Port `float.zig` — Float16 and typed float loading

**Files:**
- Create: `src/lib/base/float.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/base/float.h` (101 lines)

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const float = @import("base/float.zig");

test "loadFloat16 - zero" {
    try testing.expectEqual(@as(f32, 0.0), float.loadFloat16(0));
}

test "loadFloat16 - one" {
    // f16 1.0 = 0x3C00
    try testing.expectEqual(@as(f32, 1.0), float.loadFloat16(0x3C00));
}

test "loadFloat16 - negative one" {
    // f16 -1.0 = 0xBC00
    try testing.expectEqual(@as(f32, -1.0), float.loadFloat16(0xBC00));
}

test "loadFloat16 - subnormal" {
    // Smallest positive subnormal: 0x0001 = 2^-24
    const val = float.loadFloat16(0x0001);
    try testing.expect(val > 0.0);
    try testing.expect(val < 0.001);
}

test "loadFloat16 - infinity" {
    const val = float.loadFloat16(0x7C00);
    try testing.expect(std.math.isInf(val));
}
```

**Step 2: Implement float.zig**

```zig
/// Float16 loading and typed float row loading.
/// Mirrors lib/jxl/base/float.h.
const std = @import("std");

pub fn loadFloat16(bits16: u16) f32 {
    const sign: u32 = bits16 >> 15;
    const biased_exp: u32 = (bits16 >> 10) & 0x1F;
    const mantissa: u32 = bits16 & 0x3FF;

    if (biased_exp == 0) {
        // Subnormal or zero
        const subnormal = (1.0 / 16384.0) * (@as(f32, @floatFromInt(mantissa)) * (1.0 / 1024.0));
        return if (sign != 0) -subnormal else subnormal;
    }

    const biased_exp32: u32 = if (biased_exp == 0b11111) 0b11111111 else biased_exp + (127 - 15);
    const mantissa32: u32 = mantissa << (23 - 10);
    const bits32: u32 = (sign << 31) | (biased_exp32 << 23) | mantissa32;

    return @bitCast(bits32);
}
```

**Step 3: Run tests**

Expected: PASS

**Step 4: Commit**

```
feat: port float.zig — float16 loading
```

---

### Task 11: Port `bit_reader.zig` — Core BitReader

**Files:**
- Create: `src/lib/base/bit_reader.zig`
- Update: `src/lib/root.zig`

**C++ source:** `lib/jxl/dec_bit_reader.h` + `lib/jxl/dec_bit_reader.cc` (~315 + ~50 lines)

This is the most critical foundation piece — the bitstream reader used by every decoder path.

**Step 1: Write failing tests**

```zig
const testing = @import("std").testing;
const BitReader = @import("base/bit_reader.zig").BitReader;

test "BitReader reads single bits" {
    const data = [_]u8{0b10110100};
    var reader = BitReader.init(&data);
    // LSB first
    try testing.expectEqual(@as(u64, 0), reader.readBits(1));
    try testing.expectEqual(@as(u64, 0), reader.readBits(1));
    try testing.expectEqual(@as(u64, 1), reader.readBits(1));
    try testing.expectEqual(@as(u64, 0), reader.readBits(1));
    try testing.expectEqual(@as(u64, 1), reader.readBits(1));
    try testing.expectEqual(@as(u64, 1), reader.readBits(1));
    try testing.expectEqual(@as(u64, 0), reader.readBits(1));
    try testing.expectEqual(@as(u64, 1), reader.readBits(1));
    try reader.close();
}

test "BitReader reads multi-bit values" {
    // 0xABCD in LE = [0xCD, 0xAB]
    const data = [_]u8{ 0xCD, 0xAB };
    var reader = BitReader.init(&data);
    try testing.expectEqual(@as(u64, 0xABCD), reader.readBits(16));
    try reader.close();
}

test "BitReader totalBitsConsumed tracks correctly" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var reader = BitReader.init(&data);
    try testing.expectEqual(@as(usize, 0), reader.totalBitsConsumed());
    _ = reader.readBits(3);
    try testing.expectEqual(@as(usize, 3), reader.totalBitsConsumed());
    _ = reader.readBits(5);
    try testing.expectEqual(@as(usize, 8), reader.totalBitsConsumed());
    try reader.close();
}

test "BitReader jumpToByteBoundary" {
    const data = [_]u8{ 0x00, 0xFF };
    var reader = BitReader.init(&data);
    _ = reader.readBits(3);
    try reader.jumpToByteBoundary();
    try testing.expectEqual(@as(usize, 8), reader.totalBitsConsumed());
    try reader.close();
}

test "BitReader overread returns zeros" {
    const data = [_]u8{0xAB};
    var reader = BitReader.init(&data);
    const val = reader.readBits(8);
    try testing.expectEqual(@as(u64, 0xAB), val);
    // Reading past end returns zeros
    const past = reader.readBits(8);
    try testing.expectEqual(@as(u64, 0), past);
    // But close reports error
    try testing.expectError(error.GenericError, reader.close());
}

test "BitReader empty input" {
    const data = [_]u8{};
    var reader = BitReader.init(&data);
    try reader.close();
}
```

**Step 2: Implement bit_reader.zig**

The C++ BitReader uses a 64-bit buffer with deferred refills. We translate this faithfully.

```zig
/// Bounds-checked bit reader with 64-bit buffer and deferred refills.
/// Reads little-endian bitstreams. Mirrors lib/jxl/dec_bit_reader.h.
const std = @import("std");
const status = @import("status.zig");
const byte_order = @import("byte_order.zig");

pub const BitReader = struct {
    const max_bits_per_call: usize = 56;

    buf: u64,
    bits_in_buf: u6, // [0, 63]
    data: []const u8,
    pos: usize, // next byte position
    overread_bytes: u64,
    close_called: bool,
    checked_out_of_bounds_bits: usize,

    pub fn init(data: []const u8) BitReader {
        var self = BitReader{
            .buf = 0,
            .bits_in_buf = 0,
            .data = data,
            .pos = 0,
            .overread_bytes = 0,
            .close_called = false,
            .checked_out_of_bounds_bits = 0,
        };
        self.refill();
        return self;
    }

    pub fn refill(self: *BitReader) void {
        if (self.pos + 8 <= self.data.len) {
            // Safe to load 8 bytes
            const loaded = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
            self.buf |= loaded << self.bits_in_buf;
            const advance = (63 - @as(usize, self.bits_in_buf)) >> 3;
            self.pos += advance;
            self.bits_in_buf |= 56;
        } else {
            self.boundsCheckedRefill();
        }
    }

    fn boundsCheckedRefill(self: *BitReader) void {
        while (self.bits_in_buf < 56) {
            if (self.pos < self.data.len) {
                self.buf |= @as(u64, self.data[self.pos]) << self.bits_in_buf;
                self.pos += 1;
            } else {
                self.overread_bytes += 1;
            }
            self.bits_in_buf +|= 8;
            if (self.bits_in_buf >= 56) break;
        }
    }

    pub fn peekBits(self: *const BitReader, nbits: u6) u64 {
        std.debug.assert(!self.close_called);
        if (nbits == 0) return 0;
        const mask = (@as(u64, 1) << nbits) - 1;
        return self.buf & mask;
    }

    pub fn consume(self: *BitReader, num_bits: u6) void {
        std.debug.assert(!self.close_called);
        self.bits_in_buf -= num_bits;
        self.buf >>= num_bits;
    }

    pub fn readBits(self: *BitReader, nbits: u6) u64 {
        std.debug.assert(!self.close_called);
        self.refill();
        const val = self.peekBits(nbits);
        self.consume(nbits);
        return val;
    }

    pub fn totalBitsConsumed(self: *const BitReader) usize {
        return (self.pos + self.overread_bytes) * 8 - @as(usize, self.bits_in_buf);
    }

    pub fn totalBytes(self: *const BitReader) usize {
        return self.data.len;
    }

    pub fn jumpToByteBoundary(self: *BitReader) status.JxlError!void {
        const remainder = self.totalBitsConsumed() % 8;
        if (remainder == 0) return;
        const skip: u6 = @intCast(8 - remainder);
        if (self.readBits(skip) != 0) {
            return status.JxlError.GenericError;
        }
    }

    pub fn allReadsWithinBounds(self: *BitReader) bool {
        self.checked_out_of_bounds_bits = self.totalBitsConsumed();
        return self.totalBitsConsumed() <= self.totalBytes() * 8;
    }

    pub fn close(self: *BitReader) status.JxlError!void {
        std.debug.assert(!self.close_called);
        self.close_called = true;
        if (self.data.len == 0) return;
        if (self.totalBitsConsumed() > self.checked_out_of_bounds_bits and
            self.totalBitsConsumed() > self.totalBytes() * 8)
        {
            return status.JxlError.GenericError;
        }
    }

    pub fn skipBits(self: *BitReader, skip_count: usize) void {
        std.debug.assert(!self.close_called);
        var skip = skip_count;

        if (skip <= self.bits_in_buf) {
            self.consume(@intCast(skip));
            return;
        }

        skip -= self.bits_in_buf;
        self.bits_in_buf = 0;
        self.buf = 0;

        const whole_bytes = skip / 8;
        skip %= 8;
        if (whole_bytes > self.data.len -| self.pos) {
            self.pos = self.data.len;
            skip += 8;
        } else {
            self.pos += whole_bytes;
        }

        self.refill();
        if (skip > 0) self.consume(@intCast(skip));
    }
};
```

**Step 3: Run tests**

Run: `zig build test -Doptimize=Debug`
Expected: PASS

**Step 4: Commit**

```
feat: port bit_reader.zig — 64-bit buffered bitstream reader
```

---

### Task 12: Project scaffolding files

**Files:**
- Create: `PLAN.md`
- Create: `IMPROVEMENTS.md`
- Create: `CODE_MINIMAP.md`
- Create: `PROJECT_OVERVIEW.md`

**Step 1: Create all four files**

`PROJECT_OVERVIEW.md`:
```markdown
# libjxlz

A Zig reimplementation of the JPEG XL (ISO 18181) reference codec, targeting
equivalent or better performance than the original C++ libjxl.

## Terminology
- **JXL**: JPEG XL image format
- **ANS**: Asymmetric Numeral Systems (entropy coding)
- **MA tree**: Meta-Adaptive tree (modular integer coding)
- **XYB**: Perceptual color space used by JXL
- **DCT**: Discrete Cosine Transform
- **Highway**: Google's SIMD abstraction library (being replaced by Zig @Vector)
- **cjxl/djxl**: Original compress/decompress CLI tools
- **cjxlz/djxlz**: Our Zig-based equivalents
```

`IMPROVEMENTS.md`:
```markdown
# Improvement Notes

Items spotted during transliterative port — do NOT implement inline.
Revisit after full port is complete and all tests pass.

## Foundation Layer
- [ ] byte_order.zig: The C++ version has extensive #if branches for endianness.
      Zig's std.mem.readInt handles this natively. Verify codegen is equivalent.
- [ ] bit_reader.zig: Consider using Zig's comptime to specialize PeekFixedBits
      (C++ uses template<size_t N>) — may enable better optimization.
- [ ] common.zig: UninitializedAllocator pattern from C++ could map to
      Zig's undefined initialization — worth benchmarking.
```

`CODE_MINIMAP.md`:
```markdown
# Code Minimap

## src/lib/
- `root.zig` — Module root, re-exports all submodules

### src/lib/base/
- `status.zig` — StatusCode enum, JxlError error set, Status struct (FFI bridge)
- `bits.zig` — CLZ, CTZ, floorLog2, ceilLog2 bit manipulation
- `common.zig` — Constants (pi, bits_per_byte), divCeil, roundUp, clamp
- `byte_order.zig` — Endian-aware load/store for 16/32/64-bit ints and floats
- `random.zig` — Xorshift128+ PRNG (deterministic, platform-independent)
- `rect.zig` — Rect type for rectangular image regions
- `float.zig` — Float16 loading, typed float row loading
- `bit_reader.zig` — 64-bit buffered bitstream reader with deferred refill
```

`PLAN.md`:
```markdown
# libjxlz Plan

## Phase 1: Foundation (current)
- [ ] build.zig + build.zig.zon
- [ ] ./build and ./test scripts
- [ ] flake.nix with Zig + Garnix
- [ ] status.zig
- [ ] bits.zig
- [ ] common.zig
- [ ] byte_order.zig
- [ ] random.zig
- [ ] rect.zig
- [ ] float.zig
- [ ] bit_reader.zig
- [ ] Project scaffolding (PLAN.md, IMPROVEMENTS.md, etc.)

## Phase 2: Entropy Decoding
- [ ] ANS decoder
- [ ] Huffman decoder
- [ ] Brotli integration (C FFI)

## Phase 3: Core Decoder
- [ ] Frame header parsing
- [ ] Group decoding
- [ ] Modular integer decoding (MA trees)
- [ ] Context map decoding

## Phase 4: Render Pipeline
- [ ] Inverse DCT (SIMD)
- [ ] Color transforms (XYB)
- [ ] Upsampling, noise, blending
- [ ] Pipeline assembly

## Phase 5: Decode API + CLI
- [ ] C FFI decode API
- [ ] djxlz CLI
- [ ] Conformance tests

## Phase 6: Encoder
- [ ] Forward DCT + quantization
- [ ] ANS encoder
- [ ] Modular encoder
- [ ] Frame encoder
- [ ] Fast lossless encoder
- [ ] C FFI encode API
- [ ] cjxlz CLI

## Phase 7: Extras
- [ ] JPEG recompression (jpegli)
- [ ] jxltranz transcoder
- [ ] Butteraugli / SSIMULACRA metrics
```

**Step 2: Commit**

```
docs: add PROJECT_OVERVIEW, PLAN, IMPROVEMENTS, CODE_MINIMAP
```

---

### Task 13: Verify full test suite

**Step 1: Run `./test`**

Expected: All Zig unit tests pass, exit 0.

**Step 2: Run `./build`**

Expected: ReleaseFast build succeeds, produces `zig-out/lib/libjxlz.a`

**Step 3: Verify nix build**

Run: `nix build`
Expected: Builds successfully

---

## Summary

13 tasks covering:
- Build infrastructure (tasks 1-3)
- 8 foundation modules ported from C++ (tasks 4-11)
- Documentation scaffolding (task 12)
- Integration verification (task 13)

Total C++ lines translated: ~2,900 (all of `lib/jxl/base/`)
Estimated Zig output: ~600-800 lines (Zig is more concise)

After Phase 1, we have a tested foundation to build the entropy decoders on.
