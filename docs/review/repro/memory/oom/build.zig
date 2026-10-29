//! Throwaway harness for the memory review (area 1): runs Emerald programs
//! through `emerald.run` with an allocation failure injected at each index.
//! Build from this directory with `mise exec -- zig build`, then run
//! `zig-out/bin/oom [--stride N] <file.em>...` from the repository root.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emerald_module = b.createModule(.{
        .root_source_file = b.path("../../../../../src/emerald.zig"),
        .target = target,
        .optimize = optimize,
    });
    const front_module = b.createModule(.{
        .root_source_file = b.path("../../../../../src/front.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    const tool = b.addExecutable(.{
        .name = "prelude-ast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../../../../../tools/prelude_ast.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{ .name = "front", .module = front_module }},
        }),
    });
    const gen = b.addRunArtifact(tool);
    gen.addFileArg(b.path("../../../../../src/prelude.em"));
    const prelude_ast = gen.addOutputFileArg("prelude_ast.zig");
    emerald_module.addAnonymousImport("prelude_ast", .{ .root_source_file = prelude_ast });
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", "0.0.0-review");
    opts.addOption(usize, "session_execution_runs", 0);
    emerald_module.addOptions("version_options", opts);

    const exe = b.addExecutable(.{
        .name = "oom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("oom.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emerald", .module = emerald_module }},
        }),
    });
    b.installArtifact(exe);
}
