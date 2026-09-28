const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Development builds identify the coming release without claiming it has
    // shipped. Release automation overrides this from its vX.Y.Z tag.
    const version = b.option([]const u8, "version", "Version string printed by `emerald --version`") orelse "0.6.0-dev";

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
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", version);
    exe_module.addOptions("version_options", version_options);

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

    // `Repl.zig` is `main.zig`'s sibling, not `emerald_module`'s, so its own
    // tests (the completeness heuristic) need their own module: `zig build
    // test`'s module-based test discovery, unlike plain `zig test <file>`,
    // does not walk into a root's own `@import`s on its own.
    const repl_module = b.createModule(.{
        .root_source_file = b.path("src/Repl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emerald", .module = emerald_module }},
    });
    const repl_tests = b.addTest(.{
        .name = "emerald-repl",
        .root_module = repl_module,
    });
    const run_repl_tests = b.addRunArtifact(repl_tests);

    // `Lsp.zig` is `main.zig`'s sibling too, for the same reason `Repl.zig` is.
    const lsp_module = b.createModule(.{
        .root_source_file = b.path("src/Lsp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "emerald", .module = emerald_module }},
    });
    const lsp_tests = b.addTest(.{
        .name = "emerald-lsp",
        .root_module = lsp_module,
    });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

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

    // `zig build json-conformance -- <test_parsing directory>` checks the
    // JSON parser against JSONTestSuite, whose 318 files are too many to
    // commit; see tools/json/fetch.sh.
    const json_check = b.addExecutable(.{
        .name = "json-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/json/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emerald", .module = emerald_module }},
        }),
    });
    const run_json_check = b.addRunArtifact(json_check);
    if (b.args) |args| run_json_check.addArgs(args);
    b.step("json-conformance", "Check the JSON parser against JSONTestSuite").dependOn(&run_json_check.step);

    // A deterministic, bounded frontend campaign. It deliberately is not a
    // dependency of `test`: CI selects a short fixed campaign, while a local
    // run can choose a seed and case count with `zig build fuzz -- <seed> <cases>`.
    const fuzz = b.addExecutable(.{
        .name = "emerald-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "emerald", .module = emerald_module }},
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz);
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Run deterministic bounded execution fuzz cases").dependOn(&run_fuzz.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_conformance.step);
    test_step.dependOn(&run_repl_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
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

    // `check` shares `run`'s frontend but never evaluates entry statements.
    // Its output is therefore the successful analysis acknowledgement, not
    // anything the valid program would print.
    const checks_without_running = fixtures.add("checks-without-running.em", "print(\"this must not run\")\n");
    const check_does_not_execute = b.addRunArtifact(exe);
    check_does_not_execute.addArg("check");
    check_does_not_execute.addFileArg(checks_without_running);
    check_does_not_execute.expectStdOutEqual("No problems found.\n");
    check_does_not_execute.expectExitCode(0);
    test_step.dependOn(&check_does_not_execute.step);

    // Conversely, `run` must stop before entry execution when the shared
    // frontend finds a source error.
    const invalid_before_run = fixtures.add("invalid-before-run.em", "print(\"this must not run\")\nconst count: Int = \"one\"\n");
    const run_stops_on_source_error = b.addRunArtifact(exe);
    run_stops_on_source_error.addArg("run");
    run_stops_on_source_error.addFileArg(invalid_before_run);
    run_stops_on_source_error.expectExitCode(1);
    run_stops_on_source_error.addCheck(.{ .expect_stderr_match = "this is String, but `count` was declared as Int" });
    test_step.dependOn(&run_stops_on_source_error.step);

    // A warning is visible to every analysis command and keeps status 1, but
    // it does not suppress a valid run.
    const warned_program = fixtures.add("warned.em", "var score: Int = 5\nif score is Int {\n    print(\"still ran\")\n}\n");
    const check_reports_warning = b.addRunArtifact(exe);
    check_reports_warning.addArg("check");
    check_reports_warning.addFileArg(warned_program);
    check_reports_warning.expectExitCode(1);
    check_reports_warning.addCheck(.{ .expect_stderr_match = "warning: this `is` test always answers `true`" });
    test_step.dependOn(&check_reports_warning.step);

    const run_reports_warning_and_executes = b.addRunArtifact(exe);
    run_reports_warning_and_executes.addArg("run");
    run_reports_warning_and_executes.addFileArg(warned_program);
    run_reports_warning_and_executes.expectExitCode(1);
    run_reports_warning_and_executes.addCheck(.{ .expect_stdout_match = "still ran" });
    run_reports_warning_and_executes.addCheck(.{ .expect_stderr_match = "warning: this `is` test always answers `true`" });
    test_step.dependOn(&run_reports_warning_and_executes.step);

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

    const unknown_name = fixtures.add("unknown-name.em", "print(total)\n");
    const reports_unknown_name = b.addRunArtifact(exe);
    reports_unknown_name.addArg("check");
    reports_unknown_name.addFileArg(unknown_name);
    reports_unknown_name.expectExitCode(1);
    reports_unknown_name.addCheck(.{ .expect_stderr_match = "[E1001] `total` is not defined" });
    test_step.dependOn(&reports_unknown_name.step);

    const mismatched_type = fixtures.add("mismatched-type.em", "var count: Int = \"three\"\n");
    const reports_mismatched_type = b.addRunArtifact(exe);
    reports_mismatched_type.addArg("check");
    reports_mismatched_type.addFileArg(mismatched_type);
    reports_mismatched_type.expectExitCode(1);
    reports_mismatched_type.addCheck(.{ .expect_stderr_match = "[E2001] this is String, but `count` was declared as Int" });
    test_step.dependOn(&reports_mismatched_type.step);

    const constant_changed = fixtures.add("constant-changed.em", "const score = 10\nscore = 11\n");
    const reports_constant_changed = b.addRunArtifact(exe);
    reports_constant_changed.addArg("check");
    reports_constant_changed.addFileArg(constant_changed);
    reports_constant_changed.expectExitCode(1);
    reports_constant_changed.addCheck(.{ .expect_stderr_match = "[E3001] `score` cannot be reassigned" });
    test_step.dependOn(&reports_constant_changed.step);

    const unknown_member = fixtures.add("unknown-member.em", "var names = [\"Ava\"]\nnames.push(\"Leo\")\n");
    const reports_unknown_member = b.addRunArtifact(exe);
    reports_unknown_member.addArg("check");
    reports_unknown_member.addFileArg(unknown_member);
    reports_unknown_member.expectExitCode(1);
    reports_unknown_member.addCheck(.{ .expect_stderr_match = "[E4001] List[String] has no method `push`" });
    test_step.dependOn(&reports_unknown_member.step);

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

    // Bare invocation is the discovery path, not an error. Help can then be
    // narrowed to one command without making a user run a program first.
    const global_help = b.addRunArtifact(exe);
    global_help.expectExitCode(0);
    global_help.addCheck(.{ .expect_stdout_match = "Usage: emerald <command> [arguments]" });
    global_help.addCheck(.{ .expect_stdout_match = "Run `emerald help <command>`" });
    test_step.dependOn(&global_help.step);

    const version_output = b.addRunArtifact(exe);
    version_output.addArg("--version");
    version_output.expectStdOutEqual("Emerald 0.6.0-dev\n");
    version_output.expectExitCode(0);
    test_step.dependOn(&version_output.step);

    const run_help = b.addRunArtifact(exe);
    run_help.addArgs(&.{ "help", "run" });
    run_help.expectExitCode(0);
    run_help.addCheck(.{ .expect_stdout_match = "Usage: emerald run [--color=auto|always|never] <file.em> [-- <program-argument>...]" });
    test_step.dependOn(&run_help.step);

    const explain_help = b.addRunArtifact(exe);
    explain_help.addArgs(&.{ "help", "explain" });
    explain_help.expectExitCode(0);
    explain_help.addCheck(.{ .expect_stdout_match = "Usage: emerald explain <diagnostic-code>" });
    test_step.dependOn(&explain_help.step);

    const explains_unknown_name = b.addRunArtifact(exe);
    explains_unknown_name.addArgs(&.{ "explain", "E1001" });
    explains_unknown_name.expectExitCode(0);
    explains_unknown_name.addCheck(.{ .expect_stdout_match = "E1001: A name must be declared before Emerald can use it." });
    explains_unknown_name.addCheck(.{ .expect_stdout_match = "var total = 0" });
    test_step.dependOn(&explains_unknown_name.step);

    const rejects_unknown_explanation = b.addRunArtifact(exe);
    rejects_unknown_explanation.addArgs(&.{ "explain", "E9999" });
    rejects_unknown_explanation.expectExitCode(64);
    rejects_unknown_explanation.addCheck(.{ .expect_stderr_match = "`E9999` is not an explained diagnostic code" });
    test_step.dependOn(&rejects_unknown_explanation.step);

    const unknown_command = b.addRunArtifact(exe);
    unknown_command.addArg("rn");
    unknown_command.expectExitCode(64);
    unknown_command.addCheck(.{ .expect_stderr_match = "unknown command `rn`" });
    unknown_command.addCheck(.{ .expect_stderr_match = "Run `emerald help`" });
    test_step.dependOn(&unknown_command.step);

    const repl_misused = b.addRunArtifact(exe);
    repl_misused.addArgs(&.{ "repl", "unexpected.em" });
    repl_misused.expectExitCode(64);
    repl_misused.addCheck(.{ .expect_stderr_match = "repl does not take arguments" });
    repl_misused.addCheck(.{ .expect_stderr_match = "emerald help repl" });
    test_step.dependOn(&repl_misused.step);

    const lsp_misused = b.addRunArtifact(exe);
    lsp_misused.addArgs(&.{ "lsp", "unexpected" });
    lsp_misused.expectExitCode(64);
    lsp_misused.addCheck(.{ .expect_stderr_match = "lsp accepts only an optional `--stdio`" });
    test_step.dependOn(&lsp_misused.step);

    // A missing file is a different problem from a malformed command line
    // (64): the invocation itself was fine, so it gets its own status (66,
    // `sysexits.h`'s `EX_NOINPUT`) rather than sharing 64's.
    const missing = b.addRunArtifact(exe);
    missing.addArg("check");
    missing.addArg("definitely-does-not-exist.em");
    missing.expectExitCode(66);
    missing.addCheck(.{ .expect_stderr_match = "cannot read 'definitely-does-not-exist.em'" });
    test_step.dependOn(&missing.step);

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
    format_check_messy.addCheck(.{ .expect_stdout_match = "Would format " });
    format_check_messy.addCheck(.{ .expect_stdout_match = "Run `emerald format " });
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
    format_misused.addCheck(.{ .expect_stderr_match = "format expects `<file.em>` or `--check <file.em>`" });
    test_step.dependOn(&format_misused.step);

    // `run` executes and prints; a runtime error exits 2 rather than 1.
    const runs = b.addRunArtifact(exe);
    runs.addArg("run");
    runs.addFileArg(b.path("examples/arithmetic.em"));
    runs.expectStdOutEqual("14\n2\ntrue\n20\n");
    runs.expectExitCode(0);
    test_step.dependOn(&runs.step);

    const receives_arguments = fixtures.add("receives-arguments.em", "print(Program.arguments)\n");
    const run_receives_arguments = b.addRunArtifact(exe);
    run_receives_arguments.addArgs(&.{"run"});
    run_receives_arguments.addFileArg(receives_arguments);
    run_receives_arguments.addArgs(&.{ "--", "Ada", "two words" });
    run_receives_arguments.expectStdOutEqual("[\"Ada\", \"two words\"]\n");
    run_receives_arguments.expectExitCode(0);
    test_step.dependOn(&run_receives_arguments.step);

    // `--color` (rewrite-context 15.6): the flag is the highest-precedence
    // input, so `always`/`never` are asserted against this redirected pipe,
    // which auto-detection alone would always leave unstyled. The pure precedence function has its own exhaustive unit
    // tests (`src/ColorPolicy.zig`); these are the end-to-end wiring: CLI
    // parsing, `--` still working alongside the new flag, and environment
    // variables actually reaching the process.
    const greets = fixtures.add("greets.em", "print(Console.green(\"hi\"))\n");
    const color_always = b.addRunArtifact(exe);
    color_always.addArgs(&.{ "run", "--color=always" });
    color_always.addFileArg(greets);
    color_always.expectStdOutEqual("\x1b[32mhi\x1b[39m\n");
    color_always.expectExitCode(0);
    test_step.dependOn(&color_always.step);

    const color_never = b.addRunArtifact(exe);
    color_never.addArgs(&.{ "run", "--color=never" });
    color_never.addFileArg(greets);
    color_never.expectStdOutEqual("hi\n");
    color_never.expectExitCode(0);
    test_step.dependOn(&color_never.step);

    // The flag still leaves room for the path and `--`-separated program
    // arguments that follow it.
    const color_with_arguments = b.addRunArtifact(exe);
    color_with_arguments.addArgs(&.{ "run", "--color=always" });
    color_with_arguments.addFileArg(receives_arguments);
    color_with_arguments.addArgs(&.{ "--", "Ada" });
    color_with_arguments.expectStdOutEqual("[\"Ada\"]\n");
    color_with_arguments.expectExitCode(0);
    test_step.dependOn(&color_with_arguments.step);

    const color_rejects_unknown_value = b.addRunArtifact(exe);
    color_rejects_unknown_value.addArgs(&.{ "run", "--color=blue" });
    color_rejects_unknown_value.addFileArg(greets);
    color_rejects_unknown_value.expectExitCode(64);
    color_rejects_unknown_value.addCheck(.{
        .expect_stderr_match = "expects `--color=auto`, `--color=always`, or `--color=never`",
    });
    test_step.dependOn(&color_rejects_unknown_value.step);

    const color_rejects_missing_value = b.addRunArtifact(exe);
    color_rejects_missing_value.addArgs(&.{ "run", "--color" });
    color_rejects_missing_value.addFileArg(greets);
    color_rejects_missing_value.expectExitCode(64);
    color_rejects_missing_value.addCheck(.{
        .expect_stderr_match = "expects `--color=auto`, `--color=always`, or `--color=never`",
    });
    test_step.dependOn(&color_rejects_missing_value.step);

    // `test` accepts the same flag.
    const color_test_fixture = fixtures.add("color-test-fixture.em", "@test\nfunc only() {\n    assert true\n}\n");
    const color_on_test_command = b.addRunArtifact(exe);
    color_on_test_command.addArgs(&.{ "test", "--color=always" });
    color_on_test_command.addFileArg(color_test_fixture);
    color_on_test_command.expectStdOutEqual("1 test passed.\n");
    color_on_test_command.expectExitCode(0);
    test_step.dependOn(&color_on_test_command.step);

    // `FORCE_COLOR` reaches the process and turns styling on for this same
    // redirected pipe when no flag overrides it (third in 15.6's precedence).
    const color_from_force_color_env = b.addRunArtifact(exe);
    color_from_force_color_env.color = .manual;
    color_from_force_color_env.removeEnvironmentVariable("NO_COLOR");
    color_from_force_color_env.addArgs(&.{"run"});
    color_from_force_color_env.addFileArg(greets);
    color_from_force_color_env.setEnvironmentVariable("FORCE_COLOR", "1");
    color_from_force_color_env.expectStdOutEqual("\x1b[32mhi\x1b[39m\n");
    color_from_force_color_env.expectExitCode(0);
    test_step.dependOn(&color_from_force_color_env.step);

    // `--color=never` still wins over `FORCE_COLOR` (the flag is decision
    // 3's highest tier, checked before any environment variable).
    const color_flag_beats_force_color_env = b.addRunArtifact(exe);
    color_flag_beats_force_color_env.color = .manual;
    color_flag_beats_force_color_env.removeEnvironmentVariable("NO_COLOR");
    color_flag_beats_force_color_env.addArgs(&.{ "run", "--color=never" });
    color_flag_beats_force_color_env.addFileArg(greets);
    color_flag_beats_force_color_env.setEnvironmentVariable("FORCE_COLOR", "1");
    color_flag_beats_force_color_env.expectStdOutEqual("hi\n");
    color_flag_beats_force_color_env.expectExitCode(0);
    test_step.dependOn(&color_flag_beats_force_color_env.step);

    // Section 15.8's local zone reaches the process through `TZ`, read the
    // way glibc reads it. A POSIX rule needs no zoneinfo files, so the
    // result is the same on every Unix-like host; an empty `TZ` means UTC.
    // Windows describes its zone through the system instead, and ignores
    // `TZ`. `src/TimeZone.zig` unit-tests every source and rule form.
    if (b.graph.host.result.os.tag != .windows) {
        const reports_zone = fixtures.add("reports-zone.em", "print(TimeZone.local, TimeZone.local.offset_at(Instant.parse(\"2026-07-01T00:00:00Z\")))\n");
        const zone_from_posix_rule = b.addRunArtifact(exe);
        zone_from_posix_rule.addArg("run");
        zone_from_posix_rule.addFileArg(reports_zone);
        zone_from_posix_rule.setEnvironmentVariable("TZ", "EST5EDT,M3.2.0,M11.1.0");
        zone_from_posix_rule.expectStdOutEqual("EST5EDT,M3.2.0,M11.1.0 -4h\n");
        zone_from_posix_rule.expectExitCode(0);
        test_step.dependOn(&zone_from_posix_rule.step);

        const zone_empty_is_utc = b.addRunArtifact(exe);
        zone_empty_is_utc.addArg("run");
        zone_empty_is_utc.addFileArg(reports_zone);
        zone_empty_is_utc.setEnvironmentVariable("TZ", "");
        zone_empty_is_utc.expectStdOutEqual("UTC 0s\n");
        zone_empty_is_utc.expectExitCode(0);
        test_step.dependOn(&zone_empty_is_utc.step);
    }

    const check_rejects_arguments = b.addRunArtifact(exe);
    check_rejects_arguments.addArgs(&.{"check"});
    check_rejects_arguments.addFileArg(receives_arguments);
    check_rejects_arguments.addArgs(&.{ "--", "Ada" });
    check_rejects_arguments.expectExitCode(64);
    check_rejects_arguments.addCheck(.{ .expect_stderr_match = "check does not run a program" });
    test_step.dependOn(&check_rejects_arguments.step);

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

    const tests_receive_arguments = fixtures.add("tests-receive-arguments.em", "@test\nfunc arguments_are_available() {\n    print(Program.arguments)\n}\n");
    const test_receives_arguments = b.addRunArtifact(exe);
    test_receives_arguments.addArgs(&.{"test"});
    test_receives_arguments.addFileArg(tests_receive_arguments);
    test_receives_arguments.addArgs(&.{ "--", "seed" });
    test_receives_arguments.expectStdOutEqual("[\"seed\"]\n1 test passed.\n");
    test_receives_arguments.expectExitCode(0);
    test_step.dependOn(&test_receives_arguments.step);

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
