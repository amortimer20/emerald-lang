const std = @import("std");
const libraries = @import("../libraries.zig");

pub const library: libraries.Library = .{
    .name = "selftest",
    .names = &.{ "Selftest", "SelftestCounter", "SelftestError" },
    .module = "emerald-selftest",
    .error_type = "SelftestError",
    .ships = false,
    .add = add,
};

fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{ .file = b.path("vendor/selftest/selftest.c"), .flags = &.{"-std=c11"} });
    return b.addLibrary(.{ .name = library.module, .linkage = .dynamic, .root_module = module });
}
