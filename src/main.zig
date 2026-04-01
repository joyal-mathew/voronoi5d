const std = @import("std");
const voronoi = @import("voronoi.zig");
const rl = @import("c.zig").rl;

const gpu = @import("gpu.zig");
const cpu = @import("cpu.zig");

const clap = @import("clap");

const Backend = union(enum) {
    gpu: gpu.Voronoi,
    cpu: cpu.Voronoi,

    fn update(self: *Backend, centroids: []voronoi.Centroid, chromatic_scale: f32, debug: bool) void {
        switch (self.*) {
            .gpu => |*b| b.update(centroids, chromatic_scale, debug),
            .cpu => |*b| b.update(centroids, chromatic_scale, debug),
        }
    }

    fn getTexture(self: Backend) rl.Texture2D {
        return switch (self) {
            .gpu => |b| b.getTexture(),
            .cpu => |b| b.getTexture(),
        };
    }

    fn deinit(self: Backend) void {
        switch (self) {
            .gpu => |b| b.deinit(),
            .cpu => |b| b.deinit(),
        }
    }
};

const cast = voronoi.cast;
const allocator = voronoi.allocator;

fn scaleDownImage(image: *rl.Image, pixel_target_count: i32) void {
    const total_pixels = image.width * image.height;
    const pixels_scale: u32 = @intCast(@divTrunc(total_pixels, pixel_target_count));
    const side_scale: i32 = @intCast(std.math.sqrt(pixels_scale));

    if (side_scale > 0)
        rl.ImageResize(image, @divTrunc(image.width, side_scale), @divTrunc(image.height, side_scale));
}

fn getRenderRect(texture_w: i32, texture_h: i32, window_w: i32, window_h: i32, padding: i32) rl.Rectangle {
    const texture_aspect_ratio = cast(f64, texture_w) / cast(f64, texture_h);
    const window_aspect_ratio = cast(f64, window_w) / cast(f64, window_h);

    const render_w, const render_h = blk: {
        if (texture_aspect_ratio < window_aspect_ratio) {
            const h = window_h - 2 * padding;
            const w: i32 = @intFromFloat(cast(f32, h) * texture_aspect_ratio);
            break :blk .{w, h};
        }
        else {
            const w = window_w - 2 * padding;
            const h: i32 = @intFromFloat(cast(f32, w) / texture_aspect_ratio);
            break :blk .{w, h};
        }
    };

    const offset_x = @divTrunc(window_w - render_w, 2);
    const offset_y = @divTrunc(window_h - render_h, 2);

    return .{
        .x = @floatFromInt(offset_x),
        .y = @floatFromInt(offset_y),
        .width = @floatFromInt(render_w),
        .height = @floatFromInt(render_h),
    };
}

pub fn drawTexture(texture: rl.Texture2D, screen_width: i32, screen_height: i32) rl.Rectangle {
    const rect = getRenderRect(texture.width, texture.height, screen_width, screen_height, 10);
    rl.DrawTexturePro(
        texture,
        std.mem.zeroInit(rl.Rectangle, .{ .width = cast(f32, texture.width), .height = cast(f32, texture.height) }),
        rect,
        std.mem.zeroes(rl.Vector2), 0, rl.WHITE,
    );
    return rect;
}

const InputHandler = struct {
    hadInput: bool = true,

    fn isKeyPressed(self: *InputHandler, key: i32) bool {
        const pressed = rl.IsKeyPressed(key);
        self.hadInput = self.hadInput or pressed;
        return pressed;
    }

    fn gotInput(self: *InputHandler) bool {
        defer self.hadInput = false;
        return self.hadInput;
    }
};

const ARGS_MESSAGE =
        \\-h, --help                    Display this help and exit
        \\-k, --centroids <INT>         Number of centroids
        \\-s, --chromatic_scale <FLOAT> Chromatic scale
        \\-b, --backend   <BACKEND>     An option parameter which takes an enum
        \\<PATH>
