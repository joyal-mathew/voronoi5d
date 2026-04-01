const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "voronoi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const cli = b.addExecutable(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        })
    });

    const cli2 = b.addExecutable(.{
        .name = "cli2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli2.zig"),
            .target = target,
            .optimize = optimize,
        })
    });

    const clap = b.dependency("clap", .{});

    exe.linkLibC();
    exe.root_module.linkSystemLibrary("raylib", .{});
    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addAnonymousImport("shader", .{
        .root_source_file = b.path("voronoi.glsl"),
    });

    cli.linkLibC();
    cli.root_module.linkSystemLibrary("raylib", .{});
    cli.root_module.addImport("clap", clap.module("clap"));
    cli.root_module.addAnonymousImport("shader", .{
        .root_source_file = b.path("voronoi.glsl"),
    });

    cli2.linkLibC();
    cli2.root_module.addImport("clap", clap.module("clap"));
    cli2.root_module.addLibraryPath(b.path("glad/lib"));
    cli2.root_module.addIncludePath(b.path("glad/include/"));
    cli2.root_module.linkSystemLibrary("glad", .{});
    cli2.root_module.linkSystemLibrary("egl", .{});
    cli2.root_module.linkSystemLibrary("png", .{});
    cli2.root_module.linkSystemLibrary("jpeg", .{});
    cli2.root_module.addAnonymousImport("shader", .{
        .root_source_file = b.path("voronoi.glsl"),
    });

    b.installArtifact(exe);
    b.installArtifact(cli);
    b.installArtifact(cli2);

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
