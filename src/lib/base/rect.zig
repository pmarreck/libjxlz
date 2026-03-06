const std = @import("std");
const common = @import("common.zig");

/// Rectangular region in image(s), matching C++ jxl::Rect.
pub const Rect = struct {
	x0_: usize,
	y0_: usize,
	xsize_: usize,
	ysize_: usize,

	/// Construct with origin and size.
	pub fn init(xbegin: usize, ybegin: usize, xs: usize, ys: usize) Rect {
		return .{ .x0_ = xbegin, .y0_ = ybegin, .xsize_ = xs, .ysize_ = ys };
	}

	/// Construct clamped to [0, xend) x [0, yend).
	pub fn initClamped(xbegin: usize, ybegin: usize, xs_max: usize, ys_max: usize, xend: usize, yend: usize) Rect {
		return .{
			.x0_ = xbegin,
			.y0_ = ybegin,
			.xsize_ = clampedSize(xbegin, xs_max, xend),
			.ysize_ = clampedSize(ybegin, ys_max, yend),
		};
	}

	/// Empty (zero-size) rect.
	pub fn empty() Rect {
		return .{ .x0_ = 0, .y0_ = 0, .xsize_ = 0, .ysize_ = 0 };
	}

	pub fn x0(self: Rect) usize {
		return self.x0_;
	}
	pub fn y0(self: Rect) usize {
		return self.y0_;
	}
	pub fn xsize(self: Rect) usize {
		return self.xsize_;
	}
	pub fn ysize(self: Rect) usize {
		return self.ysize_;
	}
	pub fn x1(self: Rect) usize {
		return self.x0_ + self.xsize_;
	}
	pub fn y1(self: Rect) usize {
		return self.y0_ + self.ysize_;
	}

	/// Returns the intersection of two rects.
	pub fn intersection(self: Rect, other: Rect) Rect {
		const new_x0 = @max(self.x0_, other.x0_);
		const new_y0 = @max(self.y0_, other.y0_);
		const new_x1 = @min(self.x1(), other.x1());
		const new_y1 = @min(self.y1(), other.y1());
		return .{
			.x0_ = new_x0,
			.y0_ = new_y0,
			.xsize_ = if (new_x1 > new_x0) new_x1 - new_x0 else 0,
			.ysize_ = if (new_y1 > new_y0) new_y1 - new_y0 else 0,
		};
	}

	/// Translate by signed offsets.
	pub fn translate(self: Rect, x_offset: i64, y_offset: i64) Rect {
		return .{
			.x0_ = @intCast(@as(i64, @intCast(self.x0_)) + x_offset),
			.y0_ = @intCast(@as(i64, @intCast(self.y0_)) + y_offset),
			.xsize_ = self.xsize_,
			.ysize_ = self.ysize_,
		};
	}

	/// Returns true if self is entirely inside other.
	pub fn isInside(self: Rect, other: Rect) bool {
		return self.x0_ >= other.x0_ and self.x1() <= other.x1() and
			self.y0_ >= other.y0_ and self.y1() <= other.y1();
	}

	/// Shift coordinates and sizes left.
	pub fn shiftLeft(self: Rect, shiftx: u6, shifty: u6) Rect {
		return .{
			.x0_ = self.x0_ << shiftx,
			.y0_ = self.y0_ << shifty,
			.xsize_ = self.xsize_ << shiftx,
			.ysize_ = self.ysize_ << shifty,
		};
	}

	/// Shift right with ceiling division for sizes. Origin must be aligned.
	pub fn ceilShiftRight(self: Rect, shiftx: u6, shifty: u6) error{AlignmentError}!Rect {
		const xdiv = @as(usize, 1) << shiftx;
		const ydiv = @as(usize, 1) << shifty;
		if (self.x0_ % xdiv != 0 or self.y0_ % ydiv != 0) {
			return error.AlignmentError;
		}
		return .{
			.x0_ = self.x0_ >> shiftx,
			.y0_ = self.y0_ >> shifty,
			.xsize_ = common.divCeil(self.xsize_, xdiv),
			.ysize_ = common.divCeil(self.ysize_, ydiv),
		};
	}

	fn clampedSize(begin: usize, size_max: usize, end: usize) usize {
		if (begin + size_max <= end) return size_max;
		return if (end > begin) end - begin else 0;
	}
};