;

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(ARGS_MESSAGE);

    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .INT = clap.parsers.int(usize, 10),
        .FLOAT = clap.parsers.float(f64),
        .BACKEND = clap.parsers.enumeration(std.meta.Tag(Backend)),
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

    if (res.args.help != 0) {
        std.debug.print("{s}\n", .{ARGS_MESSAGE});
        return;
    }

    // const pixel_target_count = 200000;

    const image_path = try allocator.dupeZ(u8, res.positionals[0] orelse return error.PathMissing);
    defer allocator.free(image_path);
    var image = rl.LoadImage(image_path);
    rl.ImageFormat(&image, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    // scaleDownImage(&image, pixel_target_count);
    defer rl.UnloadImage(image);

    var screen_width = image.width;
    var screen_height = image.height;

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(screen_width, screen_height, "Voronoi");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    const useGpu = if (res.args.backend) |b| switch (b) {
        .gpu => true,
        .cpu => false,
    }
    else
        rl.rlGetVersion() == rl.RL_OPENGL_43;

    const image_texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(image_texture);

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const random = rng.random();

    var centroids = std.array_list.Managed(voronoi.Centroid).init(allocator);
    defer centroids.deinit();

    for (0..res.args.centroids orelse 11) |_| {
        try centroids.append(.{
            .x = random.float(f32),
            .y = random.float(f32),
        });
    }

    const ptr: [*]voronoi.Pixel = @ptrCast(image.data orelse return error.NullPointer);
    const pixel_count: usize = @intCast(image.width * image.height);
    const src_pixels: []voronoi.Pixel = @ptrCast(ptr[0..pixel_count]);

    const chromatic_delta = 0.1;
    var chromatic_scale: f32 = @floatCast(res.args.chromatic_scale orelse voronoi.suggestChromaticScale(src_pixels));

    var backend: Backend = if (useGpu)
        .{ .gpu = try gpu.Voronoi.init(image) }
    else
        .{ .cpu = try cpu.Voronoi.init(image) };
    defer backend.deinit();

    std.log.info("Using {s}", .{@tagName(backend)});
    std.log.info("s_ch = {}", .{chromatic_scale});

    var print_buffer: [64]u8 = undefined;
    var time_samples = std.mem.zeroes([16]u64);
    var time_i: usize = 0;

    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);

    var debug = false;
    var input_handler: InputHandler = .{};

    while (!rl.WindowShouldClose()) {
        if (rl.IsWindowResized()) {
            screen_width = rl.GetScreenWidth();
            screen_height = rl.GetScreenHeight();
        }

        if (input_handler.isKeyPressed(rl.KEY_MINUS)) {
            _ = centroids.pop();
        }

        if (input_handler.isKeyPressed(rl.KEY_EQUAL)) {
            try centroids.append(.{
                .x = random.float(f32),
                .y = random.float(f32),
            });
        }

        if (input_handler.isKeyPressed(rl.KEY_UP))
            chromatic_scale += chromatic_delta;
        if (input_handler.isKeyPressed(rl.KEY_DOWN))
            chromatic_scale -= chromatic_delta;

        if (input_handler.isKeyPressed(rl.KEY_R)) {
            for (centroids.items) |*c| {
                c.* = .{
                    .x = random.float(f32),
                    .y = random.float(f32),
                };
            }
        }

        if (input_handler.isKeyPressed(rl.KEY_D))
            debug = !debug;

        const start = try std.time.Instant.now();
        if (input_handler.gotInput())
            backend.update(centroids.items, chromatic_scale, debug);
        const end = try std.time.Instant.now();

        time_samples[time_i] = end.since(start) / std.time.ns_per_ms;
        time_i += 1;
        if (time_i >= time_samples.len)
            time_i = 0;

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.RAYWHITE);
        const rect = drawTexture(if (rl.IsKeyDown(rl.KEY_O)) image_texture else backend.getTexture(), screen_width, screen_height);
        if (!rl.IsKeyDown(rl.KEY_SPACE)) {
            for (centroids.items) |c| {
                const pos: rl.Vector2 = .{ .x = rect.x + rect.width * c.x, .y = rect.y + rect.height * c.y };
                const ix = cast(usize, c.x * cast(f32, width));
                const iy = cast(usize, c.y * cast(f32, height));
                const color = src_pixels[ix + iy * width];
                rl.DrawCircleV(pos, 10, .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a });
                rl.DrawRing(pos, 8, 12, 0, 360, 16, rl.BLACK);
            }
        }

        if (rl.IsKeyDown(rl.KEY_F)) {
            rl.DrawFPS(1, 1);
        }
        else if (rl.IsKeyDown(rl.KEY_T)) {
            var sum: u64 = 0;
            for (time_samples) |t|
                sum += t;
            var writer = std.Io.Writer.fixed(&print_buffer);
            try writer.print("{} ms", .{sum / time_samples.len});
            writer.buffer[writer.end] = 0;
            rl.DrawText(writer.buffer.ptr, 1, 1, 32, rl.GREEN);
        }
        else {
            var writer = std.Io.Writer.fixed(&print_buffer);
            try writer.print("{}", .{chromatic_scale});
            writer.buffer[writer.end] = 0;
            rl.DrawText(writer.buffer.ptr, 1, 1, 32, rl.GREEN);
        }
    }
}
