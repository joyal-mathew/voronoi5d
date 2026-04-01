const std = @import("std");
const voronoi = @import("voronoi.zig");
const clap = @import("clap");

const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("glad/glad.h");
    @cInclude("libpng16/png.h");
    @cInclude("jpeglib.h");
});

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
        c.GL_INVALID_FRAMEBUFFER_OPERATION => error.GlInvalidFramebuffer_Operation,
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

    const PNG_MAGIC = [_]u8{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    const JPEG_MAGIC = [_]u8{0xFF, 0xD8, 0xFF};

    fn checkPng(png: c.png_image) !void {
        if (png.warning_or_error != 0) {
            const msg: [*:0]const u8 = @ptrCast(&png.message);
            std.log.err("PNG Error: {s}\n", .{msg});
            return error.PngError;
        }
    }

    fn read(allocator: std.mem.Allocator, path: []const u8) !Image {
        const memory = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(memory);

        if (std.mem.startsWith(u8, memory, &PNG_MAGIC))
            return readPng(allocator, memory);
        if (std.mem.startsWith(u8, memory, &JPEG_MAGIC))
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

        info.out_color_space = c.JCS_EXT_RGBA;
        _ = c.jpeg_start_decompress(&info);
        defer _ = c.jpeg_finish_decompress(&info);

        const stride = info.output_width * @as(usize, @intCast(info.output_components));
        const row_buffer = if (info.mem.*.alloc_sarray) |alloc_fn|
            alloc_fn(@ptrCast(&info), c.JPOOL_IMAGE, @intCast(stride), 1)
        else
            return error.JpegError;

        std.debug.assert(info.output_components == 4);
        const buffer = try allocator.alloc(u8, 4 * info.output_width * info.output_height);

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
        png.format = c.PNG_FORMAT_RGBA;
        const buffer = try allocator.alloc(u8, 4 * png.width * png.height);

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
            .format = c.PNG_FORMAT_RGBA,
        });

        _ = c.png_image_write_to_file(&png, path, 1, self.buffer.ptr, 0, null);
        try checkPng(png);
    }

    fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
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

    fn init(allocator: std.mem.Allocator, image: Image) !Gl {
        var src_texture: u32 = undefined;
        var dst_texture: u32 = undefined;

        var shader_buffer: u32 = undefined;

        c.glCreateTextures(c.GL_TEXTURE_2D, 1, &src_texture);
        c.glCreateTextures(c.GL_TEXTURE_2D, 1, &dst_texture);
        c.glGenBuffers(1, &shader_buffer);

        try glCheck(src_texture);
        try glCheck(dst_texture);

        c.glTextureStorage2D(src_texture, 1, c.GL_RGBA8, @intCast(image.width), @intCast(image.height));
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTextureSubImage2D(src_texture, 0, 0, 0, @intCast(image.width), @intCast(image.height), c.GL_RGBA, c.GL_UNSIGNED_BYTE, image.buffer.ptr);

        c.glTextureStorage2D(dst_texture, 1, c.GL_RGBA8, @intCast(image.width), @intCast(image.height));
        const color = [_]u8{255} ** 4;
        c.glClearTexImage(dst_texture, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &color);

        c.glBindImageTexture(SRC_TEXTURE_INDEX, src_texture, 0, 0, 0, c.GL_READ_ONLY, c.GL_RGBA8);
        c.glBindImageTexture(DST_TEXTURE_INDEX, dst_texture, 0, 0, 0, c.GL_WRITE_ONLY, c.GL_RGBA8);
        c.glBindBufferBase(c.GL_SHADER_STORAGE_BUFFER, SHADER_BUFFER_INDEX, shader_buffer);
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
            .width = image.width,
            .height = image.height,
        };
    }

    fn deinit(self: *Gl) void {
        c.glDeleteTextures(1, &self.src_texture);
        c.glDeleteTextures(1, &self.dst_texture);
        c.glDeleteBuffers(1, &self.shader_buffer);
        c.glDeleteShader(self.shader);
        c.glDeleteProgram(self.program);
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

    fn writeToImage(self: Gl, image: Image) !void {
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glGetTextureImage(self.dst_texture, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, @intCast(image.buffer.len), image.buffer.ptr);

        try checkGlError();
    }
};

const SRC_TEXTURE_INDEX = 0;
const DST_TEXTURE_INDEX = 1;
const SHADER_BUFFER_INDEX = 2;

const ARGS_MESSAGE =
        \\-h, --help                    Display this help and exit
        \\-k, --centroids <INT>         Number of centroids
        \\-s, --chromatic_scale <FLOAT> Chromatic scale
        \\<PATH>                        Source path
        \\<PATH>                        Destination path
;

const Timer = struct {
    name: []const u8,
    start: std.time.Instant,

    fn begin(name: []const u8) !Timer {
        return .{
            .name = name,
            .start = try .now(),
        };
    }

    fn stop(self: Timer) !void {
        const end = try std.time.Instant.now();
        std.log.info("{s}: {} ms", .{self.name, end.since(self.start) / std.time.ns_per_ms});
    }
};

pub fn main() !void {
    const overall = try Timer.begin("overall");
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const params = comptime clap.parseParamsComptime(ARGS_MESSAGE);

    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .INT = clap.parsers.int(usize, 10),
        .FLOAT = clap.parsers.float(f64),
    };

    var arg_iter = std.process.args();
    _ = arg_iter.skip();
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, parsers, &arg_iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .assignment_separators = "=:",
    }) catch |err| {
        var writer = std.fs.File.stdout().writer(&.{});
        try diag.report(&writer.interface, err);
        try writer.end();
        return err;
    };

    defer res.deinit();

    const init = try Timer.begin("init");
    const egl = try Egl.init();

    if (c.gladLoadGL() == 0)
        return error.GlLoadError;

    const src_path = try allocator.dupeZ(u8, res.positionals[0] orelse return error.PathMissing);
    const dst_path = try allocator.dupeZ(u8, res.positionals[1] orelse return error.PathMissing);

    const image = try Image.read(std.heap.c_allocator, src_path);
    defer image.deinit(std.heap.c_allocator);

    var gl = try Gl.init(std.heap.c_allocator, image);
    defer gl.deinit();

    const k = res.args.centroids orelse 11;
    const s_ch = res.args.chromatic_scale orelse voronoi.suggestChromaticScale(@ptrCast(image.buffer));

    const centroids = try allocator.alloc(Centroid, k);

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const random = rng.random();

    for (centroids) |*e| {
        e.x = random.float(f32);
        e.y = random.float(f32);
    }

    std.log.info("k = {}, s_ch = {}", .{k, s_ch});
    try init.stop();

    const compute = try Timer.begin("compute");
    try gl.compute(centroids, @floatCast(s_ch));
    try gl.writeToImage(image);
    try compute.stop();

    const write = try Timer.begin("write");
    try image.write(dst_path);
    try write.stop();
    try overall.stop();

    try egl.denit();
}
