const std = @import("std");
const voronoi = @import("voronoi.zig");
const clap = @import("clap");
const c = @import("c");

const pixel_components = 3;

fn eglCheck(ok: c.EGLBoolean) !void {
    if (ok != c.EGL_TRUE) return error.EglError;
}

fn glCheck(id: anytype) !void {
    if (id < 1) return error.GlError;
}

fn checkGlError() !void {
    return switch (c.glGetError()) {
        c.GL_NO_ERROR => {},
        c.GL_INVALID_ENUM => error.GlInvalidEnum,
        c.GL_INVALID_VALUE => error.GlInvalidValue,
        c.GL_INVALID_OPERATION => error.GlInvalidOperation,
        c.GL_INVALID_FRAMEBUFFER_OPERATION => error.GlInvalidFramebufferOperation,
        c.GL_OUT_OF_MEMORY => error.GlOutOfMemory,
        c.GL_STACK_UNDERFLOW => error.GlStackUnderflow,
        c.GL_STACK_OVERFLOW => error.GlStackOverflow,
        else => error.GlUnknown,
    };
}

const Centroid = struct {
    x: f32,
    y: f32,
};

const Image = struct {
    width: u32,
    height: u32,
    buffer: []u8,

    const png_magic = [_]u8{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    const jpeg_magic = [_]u8{0xFF, 0xD8, 0xFF};

    fn checkPng(png: c.png_image) !void {
        if (png.warning_or_error != 0) {
            const msg: [*:0]const u8 = @ptrCast(&png.message);
            std.log.err("PNG Error: {s}\n", .{msg});
            return error.PngError;
        }
    }

    fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
        const memory = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        defer allocator.free(memory);

        if (std.mem.startsWith(u8, memory, &png_magic))
            return readPng(allocator, memory);
        if (std.mem.startsWith(u8, memory, &jpeg_magic))
            return readJpeg(allocator, memory);

        return error.UnsupportedImageFormat;
    }

    fn readJpeg(allocator: std.mem.Allocator, memory: []const u8) !Image {
        var info: c.jpeg_decompress_struct = undefined;
        var err: c.jpeg_error_mgr = undefined;

        info.err = c.jpeg_std_error(&err);
        c.jpeg_create_decompress(&info);
        defer c.jpeg_destroy_decompress(&info);

        c.jpeg_mem_src(&info, memory.ptr, memory.len);
        _ = c.jpeg_read_header(&info, 1);

        info.out_color_space = c.JCS_RGB;
        _ = c.jpeg_start_decompress(&info);
        defer _ = c.jpeg_finish_decompress(&info);

        const stride = info.output_width * @as(usize, @intCast(info.output_components));
        const row_buffer = if (info.mem.*.alloc_sarray) |alloc_fn|
            alloc_fn(@ptrCast(&info), c.JPOOL_IMAGE, @intCast(stride), 1)
        else
            return error.JpegError;

        std.debug.assert(info.output_components == pixel_components);
        const buffer = try allocator.alloc(u8, pixel_components * info.output_width * info.output_height);

        while (info.output_scanline < info.output_height) {
            const r = info.output_scanline;
            _ = c.jpeg_read_scanlines(&info, row_buffer, 1);
            @memcpy(buffer[r * stride..(r + 1) * stride], row_buffer[0]);
        }

        return .{
            .width = info.output_width,
            .height = info.output_height,
            .buffer = buffer,
        };
    }

    fn readPng(allocator: std.mem.Allocator, memory: []const u8) !Image {
        var png = std.mem.zeroInit(c.png_image, .{ .version = c.PNG_IMAGE_VERSION });
        defer c.png_image_free(&png);

        _ = c.png_image_begin_read_from_memory(&png, memory.ptr, memory.len);
        try checkPng(png);
        png.format = c.PNG_FORMAT_RGB;
        const buffer = try allocator.alloc(u8, pixel_components * png.width * png.height);

        _ = c.png_image_finish_read(&png, null, buffer.ptr, 0, null);
        try checkPng(png);

        return .{
            .width = png.width,
            .height = png.height,
            .buffer = buffer,
        };
    }

    fn write(self: Image, path: [:0]const u8) !void {
        var png = std.mem.zeroInit(c.png_image, .{
            .version = c.PNG_IMAGE_VERSION,
            .width = self.width,
            .height = self.height,
            .flags = c.PNG_IMAGE_FLAG_FAST,
            .format = c.PNG_FORMAT_RGB,
        });

        _ = c.png_image_write_to_file(&png, path, 1, self.buffer.ptr, 0, null);
        try checkPng(png);
    }

    fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

fn PtrZigFromC(T: type) type {
    const info = @typeInfo(T).pointer;
    const attrs: std.builtin.Type.Pointer.Attributes = .{
        .@"const" = info.is_const,
        .@"volatile" = info.is_volatile,
        .@"addrspace" = info.address_space,
        .@"align" = info.alignment,
    };
    return @Pointer(.one, attrs, info.child, null);
}

fn checkPtr(ptr: anytype) !PtrZigFromC(@TypeOf(ptr)) {
    if (ptr == 0)
        return error.NullPointer;
    return @ptrCast(ptr);
}

fn check(x: anytype) !void {
    if (x != 0) return error.RuntimeException;
}

fn checkNeg(x: anytype) !@TypeOf(x) {
    if (x < 0) return error.RuntimeException;
    return x;
}

const FramePool = struct {
    lock: std.Io.Mutex = .init,
    free_list: std.SinglyLinkedList = .{},

    fn deinit(self: *FramePool) void {
        var node = self.free_list.first;

        while (node) |n| {
            var frame: *c.AVFrame = @fieldParentPtr("opaque", @as(*?*anyopaque, @ptrCast(n)));
            c.av_frame_free(@ptrCast(&frame));
            node = n.next;
        }

        self.* = .{};
    }

    fn create(self: *FramePool, io: std.Io) !*c.AVFrame {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        if (self.free_list.popFirst()) |node|
            return @fieldParentPtr("opaque", @as(*?*anyopaque, @ptrCast(node)));

        const ptr = c.av_frame_alloc();
        if (ptr == 0) return error.OutOfMemory;
        return @ptrCast(ptr);
    }

    fn destroy(self: *FramePool, io: std.Io, frame: *c.AVFrame) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        c.av_frame_unref(frame);
        self.free_list.prepend(@ptrCast(&frame.@"opaque"));
    }
};

