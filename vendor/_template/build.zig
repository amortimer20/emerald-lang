const std = @import("std");
const libraries = @import("../libraries.zig");

pub const library: libraries.Library = .{
    .name = "example",
    // The names that load the library: every type and namespace it declares.
    .names = &.{ "Example", "ExampleError" },
    .module = "emerald-example",
    .error_type = "ExampleError",
    // False while it is being built or only tests the mechanism.
    .ships = false,
    .add = add,
};

fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addCSourceFile(.{ .file = b.path("vendor/example/example.c"), .flags = &.{"-std=c11"} });
    // A library with upstream source adds it here, from a `build.zig.zon`
    // dependency, and links whatever system libraries it needs.
    return b.addLibrary(.{ .name = library.module, .linkage = .dynamic, .root_module = module });
}
