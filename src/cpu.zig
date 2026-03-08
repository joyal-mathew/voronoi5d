const std = @import("std");
const voronoi = @import("voronoi.zig");
const rl = @import("c.zig").rl;

const cast = voronoi.cast;
const allocator = voronoi.allocator;

const Context = struct {
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

const VoronoiArgs = struct {
    dst_pixels: []voronoi.Pixel,
    src_pixels: []voronoi.Pixel,
    centroids: []Context,
    width: usize,
    height: usize,
    chromatic_scale: f32,
    start_i: usize,
    end_i: usize,
};

fn processVoronoi(args: VoronoiArgs) void {
    var x = args.start_i % args.width;
    var y = @divTrunc(args.start_i, args.width);

    const w = cast(f32, args.width);
    const h = cast(f32, args.height);

    outer: while (true) : (y += 1) {
        while (x < args.width) : (x += 1) {
            const i = x + y * args.width;
            if (i >= args.end_i)
                break :outer;

            const p = args.src_pixels[i];

            const context: Context = .{
                .x = cast(f32, x) / w,
                .y = cast(f32, y) / h,
                .r = cast(f32, p.r) / 255 * args.chromatic_scale,
                .g = cast(f32, p.g) / 255 * args.chromatic_scale,
                .b = cast(f32, p.b) / 255 * args.chromatic_scale,
            };

            if (std.sort.min(Context, args.centroids, context, Context.lessThan)) |center| {
                const cx = cast(usize, center.x * w);
                const cy = cast(usize, center.y * h);
                args.dst_pixels[i] = args.src_pixels[cx + cy * args.width];
            }
            else {
                args.dst_pixels[i] = args.src_pixels[i];
            }
        }

        x = 0;
    }
}

const WorkerArgs = struct {
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

            a.src_pixels = src_pixels;
            a.dst_pixels = dst_pixels;
            a.width = width;
            a.height = height;
        }

        worker_args.* = .{
            .args = args,
            .starters = starters,
            .enders = enders,
            .end = .{},
        };

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

    pub fn update(self: *Voronoi, centroids: []voronoi.Centroid, chromatic_scale: f32) void {
        self.context.clearRetainingCapacity();
        self.chromatic_scale = chromatic_scale;

        for (centroids) |c| {
            const ix = cast(usize, c.x * cast(f32, self.width));
            const iy = cast(usize, c.y * cast(f32, self.height));
            const p = self.src_pixels[ix + iy * self.width];

            self.context.append(.{
                .x = c.x,
                .y = c.y,
                .r = cast(f32, p.r) / 255 * chromatic_scale,
                .g = cast(f32, p.g) / 255 * chromatic_scale,
                .b = cast(f32, p.b) / 255 * chromatic_scale,
            }) catch @panic("OOM");
        }

        for (self.worker_args.args, self.worker_args.starters) |*a, *s| {
            a.centroids = self.context.items;
            a.chromatic_scale = chromatic_scale;
            s.set();
        }

        for (self.worker_args.enders) |*e| {
            e.wait();
            e.reset();
        }

        rl.UpdateTexture(self.texture, self.dst_pixels.ptr);
    }

    pub fn getTexture(self: Voronoi) rl.Texture2D {
        return self.texture;
    }

    fn worker(tid: usize, args: *const WorkerArgs) void {
        while (true) {
            args.starters[tid].wait();
            if (args.end.isSet())
                break;
            args.starters[tid].reset();

            processVoronoi(args.args[tid]);
            args.enders[tid].set();
        }
    }
};