fn OneTimeChannel(T: type) type {
    return struct {
        value: T = undefined,
        ready: std.Io.Event = .unset,

        fn send(self: *@This(), io: std.Io, value: T) void {
            self.value = value;
            self.ready.set(io);
        }

        fn recv(self: *@This(), io: std.Io) T {
            self.ready.waitUncancelable(io);
            return self.value;
        }
    };
}

const LockedWriter = struct {
    writer: std.Io.File.Writer,
    lock: std.Io.Mutex = .init,

    fn init(io: std.Io, allocator: std.mem.Allocator) !LockedWriter {
        return .{
            .writer = std.Io.File.stdout().writer(io, try allocator.alloc(u8, 4096)),
        };
    }

    fn deinit(self: LockedWriter, allocator: std.mem.Allocator) void {
        allocator.free(self.writer.interface.buffer);
    }

    fn print(self: *LockedWriter, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        return self.writer.interface.print(fmt, args);
    }
};

const CodecInfo = struct {
    id: c.AVCodecID,
    width: i32,
    height: i32,
    framerate: c.AVRational,

    fn init(stream: *const c.AVStream) CodecInfo {
        return .{
            .id = stream.codecpar.*.codec_id,
            .width = @intCast(stream.codecpar.*.width),
            .height = @intCast(stream.codecpar.*.height),
            .framerate = stream.avg_frame_rate,
        };
    }
};

