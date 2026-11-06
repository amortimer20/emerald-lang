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
    const artifact = raylib.artifact("raylib");
    // rlsw.h includes itself by the path it was compiled under, which is
    // relative to the build root; searching the root finds it.
    if (std.mem.eql(u8, platform, "memory")) artifact.root_module.addIncludePath(.{ .cwd_relative = "." });
    lib.root_module.linkLibrary(artifact);
    // The memory backend calls timeBeginPeriod but raylib's build does not link winmm for it.
    if (target.result.os.tag == .windows and std.mem.eql(u8, platform, "memory")) lib.root_module.linkSystemLibrary("winmm", .{});
    b.installArtifact(lib);
}
