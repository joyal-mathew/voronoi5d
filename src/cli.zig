const std = @import("std");
const voronoi = @import("voronoi.zig");
const xpu = @import("gpu.zig");
const rl = @import("c.zig").rl;
const clap = @import("clap");

const ARGS_MESSAGE =
        \\-h, --help                    Display this help and exit
        \\-k, --centroids <INT>         Number of centroids
        \\-s, --chromatic_scale <FLOAT> Chromatic scale
        \\<PATH>                        Source path
        \\<PATH>                        Destination path
;

pub fn main() !void {
    const start = try std.time.Instant.now();
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
        .allocator = voronoi.allocator,
        .assignment_separators = "=:",
    }) catch |err| {
        var writer = std.fs.File.stdout().writer(&.{});
        try diag.report(&writer.interface, err);
        try writer.end();
        return err;
    };

    defer res.deinit();

    var stdout = std.fs.File.stdout().writer(&.{});

    if (res.args.help != 0) {
        try stdout.interface.print("{s}\n", .{ARGS_MESSAGE});
        return;
    }

    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));
    const random = rng.random();

    const src_path = try voronoi.allocator.dupeZ(u8, res.positionals[0] orelse return error.PathMissing);
    const dst_path = try voronoi.allocator.dupeZ(u8, res.positionals[1] orelse return error.PathMissing);
    defer voronoi.allocator.free(src_path);
    defer voronoi.allocator.free(dst_path);

    var image = rl.LoadImage(src_path);
    rl.ImageFormat(&image, rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    defer rl.UnloadImage(image);

    const k = res.args.centroids orelse voronoi.suggestK(@intCast(image.width), @intCast(image.height));

    const ptr: [*]voronoi.Pixel = @ptrCast(image.data orelse return error.NullPointer);
    const pixel_count: usize = @intCast(image.width * image.height);
    const src_pixels: []voronoi.Pixel = @ptrCast(ptr[0..pixel_count]);

    const chromatic_scale: f32 = @floatCast(res.args.chromatic_scale orelse voronoi.suggestChromaticScale(src_pixels));

    const centroids = try std.heap.c_allocator.alloc(voronoi.Centroid, k);
    defer std.heap.c_allocator.free(centroids);

    for (centroids) |*c| {
        c.* = .{
            .x = random.float(f32),
            .y = random.float(f32),
        };
    }

    rl.SetConfigFlags(rl.FLAG_WINDOW_HIDDEN);
    rl.InitWindow(0, 0, "");
    defer rl.CloseWindow();
    var backend = try xpu.Voronoi.init(image);
    defer backend.deinit();

    backend.update(centroids, chromatic_scale, false);

    try stdout.interface.print("k = {}, s_ch = {}\n", .{k, chromatic_scale});

    var out_image: rl.Image = image;
    out_image.data = (try backend.getPixels()).ptr;

    try stdout.interface.print("Exporting...\n", .{});
    if (!rl.ExportImage(out_image, dst_path))
        return error.ExportError;

    const end = try std.time.Instant.now();
    try stdout.interface.print("{} ms\n", .{end.since(start) / std.time.ns_per_ms});
}