const VideoProcessor = struct {
    in_path: [:0]const u8,
    out_path: [:0]const u8,
    k: usize,
    s_ch: f64,
    allocator: std.mem.Allocator,
    frame_pool: FramePool = .{},
    input_queue: std.Io.Queue(*c.AVFrame),
    output_queue: std.Io.Queue(*c.AVFrame),
    codec_info: OneTimeChannel(CodecInfo) = .{},
    start: std.Io.Timestamp = undefined,
    stdout: LockedWriter,

    fn init(io: std.Io, allocator: std.mem.Allocator, in_path: [:0]const u8, out_path: [:0]const u8, k: usize, s_ch: f64) !VideoProcessor {
        return .{
            .in_path = in_path,
            .out_path = out_path,
            .k = k,
            .s_ch = s_ch,
            .allocator = allocator,
            .input_queue = .init(try allocator.alloc(*c.AVFrame, 128)),
            .output_queue = .init(try allocator.alloc(*c.AVFrame, 128)),
            .stdout = try .init(io, allocator)
        };
    }

    fn deinit(self: *VideoProcessor) void {
        const input_buffer: []*c.AVFrame = @alignCast(@ptrCast(self.input_queue.type_erased.buffer));
        const output_buffer: []*c.AVFrame = @alignCast(@ptrCast(self.output_queue.type_erased.buffer));

        std.debug.assert(self.input_queue.type_erased.len == 0);
        std.debug.assert(self.output_queue.type_erased.len == 0);
        self.allocator.free(input_buffer);
        self.allocator.free(output_buffer);
        self.frame_pool.deinit();
        self.stdout.deinit(self.allocator);
    }

    fn run(self: *VideoProcessor, io: std.Io) !void {
        self.start = .now(io, .boot);
        const encoder_thread = try std.Thread.spawn(.{}, encoder, .{self, io});
        const decoder_thread = try std.Thread.spawn(.{}, decoder, .{self, io});

        try self.processor(io);

        encoder_thread.join();
        decoder_thread.join();

        try self.stdout.writer.end();
    }

    fn logInfo(self: *VideoProcessor, io: std.Io) !void {
        const timestamp = self.start.untilNow(io, .boot).toMicroseconds();
        const in_len = @divExact(self.input_queue.type_erased.len, @sizeOf(*anyopaque));
        const out_len = @divExact(self.output_queue.type_erased.len, @sizeOf(*anyopaque));
        return self.stdout.print(io, "{} {} {}\n", .{timestamp, in_len, out_len});
    }

    fn encodeAndWrite(fmt_context: *c.AVFormatContext, codec_context: *c.AVCodecContext, stream: *c.AVStream, frame: ?*c.AVFrame, packet: *c.AVPacket) !void {
        _ = try checkNeg(c.avcodec_send_frame(codec_context, frame));

        while (true) {
            const response = c.avcodec_receive_packet(codec_context, packet);
            if (response == c.AVERROR(c.EAGAIN) or response == c.AVERROR_EOF)
                break;
            _ = try checkNeg(response);

            c.av_packet_rescale_ts(packet, codec_context.time_base, stream.time_base);
            packet.stream_index = stream.index;

            _ = try checkNeg(c.av_interleaved_write_frame(fmt_context, packet));
            c.av_packet_unref(packet);
        }
    }

    fn encoder(self: *VideoProcessor, io: std.Io) !void {
        var fmt_context: *c.AVFormatContext = undefined;
        defer c.avformat_free_context(fmt_context);
        _ = try checkNeg(c.avformat_alloc_output_context2(@ptrCast(&fmt_context), null, null, self.out_path));

        const codec_info = self.codec_info.recv(io);
        const codec: *c.AVCodec = try checkPtr(c.avcodec_find_encoder(codec_info.id));
        const stream: *c.AVStream = try checkPtr(c.avformat_new_stream(fmt_context, null));
        var codec_context: *c.AVCodecContext = try checkPtr(c.avcodec_alloc_context3(codec));
        defer c.avcodec_free_context(@ptrCast(&codec_context));
        const sws_context = c.sws_getContext(codec_info.width, codec_info.height, c.AV_PIX_FMT_RGB24, codec_info.width, codec_info.height, c.AV_PIX_FMT_YUV420P, c.SWS_BICUBIC, null, null, null).?;
        defer c.sws_freeContext(sws_context);
        var packet = try checkPtr(c.av_packet_alloc());
        defer c.av_packet_free(@ptrCast(&packet));
        const frame = try self.frame_pool.create(io);
        defer self.frame_pool.destroy(io, frame);

        codec_context.width = codec_info.width;
        codec_context.height = codec_info.height;
        codec_context.pix_fmt = c.AV_PIX_FMT_YUV420P;
        codec_context.bit_rate = 4 * 1024 * 1024;
        codec_context.gop_size = 240;
        codec_context.time_base = if (codec_info.framerate.num != 0)
            c.av_inv_q(codec_info.framerate)
        else
            .{ .num = 1, .den = 24 };

        if (fmt_context.oformat.*.flags & c.AVFMT_GLOBALHEADER != 0)
            codec_context.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;

        frame.format = codec_context.pix_fmt;
        frame.width = codec_info.width;
        frame.height = codec_info.height;

        _ = try checkNeg(c.av_frame_get_buffer(frame, 0));
        _ = try checkNeg(c.avcodec_open2(codec_context, codec, null));
        _ = try checkNeg(c.avcodec_parameters_from_context(stream.codecpar, codec_context));

        const open_file = fmt_context.oformat.*.flags & c.AVFMT_NOFILE == 0;
        if (open_file)
            _ = try checkNeg(c.avio_open(&fmt_context.pb, self.out_path, c.AVIO_FLAG_WRITE));
        defer if (open_file) {
            _ = c.avio_closep(&fmt_context.pb);
        };

        try check(c.avformat_write_header(fmt_context, null));

        var pts: i64 = 0;
        while (true) : (pts += 1) {
            const frame_rgb = self.output_queue.getOneUncancelable(io) catch break;
            defer {
                c.av_free(frame_rgb.data[0]);
                self.frame_pool.destroy(io, frame_rgb);
            }

            try self.logInfo(io);
            try check(c.av_frame_make_writable(frame));
            _ = try checkNeg(c.sws_scale(sws_context, &frame_rgb.data, &frame_rgb.linesize, 0, codec_info.height, &frame.data, &frame.linesize));
            frame.pts = pts;
            try encodeAndWrite(fmt_context, codec_context, stream, frame, packet);
        }

        try encodeAndWrite(fmt_context, codec_context, stream, null, packet);
        try check(c.av_write_trailer(fmt_context));
    }

    fn processor(self: *VideoProcessor, io: std.Io) !void {
        const codec_info = self.codec_info.recv(io);
        var gl = try Gl.init(self.allocator, @intCast(codec_info.width), @intCast(codec_info.height));
        defer gl.deinit();

        const centroids = try self.allocator.alloc(Centroid, self.k);
        defer self.allocator.free(centroids);

        var rng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(io, .boot).toMilliseconds()));
        const random = rng.random();

        for (centroids) |*e| {
            e.x = random.float(f32);
            e.y = random.float(f32);
        }

        const s_ch: f32 = @floatCast(self.s_ch);

        var i: usize = 0;
        while (true) : (i += 1) {
            const frame = self.input_queue.getOneUncancelable(io) catch break;
            try self.logInfo(io);
            const len = @intFromPtr(frame.@"opaque");
            const slice: []u8 = frame.data[0][0..len];
            const stride = try std.math.divExact(u32, @intCast(frame.linesize[0]), pixel_components);
            gl.inputImage(slice, stride);
            try gl.compute(centroids, s_ch);
            try gl.writeToImage(slice, stride);
            try self.output_queue.putOneUncancelable(io, frame);
            try self.logInfo(io);
        }
        
        self.output_queue.close(io);
    }

    fn decoder(self: *VideoProcessor, io: std.Io) !void {
        var fmt_context: *c.AVFormatContext = try checkPtr(c.avformat_alloc_context());
        defer c.avformat_close_input(@ptrCast(&fmt_context));
        try check(c.avformat_open_input(@ptrCast(&fmt_context), self.in_path, 0, 0));
        std.log.info("{s}", .{fmt_context.iformat.*.long_name});

        _ = try checkNeg(c.avformat_find_stream_info(fmt_context, 0));

        var codec_context, const video_stream_index = blk: {
            var codec: *c.AVCodec = undefined;
            var codec_params: *c.AVCodecParameters = undefined;
            var video_stream_index: ?usize = null;

            for (0..fmt_context.nb_streams) |i| {
                const local_params = fmt_context.streams[i].*.codecpar;
                if (local_params.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                    const local_codec = c.avcodec_find_decoder(local_params.*.codec_id);

                    if (local_codec == 0) {
                        std.log.warn("Found an unsupported codec", .{});
                        continue;
                    }

                    if (video_stream_index == null) {
                        video_stream_index = i;
                        codec = local_codec;
                        codec_params = local_params;
                    }
                    else {
                        std.log.warn("Found multiple video streams", .{});
                    }
                }
                else {
                    std.log.info("Found other stream", .{});
                }
            }

            const context: *c.AVCodecContext = try checkPtr(c.avcodec_alloc_context3(codec));

            _ = try checkNeg(c.avcodec_parameters_to_context(context, codec_params));
            _ = try checkNeg(c.avcodec_open2(context, codec, 0));

            std.log.info("Codec: {s}", .{codec.*.long_name});
            std.log.info("Type: {}", .{codec.*.@"type"});

            break :blk .{ context, video_stream_index.? };
        };
        defer c.avcodec_free_context(@ptrCast(&codec_context));

        self.codec_info.send(io, .init(@ptrCast(fmt_context.streams[video_stream_index])));

        const sws_context = c.sws_getContext(codec_context.width, codec_context.height, codec_context.pix_fmt, codec_context.width, codec_context.height, c.AV_PIX_FMT_RGB24, c.SWS_BILINEAR, 0, 0, 0).?;
        defer c.sws_freeContext(sws_context);
        var packet = try checkPtr(c.av_packet_alloc());
        defer c.av_packet_free(@ptrCast(&packet));
        const frame = try self.frame_pool.create(io);
        defer self.frame_pool.destroy(io, frame);
        var i: usize = 0;

        while (c.av_read_frame(fmt_context, packet) >= 0) {
            if (packet.stream_index == video_stream_index) {
                _ = try checkNeg(c.avcodec_send_packet(codec_context, packet));

                while (true) {
                    const response = c.avcodec_receive_frame(codec_context, frame);
                    if (response == c.AVERROR(c.EAGAIN) or response == c.AVERROR_EOF)
                        break;
                    _ = try checkNeg(response);

                    i += 1;

                    var frame_rgb = try self.frame_pool.create(io);
                    const frame_size: usize = @intCast(c.av_image_get_buffer_size(c.AV_PIX_FMT_RGB24, codec_context.width, codec_context.height, 1));
                    const frame_buffer: [*]u8 = @ptrCast(c.av_malloc(frame_size));

                    frame_rgb.width = codec_context.width;
                    frame_rgb.height = codec_context.height;
                    frame_rgb.@"opaque" = @ptrFromInt(frame_size);

                    _ = try checkNeg(c.av_image_fill_arrays(&frame_rgb.data, &frame_rgb.linesize, frame_buffer, c.AV_PIX_FMT_RGB24, frame_rgb.width, frame_rgb.height, 1));
                    _ = try checkNeg(c.sws_scale(sws_context, &frame.data, &frame.linesize, 0, codec_context.height, &frame_rgb.data, &frame_rgb.linesize));

                    try self.input_queue.putOneUncancelable(io, frame_rgb);
                    try self.logInfo(io);
                }
            }

            c.av_packet_unref(packet);
        }

        self.input_queue.close(io);
    }
};

