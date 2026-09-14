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

    // `zig build unicode-conformance -- <database directory>` checks all of
    // Unicode's NormalizationTest.txt, which is too large to commit. Part of
    // regenerating the Unicode tables; see tools/unicode/generate.zig.
    const unicode_check = b.addExecutable(.{
        .name = "unicode-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/unicode/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emerald", .module = emerald_module }},
        }),
    });
    const run_unicode_check = b.addRunArtifact(unicode_check);
    if (b.args) |args| run_unicode_check.addArgs(args);
    b.step("unicode-conformance", "Check the Unicode tables against a full database download").dependOn(&run_unicode_check.step);

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
    misused.addCheck(.{ .expect_stderr_match = "usage: emerald" });
    test_step.dependOn(&misused.step);

    // `emerald format` (18.3): a file already in the canonical style needs no
    // rewrite, `--check` reports one that does without touching it, and a
    // file that cannot parse safely is refused exactly as `check` refuses one
    // with a diagnostic, rather than partially rewritten.
    const canonical = fixtures.add("canonical.em", "var name = \"Ava\"\nprint(name)\n");
    const format_check_clean = b.addRunArtifact(exe);
    format_check_clean.addArgs(&.{ "format", "--check" });
    format_check_clean.addFileArg(canonical);
    format_check_clean.expectExitCode(0);
    test_step.dependOn(&format_check_clean.step);

    const messy_checked_only = fixtures.add("messy-checked-only.em", "var   name   =   \"Ava\"\nprint(name)\n");
    const format_check_messy = b.addRunArtifact(exe);
    format_check_messy.addArgs(&.{ "format", "--check" });
    format_check_messy.addFileArg(messy_checked_only);
    format_check_messy.expectExitCode(1);
    test_step.dependOn(&format_check_messy.step);

    // A separate fixture from the `--check` case above: both run against the
    // same `fixtures` step with no ordering between them, and this one is
    // actually rewritten in place.
    const messy_to_rewrite = fixtures.add("messy-to-rewrite.em", "var   name   =   \"Ava\"\nprint(name)\n");
    const format_rewrites = b.addRunArtifact(exe);
    format_rewrites.addArg("format");
    format_rewrites.addFileArg(messy_to_rewrite);
    format_rewrites.expectExitCode(0);
    test_step.dependOn(&format_rewrites.step);

    const format_rejects = b.addRunArtifact(exe);
    format_rejects.addArg("format");
    format_rejects.addFileArg(malformed);
    format_rejects.expectExitCode(1);
    format_rejects.addCheck(.{ .expect_stderr_match = "this is not valid UTF-8 text" });
    test_step.dependOn(&format_rejects.step);

    const format_misused = b.addRunArtifact(exe);
    format_misused.addArgs(&.{ "format", "a", "b" });
    format_misused.expectExitCode(64);
    format_misused.addCheck(.{ .expect_stderr_match = "usage: emerald" });
    test_step.dependOn(&format_misused.step);

    // `run` executes and prints; a runtime error exits 2 rather than 1.
    const runs = b.addRunArtifact(exe);
    runs.addArg("run");
    runs.addFileArg(b.path("examples/arithmetic.em"));
    runs.expectStdOutEqual("14\n2\ntrue\n20\n");
    runs.expectExitCode(0);
    test_step.dependOn(&runs.step);

    const overflows = fixtures.add("overflow.em", "print(9223372036854775807 + 1)\n");
    const reports_runtime = b.addRunArtifact(exe);
    reports_runtime.addArg("run");
    reports_runtime.addFileArg(overflows);
    reports_runtime.expectExitCode(2);
    reports_runtime.addCheck(.{ .expect_stderr_match = "overflows Int" });
    test_step.dependOn(&reports_runtime.step);

    const passing_tests = fixtures.add("passing-tests.em", "print(\"entry must not run\")\n\nfunc announce(text: String): Int {\n    print(text)\n    return 1\n}\n\nfunc broken_pair(): (Int, Int) {\n    print(\"pair attempted\")\n    raise Error(\"no pair\")\n}\n\nconst reached = announce(\"reached\")\nconst untouched = announce(\"untouched\")\nconst (left, right) = broken_pair()\n\n@test\nfunc one() {\n    assert reached == 1\n}\n\n@test\nfunc two() {\n    assert true\n}\n\n@test\nfunc failed_left() {\n    try {\n        print(left)\n    }\n    catch error {\n    }\n}\n\n@test\nfunc failed_right() {\n    try {\n        print(right)\n    }\n    catch error {\n    }\n}\n");
    const tests_pass = b.addRunArtifact(exe);
    tests_pass.addArg("test");
    tests_pass.addFileArg(passing_tests);
    tests_pass.expectStdOutEqual("reached\npair attempted\n4 tests passed.\n");
    tests_pass.expectExitCode(0);
    test_step.dependOn(&tests_pass.step);

    const single_test = fixtures.add("single-test.em", "@test\nfunc only() {\n    assert true\n}\n");
    const single_test_passes = b.addRunArtifact(exe);
    single_test_passes.addArg("test");
    single_test_passes.addFileArg(single_test);
    single_test_passes.expectStdOutEqual("1 test passed.\n");
    single_test_passes.expectExitCode(0);
    test_step.dependOn(&single_test_passes.step);

    const failing_tests = fixtures.add("failing-tests.em", "@test\nfunc fails() {\n    assert 1 == 2\n}\n\n@test\nfunc still_runs() {\n    print(\"still ran\")\n}\n");
    const tests_fail = b.addRunArtifact(exe);
    tests_fail.addArg("test");
    tests_fail.addFileArg(failing_tests);
    tests_fail.expectExitCode(3);
    tests_fail.addCheck(.{ .expect_stdout_match = "still ran" });
    tests_fail.addCheck(.{ .expect_stdout_match = "2 tests, 1 failed." });
    tests_fail.addCheck(.{ .expect_stderr_match = "test `fails` failed" });
    tests_fail.addCheck(.{ .expect_stderr_match = "Left was 1; right was 2." });
    test_step.dependOn(&tests_fail.step);
}