test "construction and accessors" {
	const r = Rect.init(10, 20, 30, 40);
	try std.testing.expectEqual(@as(usize, 10), r.x0());
	try std.testing.expectEqual(@as(usize, 20), r.y0());
	try std.testing.expectEqual(@as(usize, 30), r.xsize());
	try std.testing.expectEqual(@as(usize, 40), r.ysize());
	try std.testing.expectEqual(@as(usize, 40), r.x1());
	try std.testing.expectEqual(@as(usize, 60), r.y1());
}

test "empty rect" {
	const r = Rect.empty();
	try std.testing.expectEqual(@as(usize, 0), r.xsize());
	try std.testing.expectEqual(@as(usize, 0), r.ysize());
}

test "clamped construction" {
	// Window fully inside bounds
	const r1 = Rect.initClamped(0, 0, 8, 8, 100, 100);
	try std.testing.expectEqual(@as(usize, 8), r1.xsize());
	try std.testing.expectEqual(@as(usize, 8), r1.ysize());

	// Window exceeds bounds — clamped
	const r2 = Rect.initClamped(95, 95, 8, 8, 100, 100);
	try std.testing.expectEqual(@as(usize, 5), r2.xsize());
	try std.testing.expectEqual(@as(usize, 5), r2.ysize());

	// Begin beyond end
	const r3 = Rect.initClamped(200, 200, 8, 8, 100, 100);
	try std.testing.expectEqual(@as(usize, 0), r3.xsize());
	try std.testing.expectEqual(@as(usize, 0), r3.ysize());
}

test "intersection of overlapping rects" {
	const a = Rect.init(0, 0, 10, 10);
	const b = Rect.init(5, 5, 10, 10);
	const c = a.intersection(b);
	try std.testing.expectEqual(@as(usize, 5), c.x0());
	try std.testing.expectEqual(@as(usize, 5), c.y0());
	try std.testing.expectEqual(@as(usize, 5), c.xsize());
	try std.testing.expectEqual(@as(usize, 5), c.ysize());
}

test "intersection of non-overlapping rects" {
	const a = Rect.init(0, 0, 5, 5);
	const b = Rect.init(10, 10, 5, 5);
	const c = a.intersection(b);
	try std.testing.expectEqual(@as(usize, 0), c.xsize());
	try std.testing.expectEqual(@as(usize, 0), c.ysize());
}

test "isInside" {
	const outer = Rect.init(0, 0, 100, 100);
	const inner = Rect.init(10, 10, 20, 20);
	try std.testing.expect(inner.isInside(outer));
	try std.testing.expect(!outer.isInside(inner));
	try std.testing.expect(outer.isInside(outer));
}

test "shiftLeft" {
	const r = Rect.init(1, 2, 3, 4);
	const shifted = r.shiftLeft(1, 2);
	try std.testing.expectEqual(@as(usize, 2), shifted.x0());
	try std.testing.expectEqual(@as(usize, 8), shifted.y0());
	try std.testing.expectEqual(@as(usize, 6), shifted.xsize());
	try std.testing.expectEqual(@as(usize, 16), shifted.ysize());
}

test "translate" {
	const r = Rect.init(10, 20, 5, 5);
	const t = r.translate(3, -5);
	try std.testing.expectEqual(@as(usize, 13), t.x0());
	try std.testing.expectEqual(@as(usize, 15), t.y0());
	try std.testing.expectEqual(@as(usize, 5), t.xsize());
}

test "ceilShiftRight" {
	const r = Rect.init(8, 16, 10, 20);
	const shifted = try r.ceilShiftRight(3, 4);
	try std.testing.expectEqual(@as(usize, 1), shifted.x0());
	try std.testing.expectEqual(@as(usize, 1), shifted.y0());
	// divCeil(10, 8) = 2, divCeil(20, 16) = 2
	try std.testing.expectEqual(@as(usize, 2), shifted.xsize());
	try std.testing.expectEqual(@as(usize, 2), shifted.ysize());
}

test "ceilShiftRight alignment error" {
	const r = Rect.init(3, 0, 10, 10);
	const result = r.ceilShiftRight(2, 0);
	try std.testing.expectError(error.AlignmentError, result);
}
