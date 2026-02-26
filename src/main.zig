const std = @import("std");
const voronoi = @import("voronoi.zig");
const rl = @import("c.zig").rl;

const gpu = @import("gpu.zig");
const cpu = @import("cpu.zig");

const Backend = union(enum) {
    gpu: gpu.Voronoi,
    cpu: cpu.Voronoi,

    fn update(self: *Backend, centroids: []voronoi.Centroid) void {
        switch (self.*) {
            .gpu => |*b| b.update(centroids),
            .cpu => |*b| b.update(centroids),
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

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    const image_path = args.next() orelse return error.ArgumentMissing;
    const k = try std.fmt.parseInt(usize, args.next() orelse return error.ArgumentMissing, 10);
    const backend_opt = if (args.next()) |s| std.meta.stringToEnum(std.meta.Tag(Backend), s) orelse return error.InvalidOption else null;

    const pixel_target_count = 200000;

    var image = rl.LoadImage(image_path);
    rl.ImageFormat(&image, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    scaleDownImage(&image, pixel_target_count);
    defer rl.UnloadImage(image);

    var screen_width = image.width;
    var screen_height = image.height;

    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE);
    rl.InitWindow(screen_width, screen_height, "Voronoi");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    const useGpu = if (backend_opt) |b| switch (b) {
        .gpu => true,
        .cpu => false,
    }
    else
        rl.rlGetVersion() == rl.RL_OPENGL_43;

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const random = rng.random();

    const centroids = try allocator.alloc(voronoi.Centroid, k);
    defer allocator.free(centroids);

    for (centroids) |*c| {
        const x = random.uintLessThan(u32, @intCast(image.width));
        const y = random.uintLessThan(u32, @intCast(image.height));

        c.* = .{
            .x = cast(f32, x) / cast(f32, image.width),
            .y = cast(f32, y) / cast(f32, image.height),
        };
    }

    const ptr: [*]voronoi.Pixel = @ptrCast(image.data orelse return error.NullPointer);
    const pixel_count: usize = @intCast(image.width * image.height);
    const src_pixels: []voronoi.Pixel = @ptrCast(ptr[0..pixel_count]);

    var backend: Backend = if (useGpu)
        .{ .gpu = try gpu.Voronoi.init(image) }
    else
        .{ .cpu = try cpu.Voronoi.init(image) };
    defer backend.deinit();

    std.log.info("Using {s}\n", .{ @tagName(backend) });

    var print_buffer: [64]u8 = undefined;
    var time_samples = std.mem.zeroes([16]u64);
    var time_i: usize = 0;

    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);

    while (!rl.WindowShouldClose()) {
        if (rl.IsWindowResized()) {
            screen_width = rl.GetScreenWidth();
            screen_height = rl.GetScreenHeight();
        }

        const start = try std.time.Instant.now();
        backend.update(centroids);
        const end = try std.time.Instant.now();

        time_samples[time_i] = end.since(start) / std.time.ns_per_ms;
        time_i += 1;
        if (time_i >= time_samples.len)
            time_i = 0;

        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.RAYWHITE);
        const rect = drawTexture(backend.getTexture(), screen_width, screen_height);
        for (centroids) |c| {
            const pos: rl.Vector2 = .{ .x = rect.x + rect.width * c.x, .y = rect.y + rect.height * c.y };
            const ix = cast(usize, c.x * cast(f32, width));
            const iy = cast(usize, c.y * cast(f32, height));
            const color = src_pixels[ix + iy * width];
            rl.DrawCircleV(pos, 10, .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a });
            rl.DrawRing(pos, 8, 12, 0, 360, 16, rl.BLACK);
        }

        if (rl.IsKeyDown(rl.KEY_F)) {
            rl.DrawFPS(1, 1);
        }
        else {
            var sum: u64 = 0;
            for (time_samples) |t|
                sum += t;
            var writer = std.Io.Writer.fixed(&print_buffer);
            try writer.print("{} ms", .{sum / time_samples.len});
            writer.buffer[writer.end] = 0;
            rl.DrawText(writer.buffer.ptr, 1, 1, 32, rl.GREEN);
        }
    }
}
