const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const emerald_module = b.createModule(.{
        .root_source_file = b.path("src/emerald.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The conformance suite reads Emerald files at test time, so it needs to be
    // told where they are rather than depending on the working directory.
    const test_options = b.addOptions();
    test_options.addOptionPath("conformance_dir", b.path("conformance"));

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emerald", .module = emerald_module }},
    });
    conformance_module.addOptions("build_options", test_options);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emerald", .module = emerald_module }},
    });

    const exe = b.addExecutable(.{
        .name = "emerald",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the emerald executable");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .name = "emerald-test",
        .root_module = emerald_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const conformance_tests = b.addTest(.{
        .name = "emerald-conformance",
        .root_module = conformance_module,
    });
    const run_conformance = b.addRunArtifact(conformance_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_conformance.step);
    addCliTests(b, exe, test_step);
}

/// End-to-end coverage of the command-line contract. The exit codes in section
/// 18.1 are a promised interface, so they are asserted against the real binary
/// rather than only against library functions.
fn addCliTests(b: *std.Build, exe: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    const fixtures = b.addWriteFiles();
    // Written here rather than committed so the repository stays valid UTF-8.
    const malformed = fixtures.add("malformed.em", "var name = \"Ava\"\nvar bad = \"\xFF\"\n");

    const accepts = b.addRunArtifact(exe);
    accepts.addArg("check");
    accepts.addFileArg(b.path("examples/arithmetic.em"));
    accepts.expectStdOutEqual("No problems found.\n");
    accepts.expectExitCode(0);
    test_step.dependOn(&accepts.step);

    const rejects = b.addRunArtifact(exe);
    rejects.addArg("check");
    rejects.addFileArg(malformed);
    rejects.expectExitCode(1);
    rejects.addCheck(.{ .expect_stderr_match = "this is not valid UTF-8 text" });
    test_step.dependOn(&rejects.step);

    const lexical = fixtures.add("lexical.em", "var count = 0xFF\n");
    const reports_lexical = b.addRunArtifact(exe);
    reports_lexical.addArg("check");
    reports_lexical.addFileArg(lexical);
    reports_lexical.expectExitCode(1);
    reports_lexical.addCheck(.{ .expect_stderr_match = "Emerald writes numbers in decimal only" });
    test_step.dependOn(&reports_lexical.step);

    // Every diagnostic must reach the stream, not just the last one. This caught
    // a real defect: the standard streams were opened in positional mode, so each
    // write restarted at offset zero and clobbered the one before it.
    const two_problems = fixtures.add("two-problems.em", "var a = 0xFF\nvar b = 1__0\n");
    const reports_both = b.addRunArtifact(exe);
    reports_both.addArg("check");
    reports_both.addFileArg(two_problems);
    reports_both.expectExitCode(1);
    reports_both.addCheck(.{ .expect_stderr_match = "Emerald writes numbers in decimal only" });
    reports_both.addCheck(.{ .expect_stderr_match = "this is not a valid number" });
    test_step.dependOn(&reports_both.step);

    const misused = b.addRunArtifact(exe);
    misused.expectExitCode(64);
    misused.addCheck(.{ .expect_stderr_match = "usage: emerald check" });
    test_step.dependOn(&misused.step);
}
