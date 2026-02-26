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
    return switch (@typeInfo(T)) {
        .float => switch (@typeInfo(@TypeOf(x))) {
            .int => @as(T, @floatFromInt(x)),
            else => @compileError("Unimplemented"),
        },
        .int => switch (@typeInfo(@TypeOf(x))) {
            .float => @as(T, @intFromFloat(x)),
            else => @compileError("Unimplemented"),
        },
        else => @compileError("Unimplemented"),
    };
}
