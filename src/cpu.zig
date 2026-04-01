const std = @import("std");
const voronoi = @import("voronoi.zig");
const rl = @import("c.zig").rl;

const cast = voronoi.cast;
const allocator = voronoi.allocator;

const Context = struct {
    i: usize = 0,
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,

    fn dist(lhs: Context, rhs: Context) f64 {
        const dx = lhs.x - rhs.x;
        const dy = lhs.y - rhs.y;
        const dr = lhs.r - rhs.r;
        const dg = lhs.g - rhs.g;
        const db = lhs.b - rhs.b;
        return dx * dx + dy * dy + dr * dr + dg * dg + db * db;
    }

    fn lessThan(context: Context, lhs: Context, rhs: Context) bool {
        const dist_lhs = lhs.dist(context);
        const dist_rhs = rhs.dist(context);
        return dist_lhs < dist_rhs;
    }
};

const CommonArgs = struct {
    dst_pixels: []voronoi.Pixel,
    src_pixels: []voronoi.Pixel,
    centroids: []Context,
    width: usize,
    height: usize,
    chromatic_scale: f32,
    debug: bool,
};

const VoronoiArgs = struct {
    start_i: usize,
    end_i: usize,
};

const DEBUG_COLORS = [_]voronoi.Pixel{
    .{ .r = 230 , .g = 41, .b = 55, .a = 255 },   // Red
    .{ .r = 255 , .g = 161, .b = 0, .a = 255 },   // Orange
    .{ .r = 253 , .g = 249, .b = 0, .a = 255 },   // Yellow
    .{ .r = 0   , .g = 228, .b = 48, .a = 255 },  // Green
    .{ .r = 0   , .g = 121, .b = 241, .a = 255 }, // Blue
    .{ .r = 135 , .g = 60, .b = 190, .a = 255 },  // Violet
    .{ .r = 130 , .g = 130, .b = 130, .a = 255 }, // Gray
    .{ .r = 255 , .g = 255, .b = 255, .a = 255 }, // White
    .{ .r = 0   , .g = 0, .b = 0, .a = 255 },     // Black
    .{ .r = 190 , .g = 33, .b = 55, .a = 255 },   // Maroon
    .{ .r = 127 , .g = 106, .b = 79, .a = 255 },  // Brown
    .{ .r = 255 , .g = 203, .b = 0, .a = 255 },   // Gold
    .{ .r = 0   , .g = 117, .b = 44, .a = 255 },  // Dark Green
    .{ .r = 0   , .g = 82, .b = 172, .a = 255 },  // Dark Blue
    .{ .r = 112 , .g = 31, .b = 126, .a = 255 },  // Dark Purple
    .{ .r = 200 , .g = 200, .b = 200, .a = 255 }, // Light Gray
    .{ .r = 255 , .g = 109, .b = 194, .a = 255 }, // Pink
    .{ .r = 211 , .g = 176, .b = 131, .a = 255 }, // Beige
    .{ .r = 0   , .g = 158, .b = 47, .a = 255 },  // Lime
    .{ .r = 102 , .g = 191, .b = 255, .a = 255 }, // Sky Blue
    .{ .r = 255 , .g = 0, .b = 255, .a = 255 },   // Magenta
    .{ .r = 200 , .g = 122, .b = 255, .a = 255 }, // Purple
    .{ .r = 76  , .g = 63, .b = 47, .a = 255 },   // Dark Brown
    .{ .r = 80  , .g = 80, .b = 80, .a = 255 },   // Dark Gray
    .{ .r = 245 , .g = 245, .b = 245, .a = 255 }, // Ray White
};

fn processVoronoi(args: VoronoiArgs, common: CommonArgs) void {
    var x = args.start_i % common.width;
    var y = @divTrunc(args.start_i, common.width);

    const w = cast(f32, common.width);
    const h = cast(f32, common.height);

    outer: while (true) : (y += 1) {
        while (x < common.width) : (x += 1) {
            const i = x + y * common.width;
            if (i >= args.end_i)
                break :outer;

            const p = common.src_pixels[i];

            const context: Context = .{
                .x = cast(f32, x) / w,
                .y = cast(f32, y) / h,
                .r = cast(f32, p.r) / 255 * common.chromatic_scale,
                .g = cast(f32, p.g) / 255 * common.chromatic_scale,
                .b = cast(f32, p.b) / 255 * common.chromatic_scale,
            };

            if (std.sort.min(Context, common.centroids, context, Context.lessThan)) |center| {
                if (common.debug) {
                    common.dst_pixels[i] = DEBUG_COLORS[center.i];
                }
                else {
                    const cx = cast(usize, center.x * w);
                    const cy = cast(usize, center.y * h);
                    common.dst_pixels[i] = common.src_pixels[cx + cy * common.width];
                }
            }
            else {
                common.dst_pixels[i] = common.src_pixels[i];
            }
        }

        x = 0;
    }
}

