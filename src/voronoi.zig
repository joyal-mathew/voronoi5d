const std = @import("std");
const rl = @import("c.zig").rl;

pub const allocator = std.heap.c_allocator;

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Centroid = struct {
    x: f32,
    y: f32,
};

pub fn cast(T: type, x: anytype) T {
    const x_info = @typeInfo(@TypeOf(x));

    return @as(T, switch (@typeInfo(T)) {
        .float => switch (x_info) {
            .float => @floatCast(x),
            .int => @floatFromInt(x),
            else => @compileError("Unimplemented"),
        },
        .int => switch (x_info) {
            .float => @intFromFloat(x),
            else => @compileError("Unimplemented"),
        },
        else => @compileError("Unimplemented"),
    });
}

pub fn suggestChromaticScale(pixels: []const Pixel) f64 {
    const Vec = @Vector(3, f64);

    var total: Vec = @splat(0);

    for (pixels) |p| {
        total += .{
            cast(f64, p.r) / 255,
            cast(f64, p.g) / 255,
            cast(f64, p.b) / 255,
        };
    }

    const n: Vec = @splat(cast(f64, pixels.len));
    const mean = total / n;

    var deviation: Vec = @splat(0);

    for (pixels) |p| {
        const v: Vec = .{
            cast(f64, p.r) / 255,
            cast(f64, p.g) / 255,
            cast(f64, p.b) / 255,
        };

        const d = v - mean;
        deviation += d * d;
    }

    const variance = deviation / n;
    const stdev = @sqrt(variance);
    return 3 / (@sqrt(12.0) * @reduce(.Add, stdev));
}

pub fn suggestK(width: usize, height: usize) usize {
    return std.math.log2_int_ceil(usize, width * height);
}
