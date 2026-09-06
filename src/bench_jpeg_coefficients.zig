const std = @import("std");
const jxl = @import("lib/root.zig");
pub fn main(init: std.process.Init) !void {
	if (@import("builtin").mode != .ReleaseFast) return error.BenchmarkRequiresReleaseFast;
	const args = try init.minimal.args.toSlice(init.arena.allocator());
	if (args.len < 2) return error.ExpectedJxlPath;
	const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .unlimited);
	defer init.gpa.free(data);
	const repeat = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 4;
	var checksum: u64 = 0;
	var count: usize = 0;
	const wall_start = std.Io.Timestamp.now(init.io, .awake).nanoseconds;
	const cpu_start = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds;
	for (0..repeat) |_| {
		var parsed = try jxl.codec.container.extractCodestreamAndBoxes(init.gpa, data);
		defer parsed.deinit(init.gpa);
		var output: ?*jxl.codec.jpeg_reconstruction.Data = null;
		for (parsed.boxes) |*box| if (box.reconstruction) |*jpeg| { output = jpeg; };
		if (output == null) return error.MissingReconstruction;
		var br = jxl.base.bit_reader.BitReader.init(parsed.codestream[2..]);
		var metadata = jxl.codec.image_metadata.CodecMetadata{};
		metadata.size = jxl.codec.headers.SizeHeader.readFromBitStream(&br);
		metadata.m = try jxl.codec.image_metadata.ImageMetadata.readFromBitStream(&br);
		metadata.transform_data = try jxl.codec.image_metadata.CustomTransformData.readFromBitStream(&br, metadata.m.xyb_encoded);
		if (metadata.m.color_encoding.want_icc) return error.UnexpectedICC;
		try br.jumpToByteBoundary();
		var dec = jxl.codec.dec_frame.FrameDecoder.init(init.gpa, &metadata);
		defer dec.deinit();
		dec.jpeg_output = output;
		try dec.decodeFrame(parsed.codestream[2 + br.totalBitsConsumed() / 8 ..]);
		for (output.?.components) |component| {
			count += component.coefficients.len;
			for (component.coefficients) |coefficient| checksum +%= @as(u16, @bitCast(coefficient));
		}
	}
	const cpu = std.Io.Timestamp.now(init.io, .cpu_process).nanoseconds - cpu_start;
	const wall = std.Io.Timestamp.now(init.io, .awake).nanoseconds - wall_start;
	var buffer: [4096]u8 = undefined;
	var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
	try stdout.interface.print("{{\"repeat\":{d},\"coefficients\":{d},\"checksum\":{d},\"cpu_ns\":{d},\"wall_ns\":{d}}}\n", .{repeat,count,checksum,cpu,wall});
	try stdout.interface.flush();
}