const WorkerArgs = struct {
    common: CommonArgs,
    args: []VoronoiArgs,
    starters: []std.Thread.ResetEvent,
    enders: []std.Thread.ResetEvent,
    end: std.Thread.ResetEvent,
};

pub const Voronoi = struct {
    threads: []std.Thread,
    worker_args: *WorkerArgs,
    context: std.array_list.Managed(Context),

    texture: rl.Texture,
    dst_pixels: []voronoi.Pixel,
    src_pixels: []voronoi.Pixel,
    width: usize,
    height: usize,
    chromatic_scale: f32 = 1.0,

    pub fn init(image: rl.Image) !Voronoi {
        const jobs = std.Thread.getCpuCount() catch 1;
        std.debug.print("Using {} threads\n", .{jobs});

        const args = try allocator.alloc(VoronoiArgs, jobs);
        const starters = try allocator.alloc(std.Thread.ResetEvent, jobs);
        const enders = try allocator.alloc(std.Thread.ResetEvent, jobs);
        const worker_args = try allocator.create(WorkerArgs);

        const threads = try allocator.alloc(std.Thread, jobs);

        @memset(starters, .{});
        @memset(enders, .{});

        const width: usize = @intCast(image.width);
        const height: usize = @intCast(image.height);
        const pixel_count = width * height;

        const dst_pixels = try allocator.alloc(voronoi.Pixel, pixel_count);
        const ptr: [*]voronoi.Pixel = @ptrCast(image.data orelse return error.NullPointer);
        const src_pixels: []voronoi.Pixel = @ptrCast(ptr[0..pixel_count]);

        const chunk_size = @divTrunc(pixel_count, jobs);
        const remaining = pixel_count % jobs;

        var offset: usize = 0;
        for (args, 0..) |*a, i| {
            const size = chunk_size + @intFromBool(i < remaining);
            a.start_i = offset;
            offset += size;
            a.end_i = offset;
        }

        worker_args.common.src_pixels = src_pixels;
        worker_args.common.dst_pixels = dst_pixels;
        worker_args.common.width = width;
        worker_args.common.height = height;
        worker_args.common.debug = false;
        worker_args.args = args;
        worker_args.starters = starters;
        worker_args.enders = enders;
        worker_args.end = .{};

        for (0..jobs) |tid|
            threads[tid] = try std.Thread.spawn(.{}, Voronoi.worker, .{tid, worker_args});

        return .{
            .threads = threads,
            .worker_args = worker_args,
            .context = .init(allocator),

            .texture = rl.LoadTextureFromImage(image),
            .dst_pixels = dst_pixels,
            .src_pixels = src_pixels,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: Voronoi) void {
        self.worker_args.end.set();
        for (self.worker_args.starters) |*s|
            s.set();
        for (self.threads) |t|
            t.join();

        rl.UnloadTexture(self.texture);
        allocator.free(self.dst_pixels);
        allocator.free(self.threads);
        allocator.free(self.worker_args.args);
        allocator.free(self.worker_args.starters);
        allocator.free(self.worker_args.enders);
        allocator.destroy(self.worker_args);
    }

    pub fn update(self: *Voronoi, centroids: []voronoi.Centroid, chromatic_scale: f32, debug: bool) void {
        self.context.clearRetainingCapacity();
        self.chromatic_scale = chromatic_scale;

        for (centroids) |c| {
            const ix = cast(usize, c.x * cast(f32, self.width));
            const iy = cast(usize, c.y * cast(f32, self.height));
            const p = self.src_pixels[ix + iy * self.width];

            self.context.append(.{
                .i = self.context.items.len,
                .x = c.x,
                .y = c.y,
                .r = cast(f32, p.r) / 255 * chromatic_scale,
                .g = cast(f32, p.g) / 255 * chromatic_scale,
                .b = cast(f32, p.b) / 255 * chromatic_scale,
            }) catch @panic("OOM");
        }

        self.worker_args.common.centroids = self.context.items;
        self.worker_args.common.chromatic_scale = chromatic_scale;
        self.worker_args.common.debug = debug;

        for (self.worker_args.starters) |*s|
            s.set();

        for (self.worker_args.enders) |*e| {
            e.wait();
            e.reset();
        }

        rl.UpdateTexture(self.texture, self.dst_pixels.ptr);
    }

    pub fn getTexture(self: Voronoi) rl.Texture2D {
        return self.texture;
    }

    pub fn getPixels(self: Voronoi) ![]voronoi.Pixel {
        return self.dst_pixels;
    }

    fn worker(tid: usize, args: *const WorkerArgs) void {
        while (true) {
            args.starters[tid].wait();
            if (args.end.isSet())
                break;
            args.starters[tid].reset();

            processVoronoi(args.args[tid], args.common);
            args.enders[tid].set();
        }
    }
};
