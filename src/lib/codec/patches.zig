//! Entropy-decoded patch dictionaries and ordered Fixed pixel application.
const std = @import("std");
const jxl = @import("../root.zig");
const sf = jxl.base.soft_float;
const ans = jxl.entropy.dec_ans;
const BitReader = jxl.base.bit_reader.BitReader;
const Error = jxl.base.status.JxlError;
pub const blend = @import("blending.zig");
pub const Image = struct { width: usize, height: usize, channels: usize, data: []sf.Fixed };
pub const Reference = struct { image: ?Image = null, pre_color: bool = false };
pub const Patch = struct { ref: u2, sx: usize, sy: usize, width: usize, height: usize, x: usize, y: usize };
fn add(a: usize, b: usize) Error!usize {
	return std.math.add(usize, a, b) catch error.GenericError;
}
fn mul(a: usize, b: usize) Error!usize {
	return std.math.mul(usize, a, b) catch error.GenericError;
}
fn fits(start: usize, size: usize, limit: usize) bool {
	return start <= limit and size <= limit - start;
}
fn offset(base: usize, encoded: usize) Error!usize {
	if (encoded > std.math.maxInt(u32)) return error.GenericError;
	const delta = jxl.base.pack_signed.unpackSigned(@intCast(encoded));
	return if (delta >= 0) add(base, @intCast(delta)) else std.math.sub(usize, base, @abs(delta)) catch error.GenericError;
}
fn validImage(image: Image) Error!void {
	if (image.width == 0 or image.height == 0 or image.channels < 3 or image.channels > 259 or image.data.len != try mul(try mul(image.width, image.height), image.channels)) return error.GenericError;
}
fn overlaps(a: []const sf.Fixed, b: []const sf.Fixed) bool {
	if (a.len == 0 or b.len == 0) return false;
	const x = @intFromPtr(a.ptr);
	const y = @intFromPtr(b.ptr);
	return if (x <= y) y - x < a.len * @sizeOf(sf.Fixed) else x - y < b.len * @sizeOf(sf.Fixed);
}
pub const Dictionary = struct {
	allocator: std.mem.Allocator,
	positions: std.ArrayList(Patch) = .empty,
	blendings: std.ArrayList(blend.Info) = .empty,
	refs: u8 = 0,
	uses_extra: bool = false,
	extra_count: usize = 0,
	width: usize = 0,
	height: usize = 0,
	pub fn deinit(self: *Dictionary) void {
		self.positions.deinit(self.allocator);
		self.blendings.deinit(self.allocator);
		self.positions = .empty;
		self.blendings = .empty;
	}
	pub fn validateSampling(self: *const Dictionary, color: u32, extras: []const u32) Error!void {
		if (self.uses_extra and color != 1) for (extras) |factor| {
			if (factor != color) return error.GenericError;
		};
	}
	pub fn decode(allocator: std.mem.Allocator, br: *BitReader, width: usize, height: usize, extras: usize, references: *const [4]Reference) Error!Dictionary {
		return decodeInner(allocator, br, width, height, extras, references) catch |err| {
			if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
			return err;
		};
	}
	fn decodeInner(allocator: std.mem.Allocator, br: *BitReader, width: usize, height: usize, extras: usize, references: *const [4]Reference) Error!Dictionary {
		if (extras > 256 or width == 0 or height == 0) return error.GenericError;
		const max_refs = try add(1024, (try mul(width, height)) / 4);
		const max_patches = try mul(max_refs, 4);
		const max_blends = try mul(max_patches, 4);
		const stride = extras + 1;
		var result = Dictionary{ .allocator = allocator, .extra_count = extras, .width = width, .height = height };
		errdefer result.deinit();
		var code = ans.ANSCode.init(allocator);
		defer code.deinit();
		const contexts = try ans.decodeHistograms(allocator, br, 10, &code);
		defer allocator.free(contexts);
		var reader = try ans.ANSSymbolReader.create(&code, br, 0, allocator);
		defer reader.deinit();
		const count = reader.readHybridUint(0, br, contexts);
		if (count > max_refs) return error.GenericError;
		for (0..count) |_| {
			const ref = reader.readHybridUint(1, br, contexts);
			if (ref >= 4 or references[ref].image == null or !references[ref].pre_color) return error.GenericError;
			const image = references[ref].image.?;
			try validImage(image);
			if (image.channels != extras + 3) return error.GenericError;
			const sx = reader.readHybridUint(3, br, contexts);
			const sy = reader.readHybridUint(3, br, contexts);
			const w = try add(reader.readHybridUint(2, br, contexts), 1);
			const h = try add(reader.readHybridUint(2, br, contexts), 1);
			if (!fits(sx, w, image.width) or !fits(sy, h, image.height)) return error.GenericError;
			const copies = try add(reader.readHybridUint(7, br, contexts), 1);
			const total = try add(result.positions.items.len, copies);
			if (total > max_patches or try mul(total, stride) > max_blends) return error.GenericError;
			try result.positions.ensureTotalCapacity(allocator, total);
			try result.blendings.ensureTotalCapacity(allocator, try mul(total, stride));
			var x: usize = 0;
			var y: usize = 0;
			for (0..copies) |i| {
				x = if (i == 0) reader.readHybridUint(4, br, contexts) else try offset(x, reader.readHybridUint(6, br, contexts));
				y = if (i == 0) reader.readHybridUint(4, br, contexts) else try offset(y, reader.readHybridUint(6, br, contexts));
				if (!fits(x, w, width) or !fits(y, h, height)) return error.GenericError;
				for (0..stride) |channel| {
					const mode = reader.readHybridUint(5, br, contexts);
					if (mode >= 8) return error.GenericError;
					const alpha = if (mode >= 4 and extras > 1) reader.readHybridUint(8, br, contexts) else 0;
					if (mode >= 4 and extras > 1 and alpha >= extras) return error.GenericError;
					const clamp = if (mode >= 3) reader.readHybridUint(9, br, contexts) != 0 else false;
					result.uses_extra = result.uses_extra or mode >= 4 or (channel > 0 and mode != 0);
					result.blendings.appendAssumeCapacity(.{ .mode = @enumFromInt(mode), .alpha_channel = alpha, .clamp = clamp });
				}
				result.positions.appendAssumeCapacity(.{ .ref = @intCast(ref), .sx = sx, .sy = sy, .width = w, .height = h, .x = x, .y = y });
			}
			result.refs |= @as(u8, 1) << @as(u3, @intCast(ref));
		}
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (!reader.checkANSFinalState()) return error.GenericError;
		return result;
	}
	pub fn apply(self: *const Dictionary, output: Image, references: *const [4]Reference, extras: []const blend.Extra) Error!void {
		try validImage(output);
		if (output.width > self.width or output.height > self.height or extras.len != self.extra_count or output.channels != extras.len + 3) return error.GenericError;
		if (self.blendings.items.len != try mul(self.positions.items.len, extras.len + 1)) return error.GenericError;
		for (self.positions.items) |p| {
			const reference = references[p.ref];
			const image = reference.image orelse return error.GenericError;
			try validImage(image);
			if (!reference.pre_color or image.channels != output.channels or overlaps(image.data, output.data) or !fits(p.sx, p.width, image.width) or !fits(p.sy, p.height, image.height) or !fits(p.x, p.width, self.width) or !fits(p.y, p.height, self.height)) return error.GenericError;
		}
		const storage = try self.allocator.alloc(sf.Fixed, output.channels * 3);
		defer self.allocator.free(storage);
		const bg = storage[0..output.channels];
		const fg = storage[output.channels..][0..output.channels];
		const value = storage[2 * output.channels ..];
		const info = try self.allocator.dupe(blend.Extra, extras);
		defer self.allocator.free(info);
		for (self.positions.items, 0..) |p, index| {
			const image = references[p.ref].image.?;
			const modes = self.blendings.items[index * (extras.len + 1) ..][0 .. extras.len + 1];
			for (info, 0..) |*item, e| item.blend = modes[e + 1];
			for (0..@min(p.height, output.height -| p.y)) |y| for (0..@min(p.width, output.width -| p.x)) |x| {
				for (0..output.channels) |c| {
					bg[c] = output.data[(c * output.height + p.y + y) * output.width + p.x + x];
					fg[c] = image.data[(c * image.height + p.sy + y) * image.width + p.sx + x];
				}
				try blend.pixel(bg, fg, value, modes[0], info);
				for (value, 0..) |v, c| output.data[(c * output.height + p.y + y) * output.width + p.x + x] = v;
			};
		}
	}
};
