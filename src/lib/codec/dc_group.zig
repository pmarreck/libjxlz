//! VarDCT DC coefficient groups decoded through the shared modular codec.
const std = @import("std");
const sf = @import("../base/soft_float.zig");
const BitReader = @import("../base/bit_reader.zig").BitReader;
const JxlError = @import("../base/status.zig").JxlError;
const modular = @import("../modular/modular_image.zig");
const encoding = @import("../modular/encoding.zig");
const ParamsChroma = @import("frame_header.zig").YCbCrChromaSubsampling;
const BlockContextMap = @import("vardct_global.zig").BlockContextMap;
const GlobalEntropy = @import("ac_metadata.zig").GlobalEntropy;
const ModularOptions = @import("../modular/options.zig").ModularOptions;

pub const DecodeParams = struct {
	width: usize,
	height: usize,
	chroma: ParamsChroma = .{},
	bitdepth: i32 = 8,
	stream_id: usize,
	global: GlobalEntropy = .{},
	dc_steps: [3]sf.Fixed,
	cfl: [2]sf.Fixed,
	block_context: *const BlockContextMap,
};

pub const Plane = struct {
	width: usize = 0,
	height: usize = 0,
	samples: []sf.Fixed = &.{},
};

pub const DcGroup = struct {
	allocator: std.mem.Allocator,
	width: usize,
	height: usize,
	planes: [3]Plane = @splat(.{}),
	buckets: []u8 = &.{},

	pub fn deinit(self: *DcGroup) void {
		for (&self.planes) |*plane| {
			self.allocator.free(plane.samples);
			plane.* = .{};
		}
		self.allocator.free(self.buckets);
		self.buckets = &.{};
	}

	pub fn decode(allocator: std.mem.Allocator, br: *BitReader, params: DecodeParams) JxlError!DcGroup {
		return decodeInner(allocator, br, params) catch |err| {
			return if (!br.allReadsWithinBounds()) error.NotEnoughBytes else err;
		};
	}

	fn decodeInner(allocator: std.mem.Allocator, br: *BitReader, params: DecodeParams) JxlError!DcGroup {
		const width = params.width;
		const height = params.height;
		if (width == 0 or height == 0 or width > 256 or height > 256) return error.GenericError;
		// DC group rectangles are padded to complete subsampled blocks.
		for (0..3) |c| {
			const hx = params.chroma.hShift(c);
			const vy = params.chroma.vShift(c);
			if (width % (@as(usize, 1) << @intCast(hx)) != 0 or
				height % (@as(usize, 1) << @intCast(vy)) != 0) return error.GenericError;
		}
		const precision: u2 = @intCast(br.readBits(2));
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		var image = try modular.Image.create(allocator, width, height, params.bitdepth, 0);
		defer image.deinit();
		try image.channels.ensureTotalCapacity(allocator, 3);
		for (0..3) |wire_c| {
			const c = if (wire_c < 2) wire_c ^ 1 else 2;
			image.channels.appendAssumeCapacity(try modular.Channel.create(allocator,
				width >> @intCast(params.chroma.hShift(c)), height >> @intCast(params.chroma.vShift(c)), 0, 0));
		}
		const options = ModularOptions{};
		try encoding.modularGenericDecompress(br, &image, params.stream_id, &options, true,
			params.global.tree, params.global.code, params.global.context_map, allocator);
		if (!br.allReadsWithinBounds()) return error.NotEnoughBytes;
		if (image.channels.items.len != 3) return error.GenericError;
		var result = DcGroup{ .allocator = allocator, .width = width, .height = height };
		errdefer result.deinit();
		for (&result.planes, 0..) |*plane, c| {
			const channel = &image.channels.items[if (c < 2) c ^ 1 else 2];
			plane.width = width >> @intCast(params.chroma.hShift(c));
			plane.height = height >> @intCast(params.chroma.vShift(c));
			if (channel.w != plane.width or channel.h != plane.height) return error.GenericError;
			plane.samples = try allocator.alloc(sf.Fixed, plane.width * plane.height);
			const scale = sf.div(params.dc_steps[c], sf.fromInt(@as(i64, 1) << precision));
			for (0..plane.height) |y| for (channel.rowConst(y), 0..) |value, x| {
				plane.samples[y * plane.width + x] = sf.mul(sf.fromInt(value), scale);
			};
		}
		if (params.chroma.is444()) {
			for (result.planes[1].samples, 0..) |y, i| {
				result.planes[0].samples[i] = sf.add(result.planes[0].samples[i], sf.mul(y, params.cfl[0]));
				result.planes[2].samples[i] = sf.add(result.planes[2].samples[i], sf.mul(y, params.cfl[1]));
			}
		}
		result.buckets = try allocator.alloc(u8, width * height);
		for (0..height) |y| for (0..width) |x| {
			var values: [3]i32 = undefined;
			for (&values, 0..) |*value, c| {
				const channel = &image.channels.items[if (c < 2) c ^ 1 else 2];
				value.* = channel.rowConst(y >> @intCast(params.chroma.vShift(c)))[x >> @intCast(params.chroma.hShift(c))];
			}
			result.buckets[y * width + x] = @intCast(params.block_context.dcBucket(values));
		};
		return result;
	}
};
