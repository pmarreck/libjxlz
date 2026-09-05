const std = @import("std");

pub const StatusCode = enum(i32) {
	not_enough_bytes = -1,
	ok = 0,
	generic_error = 1,
	unsupported = 2,
};

pub const JxlError = error{
	GenericError,
	InvalidColorEncoding,
	Unsupported,
	NotEnoughBytes,
	OutOfMemory,
};

/// Drop-in replacement for bool that carries an error code.
/// Zig port of jxl::Status from status.h.
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

	/// Returns true if the status code is a fatal error (positive value).
	pub fn isFatalError(self: Status) bool {
		return @intFromEnum(self.code) > 0;
	}

	/// Convert to Zig error union: returns void on success, JxlError on failure.
	pub fn toError(self: Status) JxlError!void {
		return switch (self.code) {
			.ok => {},
			.generic_error => JxlError.GenericError,
			.unsupported => JxlError.Unsupported,
			.not_enough_bytes => JxlError.NotEnoughBytes,
		};
	}

	/// Convert a JxlError back into a Status.
	pub fn fromError(err: JxlError) Status {
		return switch (err) {
			JxlError.GenericError, JxlError.InvalidColorEncoding => Status{ .code = .generic_error },
			JxlError.Unsupported => Status{ .code = .unsupported },
			JxlError.NotEnoughBytes => Status{ .code = .not_enough_bytes },
			JxlError.OutOfMemory => Status{ .code = .generic_error },
		};
	}
};

test "StatusCode enum values match C++" {
	const testing = std.testing;
	try testing.expectEqual(@as(i32, -1), @intFromEnum(StatusCode.not_enough_bytes));
	try testing.expectEqual(@as(i32, 0), @intFromEnum(StatusCode.ok));
	try testing.expectEqual(@as(i32, 1), @intFromEnum(StatusCode.generic_error));
	try testing.expectEqual(@as(i32, 2), @intFromEnum(StatusCode.unsupported));
}

test "Status.fromBool" {
	const testing = std.testing;
	try testing.expect(Status.fromBool(true).isOk());
	try testing.expect(!Status.fromBool(false).isOk());
	try testing.expect(Status.fromBool(false).isFatalError());
	try testing.expect(!Status.fromBool(true).isFatalError());
}

test "Status.fromCode" {
	const testing = std.testing;
	try testing.expect(Status.fromCode(.ok).isOk());
	try testing.expect(Status.fromCode(.generic_error).isFatalError());
	try testing.expect(Status.fromCode(.unsupported).isFatalError());
	// not_enough_bytes is non-fatal (negative)
	try testing.expect(!Status.fromCode(.not_enough_bytes).isFatalError());
	try testing.expect(!Status.fromCode(.not_enough_bytes).isOk());
}

test "toError/fromError round-trips" {
	const testing = std.testing;

	// ok -> void (no error)
	try Status.fromCode(.ok).toError();

	// fatal errors round-trip
	const generic = Status.fromCode(.generic_error);
	if (generic.toError()) |_| {
		unreachable;
	} else |err| {
		try testing.expectEqual(generic.code, Status.fromError(err).code);
	}

	const unsupported = Status.fromCode(.unsupported);
	if (unsupported.toError()) |_| {
		unreachable;
	} else |err| {
		try testing.expectEqual(unsupported.code, Status.fromError(err).code);
	}

	const not_enough = Status.fromCode(.not_enough_bytes);
	if (not_enough.toError()) |_| {
		unreachable;
	} else |err| {
		try testing.expectEqual(not_enough.code, Status.fromError(err).code);
	}
}

test "JxlError propagation via try" {
	const helper = struct {
		fn failing() JxlError!void {
			return Status.fromCode(.generic_error).toError();
		}
		fn succeeding() JxlError!void {
			return Status.fromCode(.ok).toError();
		}
	};

	// try on success should not error
	try helper.succeeding();

	// try on failure should propagate
	if (helper.failing()) |_| {
		unreachable;
	} else |err| {
		try std.testing.expectEqual(JxlError.GenericError, err);
	}
}