const Egl = struct {
    display: c.EGLDisplay,
    context: c.EGLContext,

    fn init() !Egl {
        const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
        try eglCheck(c.eglInitialize(display, null, null));

        var config: c.EGLConfig = undefined;
        var config_count: c.EGLint = undefined;
        const attrs = [_]c.EGLint{ c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT, c.EGL_NONE };
        try eglCheck(c.eglChooseConfig(display, &attrs, &config, 1, &config_count));

        try eglCheck(c.eglBindAPI(c.EGL_OPENGL_API));

        const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, null);
        try eglCheck(c.eglMakeCurrent(display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, context));

        return .{
            .display = display,
            .context = context,
        };
    }

    fn denit(self: Egl) !void {
        try eglCheck(c.eglDestroyContext(self.display, self.context));
        try eglCheck(c.eglTerminate(self.display));
    }
};

const Gl = struct {
    src_texture: u32,
    dst_texture: u32,
    shader_buffer: u32,

    shader: u32,
    program: u32,

    count_handle: i32,
    s_ch_handle: i32,

    width: u32,
    height: u32,

    fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Gl {
        var src_texture: u32 = undefined;
        var dst_texture: u32 = undefined;

        var shader_buffer: u32 = undefined;

        c.glCreateTextures(c.GL_TEXTURE_2D, 1, &src_texture);
        c.glCreateTextures(c.GL_TEXTURE_2D, 1, &dst_texture);
        c.glGenBuffers(1, &shader_buffer);

        try glCheck(src_texture);
        try glCheck(dst_texture);

        c.glTextureStorage2D(src_texture, 1, c.GL_RGBA8, @intCast(width), @intCast(height));

        c.glTextureStorage2D(dst_texture, 1, c.GL_RGBA8, @intCast(width), @intCast(height));
        const color = [_]u8{255} ** 4;
        c.glClearTexImage(dst_texture, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &color);

        c.glBindImageTexture(src_texture_index, src_texture, 0, 0, 0, c.GL_READ_ONLY, c.GL_RGBA8);
        try checkGlError();
        c.glBindImageTexture(dst_texture_index, dst_texture, 0, 0, 0, c.GL_WRITE_ONLY, c.GL_RGBA8);
        try checkGlError();
        c.glBindBufferBase(c.GL_SHADER_STORAGE_BUFFER, shader_buffer_index, shader_buffer);
        c.glBindBuffer(c.GL_SHADER_STORAGE_BUFFER, shader_buffer);

        const shader = c.glCreateShader(c.GL_COMPUTE_SHADER);
        const program = c.glCreateProgram();

        try glCheck(shader);
        try glCheck(program);

        const shader_source: [*:0]const u8 = @embedFile("shader").ptr;
        var success: i32 = undefined;

        c.glShaderSource(shader, 1, &shader_source, null);
        c.glCompileShader(shader);
        c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &success);

        if (success == c.GL_FALSE) {
            var max_len: i32 = undefined;
            c.glGetShaderiv(shader, c.GL_INFO_LOG_LENGTH, &max_len);

            if (max_len > 0) {
                var msg_len: i32 = undefined;
                const msg_buffer = try allocator.alloc(u8, @intCast(max_len));
                defer allocator.free(msg_buffer);

                c.glGetShaderInfoLog(shader, max_len, &msg_len, msg_buffer.ptr);
                std.log.err("{s}", .{msg_buffer[0..@intCast(msg_len)]});
            }

            return error.GlCompileError;
        }

        c.glAttachShader(program, shader);
        c.glLinkProgram(program);
        c.glGetProgramiv(program, c.GL_LINK_STATUS, &success);

        if (success == c.GL_FALSE) {
            var max_len: i32 = undefined;
            c.glGetProgramiv(program, c.GL_INFO_LOG_LENGTH, &max_len);

            if (max_len > 0) {
                var msg_len: i32 = undefined;
                const msg_buffer = try allocator.alloc(u8, @intCast(max_len));
                defer allocator.free(msg_buffer);

                c.glGetProgramInfoLog(program, max_len, &msg_len, msg_buffer.ptr);
                std.log.err("{s}", .{msg_buffer[0..@intCast(msg_len)]});
            }

            return error.GlLinkError;
        }

        const count_handle = c.glGetUniformLocation(program, "count");
        const s_ch_handle = c.glGetUniformLocation(program, "chromatic_scale");

        try glCheck(count_handle);
        try glCheck(s_ch_handle);

        try checkGlError();

        return .{
            .src_texture = src_texture,
            .dst_texture = dst_texture,
            .shader_buffer = shader_buffer,
            .shader = shader,
            .program = program,
            .count_handle = count_handle,
            .s_ch_handle = s_ch_handle,
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: *Gl) void {
        c.glDeleteTextures(1, &self.src_texture);
        c.glDeleteTextures(1, &self.dst_texture);
        c.glDeleteBuffers(1, &self.shader_buffer);
        c.glDeleteShader(self.shader);
        c.glDeleteProgram(self.program);
    }

    fn inputImage(self: *Gl, image_data: []u8, stride: u32) void {
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(stride));
        c.glTextureSubImage2D(self.src_texture, 0, 0, 0, @intCast(self.width), @intCast(self.height), c.GL_RGB, c.GL_UNSIGNED_BYTE, image_data.ptr);
    }

    fn compute(self: Gl, centroids: []Centroid, chromatic_scale: f32) !void {
        c.glBufferData(c.GL_SHADER_STORAGE_BUFFER, @intCast(centroids.len * @sizeOf(Centroid)), centroids.ptr, c.GL_DYNAMIC_DRAW);
        c.glUseProgram(self.program);
        c.glUniform1ui(self.count_handle, @intCast(centroids.len));
        c.glUniform1f(self.s_ch_handle, chromatic_scale);
        c.glDispatchCompute(@divTrunc(self.width + 15, 16), @divTrunc(self.height + 15, 16), 1);
        c.glMemoryBarrier(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | c.GL_BUFFER_UPDATE_BARRIER_BIT);

        try checkGlError();
    }

    fn writeToImage(self: Gl, image_data: []u8, stride: u32) !void {
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, @intCast(stride));
        c.glGetTextureImage(self.dst_texture, 0, c.GL_RGB, c.GL_UNSIGNED_BYTE, @intCast(image_data.len), image_data.ptr);

        try checkGlError();
    }
};

