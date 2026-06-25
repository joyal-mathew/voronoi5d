const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/c.h"),
    });

    c.linkSystemLibrary("glad", .{});
    c.linkSystemLibrary("egl", .{});
    c.linkSystemLibrary("png", .{});
    c.linkSystemLibrary("jpeg", .{});

    const rl = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/rl.h"),
    });

    rl.linkSystemLibrary("X11", .{});
    rl.linkSystemLibrary("raylib", .{});

    const clap = b.dependency("clap", .{});

    const shader = b.path("src/voronoi.glsl");

    const exe = b.addExecutable(.{
        .name = "voronoi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rl", .module = rl.createModule() },
            },
        }),
    });

    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addAnonymousImport("shader", .{
        .root_source_file = shader,
    });

    const cli = b.addExecutable(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c.createModule() },
            },
        })
    });

    cli.root_module.addImport("clap", clap.module("clap"));
    cli.root_module.addAnonymousImport("shader", .{
        .root_source_file = shader,
    });

    b.installArtifact(exe);
    b.installArtifact(cli);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args|
        run_cmd.addArgs(args);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
