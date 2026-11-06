const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const platform = b.option([]const u8, "platform", "raylib platform backend") orelse "glfw";
    const config = b.option([]const u8, "config", "extra raylib C flags") orelse "";
    const raylib = b.dependency("raylib", .{ .target = target, .optimize = optimize, .platform = platform, .config = config });
    const lib = b.addLibrary(.{
        .name = "emerald-raylib",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("module.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.linkLibrary(raylib.artifact("raylib"));
    b.installArtifact(lib);
}