const src_texture_index = 0;
const dst_texture_index = 1;
const shader_buffer_index = 2;

const args_message =
        \\-h, --help                    Display this help and exit
        \\-k, --centroids <INT>         Number of centroids
        \\-s, --chromatic_scale <FLOAT> Chromatic scale
        \\<PATH>                        Source path
        \\<PATH>                        Destination path
;

const Timer = struct {
    name: []const u8,
    start: std.Io.Timestamp,

    fn begin(io: std.Io, name: []const u8) Timer {
        return .{
            .name = name,
            .start = .now(io, .boot),
        };
    }

    fn stop(self: Timer, io: std.Io) void {
        const elapsed = self.start.untilNow(io, .boot);
        std.log.info("{s}: {} ms", .{self.name, elapsed.toMilliseconds()});
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const overall = Timer.begin(init.io, "overall");

    const params = comptime clap.parseParamsComptime(args_message);
    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .INT = clap.parsers.int(usize, 10),
        .FLOAT = clap.parsers.float(f64),
    };

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, &args_iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .assignment_separators = "=:",
    }) catch |err| {
        var writer = std.Io.File.stdout().writer(init.io, &.{});
        try diag.report(&writer.interface, err);
        try writer.end();
        return err;
    };

    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{args_message});
        return;
    }

    const k = res.args.centroids orelse 11;

    const initialize = Timer.begin(init.io, "init");
    const egl = try Egl.init();

    if (c.gladLoadGL() == 0)
        return error.GlLoadError;

    const src_path = try allocator.dupeZ(u8, res.positionals[0] orelse return error.PathMissing);
    const dst_path = try allocator.dupeZ(u8, res.positionals[1] orelse return error.PathMissing);

    const image = Image.read(init.gpa, init.io, src_path) catch {
        var processor = try VideoProcessor.init(init.io, init.gpa, src_path, dst_path, k, 1.5);
        defer processor.deinit();
        try processor.run(init.io);
        return;
    };
    defer image.deinit(init.gpa);

    var gl = try Gl.init(init.gpa, @intCast(image.width), @intCast(image.height));
    defer gl.deinit();

    gl.inputImage(image.buffer, 0);

    const s_ch = res.args.chromatic_scale orelse voronoi.suggestChromaticScale(voronoi.PixelRgb, @ptrCast(image.buffer));

    const centroids = try allocator.alloc(Centroid, k);

    var rng = std.Random.DefaultPrng.init(@bitCast(std.Io.Timestamp.now(init.io, .boot).toMilliseconds()));
    const random = rng.random();

    for (centroids) |*e| {
        e.x = random.float(f32);
        e.y = random.float(f32);
    }

    std.log.info("k = {}, s_ch = {}", .{k, s_ch});
    initialize.stop(init.io);

    const compute = Timer.begin(init.io, "compute");
    try gl.compute(centroids, @floatCast(s_ch));
    try gl.writeToImage(image.buffer, 0);
    compute.stop(init.io);

    const write = Timer.begin(init.io, "write");
    try image.write(dst_path);
    write.stop(init.io);
    overall.stop(init.io);

    try egl.denit();
}
