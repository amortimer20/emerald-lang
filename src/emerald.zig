//! The Emerald frontend library.
//!
//! The pipeline described in section 19.2 is source manager, lexer, parser,
//! resolver, checker, interpreter. All of them exist now, wired together by
//! `check` and `run` below.
//!
//! Every stage after the lexer recurses over the tree, so the whole pipeline
//! runs on a thread with a large stack, sized for section 7.2's 1,000 active
//! calls at section 3.4's deepest guaranteed nesting in a Debug build, where
//! frames are largest. The parser bounds how tall any tree can grow before a
//! later stage walks it, and the interpreter guards the stack as it goes.

const std = @import("std");
const builtin = @import("builtin");

pub const Source = @import("Source.zig");
pub const Project = @import("Project.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");
pub const Ast = @import("Ast.zig");
pub const Parser = @import("Parser.zig");
pub const Resolver = @import("Resolver.zig");
pub const Type = @import("Type.zig");
pub const Checker = @import("Checker.zig");
pub const Value = @import("Value.zig");
pub const Interpreter = @import("Interpreter.zig");
pub const Heap = @import("Heap.zig");
pub const Formatter = @import("Formatter.zig");
pub const unicode = @import("unicode.zig");
pub const strings = @import("strings.zig");

/// Declarations every program sees, such as section 11.5's `Ordered`.
const prelude_text = @embedFile("prelude.em");

/// Everything a stage reported, owned by one arena.
pub const Report = struct {
    arena_state: std.heap.ArenaAllocator,
    /// Problems found before execution. An error here means nothing ran; a
    /// warning does not stop checking or execution, so it may sit alongside
    /// `failure`, `test_failures`, or a normal, complete run.
    diagnostics: []const Diagnostic,
    /// The error that stopped execution, when execution started and failed.
    failure: ?Diagnostic = null,
    /// Failures collected by `emerald test`, which does not stop at the first.
    test_failures: []const Diagnostic = &.{},
    test_count: usize = 0,
    /// A process status requested by the running Emerald program.
    exit_code: ?u8 = null,

    pub fn ok(self: Report) bool {
        return !Diagnostic.anyErrors(self.diagnostics) and self.failure == null and self.test_failures.len == 0;
    }

    pub fn deinit(self: *Report) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub const Error = Interpreter.RunError || error{
    /// The large-stack thread could not be created, so the pipeline cannot
    /// keep section 7.2's guarantees and does not start.
    StackUnavailable,
};

/// Analyses a source file without running it, as section 18.1 requires of
/// `emerald check`: the same analysis as `run`, with nothing executed.
pub fn check(gpa: std.mem.Allocator, source: *const Source) Error!Report {
    var files = [_]Project.File{lone(source)};
    const project = loneProject(&files);
    return checkProject(gpa, &project);
}

/// The same, for a whole project (14.1).
pub fn checkProject(gpa: std.mem.Allocator, project: *const Project) Error!Report {
    return onLargeStack(gpa, project, null, false, null);
}

/// Checking's full detail, kept alive for a language-server tool (18.5) that
/// needs more than pass or fail — hover's inferred type for whatever
/// expression the cursor is on, most directly. Checking only: nothing here
/// executes the program. Everything `checked.expression_types`' expression
/// pointers point into is held here too, since freeing the parsed trees
/// would leave them dangling; `deinit` releases all of it together.
pub const Analysis = struct {
    /// A declaration's name, like every other identifier text, is a slice of
    /// its own file's source rather than a copy (`Ast.StructDeclaration.name`
    /// and the rest) — so a prelude type's `display_name` (`RuntimeError`,
    /// `Ordered`, ...) stays valid only as long as this does. Kept alongside
    /// `tokenized`/`parsed`/`resolved`/`checked` for exactly the same reason
    /// they are: freeing it before the caller is done reading `checked`
    /// leaves whatever pointed into it — here, text, there, syntax nodes —
    /// dangling.
    prelude_source: Source,
    tokenized: []Lexer.Tokenized,
    parsed: []Parser.Parsed,
    resolved: Resolver.Resolved,
    checked: Checker.Checked,

    /// Whether checking finished with no error. A warning may remain, but a
    /// warning never stops checking, so `expression_types` is trustworthy
    /// either way.
    pub fn ok(self: Analysis) bool {
        return self.checked.ok();
    }

    pub fn deinit(self: *Analysis, gpa: std.mem.Allocator) void {
        self.checked.deinit();
        self.resolved.deinit();
        for (self.parsed) |*one| one.deinit();
        gpa.free(self.parsed);
        for (self.tokenized) |*one| one.deinit(gpa);
        gpa.free(self.tokenized);
        self.prelude_source.deinit(gpa);
        self.* = undefined;
    }
};

/// Lexes, parses, resolves, and checks a whole project (14.1) on the large
/// stack every recursive stage needs (this file's header), without running
/// anything. `null` means an earlier stage — invalid encoding, a directory
/// that cannot be a namespace, a lexical or parse error, or an unresolved
/// name — already stopped the pipeline (17.2's rule against cascades) before
/// there was anything for checking to see; `check`/`run` would report the
/// same stage's diagnostics in that case. A tool built on this has no
/// diagnostics of its own to show, so it only needs to know whether it has
/// an answer, not why it does not.
pub fn analyzeProject(gpa: std.mem.Allocator, project: *const Project) Error!?Analysis {
    const Task = struct {
        gpa: std.mem.Allocator,
        project: *const Project,
        result: Error!?Analysis = undefined,

        fn go(task: *@This(), available: usize) void {
            _ = available;
            task.result = analyzeOnce(task.gpa, task.project);
        }
    };

    var task: Task = .{ .gpa = gpa, .project = project };
    const thread = std.Thread.spawn(.{ .stack_size = stack_size }, Task.go, .{ &task, stack_size }) catch
        return error.StackUnavailable;
    thread.join();
    return task.result;
}

fn analyzeOnce(gpa: std.mem.Allocator, project: *const Project) Error!?Analysis {
    for (project.files) |file| {
        if (Source.findInvalidUtf8(file.source.text) != null) return null;
    }
    if (project.bad_directories.len != 0) return null;

    // The prelude joins the project the same way `analyze` joins it, so a
    // program's own use of `Ordered`, `Textual`, and the rest resolves and
    // checks the same way it would for `check`/`run`. On success this moves
    // into the returned `Analysis`, which owns it from there; every early
    // "nothing to check" exit below still owns it and frees it itself.
    var prelude_source = try Source.init(gpa, "prelude.em", prelude_text);
    errdefer prelude_source.deinit(gpa);
    const files = try gpa.alloc(Project.File, project.files.len + 1);
    defer gpa.free(files);
    @memcpy(files[0..project.files.len], project.files);
    files[project.files.len] = .{ .source = prelude_source, .namespace = Resolver.prelude_namespace, .entry = false };

    const tokenized = try gpa.alloc(Lexer.Tokenized, files.len);
    var lexed: usize = 0;
    var lex_ok = true;
    while (lexed < files.len) : (lexed += 1) {
        tokenized[lexed] = try Lexer.tokenize(gpa, &files[lexed].source);
        if (tokenized[lexed].diagnostics.len != 0) lex_ok = false;
    }
    if (!lex_ok) {
        for (tokenized) |*one| one.deinit(gpa);
        gpa.free(tokenized);
        prelude_source.deinit(gpa);
        return null;
    }

    const parsed = try gpa.alloc(Parser.Parsed, files.len);
    var parsed_count: usize = 0;
    var parse_ok = true;
    while (parsed_count < files.len) : (parsed_count += 1) {
        parsed[parsed_count] = try Parser.parse(gpa, &files[parsed_count].source, tokenized[parsed_count].tokens);
        if (parsed[parsed_count].diagnostics.len != 0) parse_ok = false;
    }
    if (!parse_ok) {
        for (parsed) |*one| one.deinit();
        gpa.free(parsed);
        for (tokenized) |*one| one.deinit(gpa);
        gpa.free(tokenized);
        prelude_source.deinit(gpa);
        return null;
    }

    const programs = try gpa.alloc(Ast.Program, files.len);
    defer gpa.free(programs);
    for (parsed, programs) |one, *program| program.* = one.program;

    var resolved = try Resolver.resolve(gpa, files, programs, project.enclosing_project);
    if (!resolved.ok()) {
        resolved.deinit();
        for (parsed) |*one| one.deinit();
        gpa.free(parsed);
        for (tokenized) |*one| one.deinit(gpa);
        gpa.free(tokenized);
        prelude_source.deinit(gpa);
        return null;
    }

    const checked = try Checker.check(gpa, files, programs, resolved.facts);
    return .{ .prelude_source = prelude_source, .tokenized = tokenized, .parsed = parsed, .resolved = resolved, .checked = checked };
}

/// A single file is a complete program, so it is a project of one. Nothing
/// below this needs to know which it was given.
///
/// The caller holds the one-file array, because the project borrows it and must
/// not outlive it.
fn lone(source: *const Source) Project.File {
    return .{ .source = source.*, .namespace = "", .entry = true };
}

fn loneProject(files: []Project.File) Project {
    return .{ .files = files, .entry = 0, .bad_directories = &.{} };
}

/// Where a running program's output goes and where `input` reads from.
pub const Streams = struct {
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    /// Section 14.1's `Program.arguments`. Empty unless the caller has actual
    /// program arguments to give, such as the CLI's `run`/`test` commands.
    arguments: []const []const u8 = &.{},
};

/// Checks a source file and then executes it with `streams`.
pub fn run(gpa: std.mem.Allocator, source: *const Source, streams: Streams) Error!Report {
    return runWithStepLimit(gpa, source, streams, null);
}

/// Checks and runs one file with an optional host-imposed execution budget.
/// A limit is for tools that run untrusted/generated programs; normal CLI
/// execution remains unbounded and therefore has no new language behavior.
pub fn runWithStepLimit(gpa: std.mem.Allocator, source: *const Source, streams: Streams, step_limit: ?usize) Error!Report {
    var files = [_]Project.File{lone(source)};
    const project = loneProject(&files);
    return runProjectWithStepLimit(gpa, &project, streams, step_limit);
}

/// The same, for a whole project (14.1).
pub fn runProject(gpa: std.mem.Allocator, project: *const Project, streams: Streams) Error!Report {
    return runProjectWithStepLimit(gpa, project, streams, null);
}

/// The project counterpart to `runWithStepLimit`.
pub fn runProjectWithStepLimit(gpa: std.mem.Allocator, project: *const Project, streams: Streams, step_limit: ?usize) Error!Report {
    return onLargeStack(gpa, project, streams, false, step_limit);
}

/// Checks a project, skips its entry statements, and runs every `@test` function.
pub fn testProject(gpa: std.mem.Allocator, project: *const Project, streams: Streams) Error!Report {
    return onLargeStack(gpa, project, streams, true, null);
}

/// Everything `emerald format` (18.3) needs to know about one project.
pub const FormatReport = struct {
    arena_state: std.heap.ArenaAllocator,
    /// A file that could not be lexed or parsed safely. Non-empty means
    /// nothing was formatted: §18.3 refuses to rewrite a file it cannot parse
    /// safely, and one bad file stops the whole project exactly as it does
    /// for `check`/`run`, rather than risk formatting some files and not
    /// others in the same run.
    diagnostics: []const Diagnostic,
    /// Parallel to `Project.files`, present only when `diagnostics` is empty.
    files: []const FormattedFile,

    pub fn ok(self: FormatReport) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *FormatReport) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

pub const FormattedFile = struct {
    text: []const u8,
    changed: bool,
};

/// Formats every file of a project (18.3), exactly as `checkProject` and
/// `runProject` see the same project: a lone file, or every file under a
/// directory that holds `main.em` (14.1). Formatting is purely syntactic, so
/// only the lexer and parser run — a file that does not yet check is still
/// formattable — but the parser's expression trees can nest as deep as
/// `Parser.max_expression_depth`, which the printer's recursive walk then
/// matches frame for frame, so this runs on the same large-stack thread as
/// everything else rather than assume the calling thread's stack is enough.
pub fn formatProject(gpa: std.mem.Allocator, project: *const Project) Error!FormatReport {
    const Task = struct {
        gpa: std.mem.Allocator,
        project: *const Project,
        result: Error!FormatReport = undefined,

        fn go(task: *@This(), available: usize) void {
            _ = available;
            task.result = formatAnalyze(task.gpa, task.project);
        }
    };

    var task: Task = .{ .gpa = gpa, .project = project };
    const thread = std.Thread.spawn(.{ .stack_size = stack_size }, Task.go, .{ &task, stack_size }) catch
        return error.StackUnavailable;
    thread.join();
    return task.result;
}

/// One stage at a time, over every file, exactly as `analyze` does: every
/// file is lexed before any is parsed, so a project reports every lexical
/// problem before any parse problem, matching §17.2's rule against cascades.
fn formatAnalyze(gpa: std.mem.Allocator, project: *const Project) Error!FormatReport {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var found: std.ArrayList(Diagnostic) = .empty;

    // Mirrors `analyze`'s own first stage: a lexer that does not itself
    // validate encoding (identifiers aside) would otherwise wave invalid
    // UTF-8 sitting inside a string literal straight through as opaque bytes.
    for (project.files, 0..) |file, index| {
        const span = Source.findInvalidUtf8(file.source.text) orelse continue;
        try found.append(arena, .{
            .message = "this is not valid UTF-8 text",
            .span = span,
            .help = "Emerald source files are always UTF-8. Re-save this file as UTF-8.",
            .file = @intCast(index),
        });
    }
    if (found.items.len != 0) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena), .files = &.{} };
    }

    const tokenized = try gpa.alloc(Lexer.Tokenized, project.files.len);
    var lexed: usize = 0;
    defer {
        for (tokenized[0..lexed]) |*one| one.deinit(gpa);
        gpa.free(tokenized);
    }
    while (lexed < project.files.len) : (lexed += 1) {
        tokenized[lexed] = try Lexer.tokenize(gpa, &project.files[lexed].source);
        try appendFrom(arena, &found, tokenized[lexed].diagnostics, @intCast(lexed));
    }
    if (found.items.len != 0) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena), .files = &.{} };
    }

    const parsed = try gpa.alloc(Parser.Parsed, project.files.len);
    var parsed_count: usize = 0;
    defer {
        for (parsed[0..parsed_count]) |*one| one.deinit();
        gpa.free(parsed);
    }
    while (parsed_count < project.files.len) : (parsed_count += 1) {
        parsed[parsed_count] = try Parser.parse(gpa, &project.files[parsed_count].source, tokenized[parsed_count].tokens);
        try appendFrom(arena, &found, parsed[parsed_count].diagnostics, @intCast(parsed_count));
    }
    if (found.items.len != 0) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena), .files = &.{} };
    }

    const files_out = try arena.alloc(FormattedFile, project.files.len);
    for (project.files, tokenized, parsed, files_out) |file, one_tokenized, one_parsed, *out| {
        const formatted = try Formatter.print(arena, &file.source, one_tokenized.tokens, one_parsed.program, project.brace_style);
        out.* = .{ .text = formatted, .changed = !std.mem.eql(u8, formatted, file.source.text) };
    }

    return .{ .arena_state = arena_state, .diagnostics = &.{}, .files = files_out };
}

/// Reserved rather than committed: the host maps a thread's stack lazily, so
/// the unused part costs address space and nothing else.
///
/// The evaluator's recursion guard is designed around a large thread stack, and
/// the debug stress case of 1,000 calls whose bodies nest 250 levels deep still
/// needs enough room for the recursive frames plus the expression tree itself.
const stack_size: usize = if (@sizeOf(usize) >= 8) 1024 * 1024 * 1024 else 32 * 1024 * 1024;

comptime {
    if (builtin.single_threaded) @compileError(
        "Emerald runs its pipeline on a thread with a large stack, so it cannot be built single-threaded.",
    );
}

fn onLargeStack(gpa: std.mem.Allocator, project: *const Project, streams: ?Streams, test_mode: bool, step_limit: ?usize) Error!Report {
    const Task = struct {
        gpa: std.mem.Allocator,
        project: *const Project,
        streams: ?Streams,
        test_mode: bool,
        step_limit: ?usize,
        result: Error!Report = undefined,

        fn go(task: *@This(), available: usize) void {
            task.result = analyze(task.gpa, task.project, task.streams, task.test_mode, task.step_limit, .here(available));
        }
    };

    // The calling thread only waits, so nothing is touched from two threads at
    // once.
    //
    // There is deliberately no fallback to the calling thread. Its stack size
    // is the host's choice, as little as 1 MiB, so the guard could not be told
    // honestly how much there is, and a program within section 7.2's
    // guarantees could fail or crash. Failing to start is the honest outcome.
    var task: Task = .{ .gpa = gpa, .project = project, .streams = streams, .test_mode = test_mode, .step_limit = step_limit };
    const thread = std.Thread.spawn(.{ .stack_size = stack_size }, Task.go, .{ &task, stack_size }) catch
        return error.StackUnavailable;
    thread.join();
    return task.result;
}

/// Runs each stage in order, stopping at the first that reports anything.
///
/// Stopping is deliberate. Section 17.2 asks for one primary error rather than a
/// cascade, and a parser fed a broken token stream produces exactly that cascade.
fn analyze(
    gpa: std.mem.Allocator,
    project: *const Project,
    streams: ?Streams,
    test_mode: bool,
    step_limit: ?usize,
    stack: Interpreter.StackLimit,
) Error!Report {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    // A stage runs over every file before the next one starts, so a project
    // reports every encoding problem, then every lexical one, and so on. That
    // is section 17.2's rule about cascades, applied to a project: one stage's
    // worth of problems at a time.
    var found: std.ArrayList(Diagnostic) = .empty;

    // Encoding. Lexing bytes that are not text would only invent confusion on
    // top of a problem the reader has to fix first.
    for (project.files, 0..) |file, index| {
        const span = Source.findInvalidUtf8(file.source.text) orelse continue;
        try found.append(arena, .{
            .message = "this is not valid UTF-8 text",
            .span = span,
            .help = "Emerald source files are always UTF-8. Re-save this file as UTF-8.",
            .file = @intCast(index),
        });
    }
    if (found.items.len != 0) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena) };
    }

    const bad_directory_count = project.bad_directories.len;

    // A directory whose name cannot become a namespace is reported against a
    // file inside it, but it is not fatal to the rest of the project: valid
    // files and malformed declarations still need their own diagnostics.
    for (project.bad_directories) |bad| {
        try found.append(arena, .{
            .message = try std.fmt.allocPrint(
                arena,
                "the directory `{s}` cannot be a namespace",
                .{bad.path},
            ),
            .span = .{ .start = 0, .end = 0 },
            .help = "A directory name becomes a namespace, so it has to read as one: letters, digits and `_`, starting with a letter. Rename it, as in `shapes/`.",
            .file = bad.file,
        });
    }

    // The prelude's declarations are written in Emerald and go through every
    // stage as one more file. It comes last, so every file of the program
    // keeps the index its diagnostics are rendered against, and nothing is
    // ever reported against the prelude itself.
    var prelude_source = try Source.init(gpa, "prelude.em", prelude_text);
    defer prelude_source.deinit(gpa);
    const files = try arena.alloc(Project.File, project.files.len + 1);
    @memcpy(files[0..project.files.len], project.files);
    files[project.files.len] = .{ .source = prelude_source, .namespace = Resolver.prelude_namespace, .entry = false };

    // Every file's tokens are held at once, because the parser for one file may
    // still be reading them while another is parsed.
    const tokenized = try gpa.alloc(Lexer.Tokenized, files.len);
    var lexed: usize = 0;
    defer {
        for (tokenized[0..lexed]) |*one| one.deinit(gpa);
        gpa.free(tokenized);
    }
    while (lexed < files.len) : (lexed += 1) {
        tokenized[lexed] = try Lexer.tokenize(gpa, &files[lexed].source);
        try appendFrom(arena, &found, tokenized[lexed].diagnostics, @intCast(lexed));
    }
    if (found.items.len > bad_directory_count) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena) };
    }

    const parsed = try gpa.alloc(Parser.Parsed, files.len);
    var parsed_count: usize = 0;
    defer {
        for (parsed[0..parsed_count]) |*one| one.deinit();
        gpa.free(parsed);
    }
    while (parsed_count < files.len) : (parsed_count += 1) {
        parsed[parsed_count] = try Parser.parse(gpa, &files[parsed_count].source, tokenized[parsed_count].tokens);
        try appendFrom(arena, &found, parsed[parsed_count].diagnostics, @intCast(parsed_count));
    }
    if (found.items.len > bad_directory_count) {
        return .{ .arena_state = arena_state, .diagnostics = try found.toOwnedSlice(arena) };
    }

    const programs = try gpa.alloc(Ast.Program, files.len);
    defer gpa.free(programs);
    for (parsed, programs) |one, *program| program.* = one.program;

    // Resolution, checking and execution each see the whole project at once,
    // because a name in one file can only be understood against the rest.
    var resolved = try Resolver.resolve(gpa, files, programs, project.enclosing_project);
    defer resolved.deinit();
    for (resolved.diagnostics) |diagnostic| std.debug.assert(diagnostic.file < project.files.len);
    if (!resolved.ok()) {
        const copies = try dupeDiagnostics(arena, resolved.diagnostics);
        return .{ .arena_state = arena_state, .diagnostics = copies };
    }

    // The resolver's facts stay valid here: `resolved` is released only when
    // this function returns.
    var checked = try Checker.check(gpa, files, programs, resolved.facts);
    defer checked.deinit();
    for (checked.diagnostics) |diagnostic| std.debug.assert(diagnostic.file < project.files.len);
    if (!checked.ok()) {
        const copies = try dupeDiagnostics(arena, checked.diagnostics);
        return .{ .arena_state = arena_state, .diagnostics = copies };
    }
    // `ok()` above only stopped for an error, so only warnings can remain.
    // They do not block checking or execution, but still have to reach the
    // caller rather than being silently dropped.
    const warnings = try dupeDiagnostics(arena, checked.diagnostics);

    const running = streams orelse return .{ .arena_state = arena_state, .diagnostics = warnings };

    var outcome = try Interpreter.run(
        gpa,
        files,
        programs,
        &checked.signatures,
        &checked.literal_types,
        &checked.structs,
        &checked.changing_methods,
        &checked.method_calls,
        &checked.super_members,
        &checked.type_tests,
        &checked.type_names,
        &checked.trait_calls,
        resolved.facts,
        running.out,
        running.in,
        running.arguments,
        stack,
        test_mode,
        step_limit,
    );
    defer outcome.deinit();

    const failure = if (outcome.failure) |raised|
        try dupeDiagnostic(arena, raised)
    else
        null;

    const test_failures = try dupeDiagnostics(arena, outcome.test_failures);
    return .{ .arena_state = arena_state, .diagnostics = warnings, .failure = failure, .test_failures = test_failures, .test_count = outcome.test_count, .exit_code = outcome.exit_code };
}

/// Copies one file's diagnostics into the report's arena, stamping the file
/// they came from. A stage that works on one file at a time does not know its
/// index, so it is filled in here, where the loop does.
fn appendFrom(
    arena: std.mem.Allocator,
    into: *std.ArrayList(Diagnostic),
    diagnostics: []const Diagnostic,
    file: u32,
) !void {
    for (diagnostics) |diagnostic| {
        var copy = try dupeDiagnostic(arena, diagnostic);
        copy.file = file;
        try into.append(arena, copy);
    }
}

/// Diagnostics point at text owned by the stage that produced them, and every
/// stage is released as soon as the next one starts, so they are copied into the
/// report's own arena.
fn dupeDiagnostic(arena: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
    const trace = try arena.alloc(Diagnostic.Frame, diagnostic.trace.len);
    for (diagnostic.trace, trace) |frame, *copy| {
        copy.* = frame;
        copy.function = try arena.dupe(u8, frame.function);
    }
    // Copied whole and then patched, so a field added to `Diagnostic` is
    // carried across rather than silently dropped here.
    var copy = diagnostic;
    copy.message = try arena.dupe(u8, diagnostic.message);
    copy.help = try arena.dupe(u8, diagnostic.help);
    copy.trace = trace;
    if (diagnostic.related) |related| {
        const related_copy = try arena.create(Diagnostic);
        related_copy.* = try dupeDiagnostic(arena, related.*);
        copy.related = related_copy;
    }
    return copy;
}

fn dupeDiagnostics(arena: std.mem.Allocator, diagnostics: []const Diagnostic) ![]const Diagnostic {
    const copies = try arena.alloc(Diagnostic, diagnostics.len);
    for (diagnostics, copies) |diagnostic, *copy| copy.* = try dupeDiagnostic(arena, diagnostic);
    return copies;
}

test "analyzeProject exposes every expression's type, keyed by expression and its own file" {
    const gpa = testing.allocator;
    var source = try Source.init(gpa, "test.em", "var total = 5\nprint(total)\n");
    defer source.deinit(gpa);
    // `files` is borrowed by `project` for the lone-file shape above, so it
    // has to outlive the `analyzeProject` call, exactly as `check` needs it to.
    var files = [_]Project.File{lone(&source)};
    const project = loneProject(&files);

    var analysis = (try analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    var found_int_literal = false;
    var iterator = analysis.checked.expression_types.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.data != .int_literal) continue;
        try testing.expectEqual(@as(u32, 0), entry.value_ptr.file);
        try testing.expectEqual(Type.int, entry.value_ptr.type);
        found_int_literal = true;
    }
    try testing.expect(found_int_literal);
}

test "analyzeProject returns null rather than checked detail when an earlier stage fails" {
    const gpa = testing.allocator;

    // A parse error: nothing ever reaches the checker.
    {
        var source = try Source.init(gpa, "test.em", "func f( {\n");
        defer source.deinit(gpa);
        var files = [_]Project.File{lone(&source)};
        const project = loneProject(&files);
        try testing.expectEqual(@as(?Analysis, null), try analyzeProject(gpa, &project));
    }

    // An unresolved name: the resolver stops it before checking runs.
    {
        var source = try Source.init(gpa, "test.em", "print(totally_undefined)\n");
        defer source.deinit(gpa);
        var files = [_]Project.File{lone(&source)};
        const project = loneProject(&files);
        try testing.expectEqual(@as(?Analysis, null), try analyzeProject(gpa, &project));
    }
}

test "a prelude type's display name stays valid after analyzeProject returns" {
    // Regression test: `RuntimeError` is declared in prelude.em, not the
    // program, and every declared name is a slice of its own file's source
    // rather than a copy. `Analysis` used to free the prelude's `Source`
    // before returning, which left a value's own type formatting readable
    // memory that was no longer prelude.em's text.
    const gpa = testing.allocator;
    var source = try Source.init(gpa, "test.em",
        \\try {
        \\    raise RuntimeError("boom")
        \\}
        \\catch error: RuntimeError {
        \\    print(error.message)
        \\}
        \\
    );
    defer source.deinit(gpa);
    var files = [_]Project.File{lone(&source)};
    const project = loneProject(&files);

    var analysis = (try analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    try testing.expect(analysis.ok());

    var found: ?Type = null;
    var iterator = analysis.checked.expression_types.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.*.data != .name) continue;
        if (!std.mem.eql(u8, entry.key_ptr.*.data.name, "error")) continue;
        found = entry.value_ptr.type;
    }

    const text = try std.fmt.allocPrint(gpa, "{f}", .{found.?});
    defer gpa.free(text);
    try testing.expectEqualStrings("RuntimeError", text);
}

const testing = std.testing;

test {
    _ = Source;
    _ = Diagnostic;
    _ = Token;
    _ = Lexer;
    _ = Ast;
    _ = Parser;
    _ = Resolver;
    _ = Type;
    _ = Checker;
    _ = Value;
    _ = Interpreter;
    _ = Heap;
    _ = unicode;
    _ = strings;
    _ = @import("arguments.zig");
}

/// Runs a program and returns what it printed. The caller owns the result.
fn runToString(gpa: std.mem.Allocator, text: []const u8, input: []const u8) ![]u8 {
    var source = try Source.init(gpa, "test.em", text);
    defer source.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var no_input: std.Io.Reader = .fixed(input);
    var report = try run(gpa, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    if (!report.ok()) {
        const problem = if (report.failure) |failure| failure else report.diagnostics[0];
        std.debug.print("unexpected: {s}\n", .{problem.message});
        return error.UnexpectedDiagnostic;
    }

    return out.toOwnedSlice();
}

fn expectOutput(text: []const u8, expected: []const u8) !void {
    return expectOutputWithInput(text, "", expected);
}

/// Runs a program that reads `input` through `input()`.
fn expectOutputWithInput(text: []const u8, input: []const u8, expected: []const u8) !void {
    const actual = try runToString(testing.allocator, text, input);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectFailure(text: []const u8, expected_message: []const u8) !void {
    var source = try Source.init(testing.allocator, "test.em", text);
    defer source.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    const problem = report.failure orelse
        if (report.diagnostics.len != 0) report.diagnostics[0] else return error.ExpectedAFailure;
    try testing.expectEqualStrings(expected_message, problem.message);
}

test "File read methods reject invalid UTF-8 as FileError" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "invalid.bin", .data = "\xff" });

    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/invalid.bin", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(absolute);
    const expected = try std.fmt.allocPrint(testing.allocator, "FileError: could not read as UTF-8 text `{s}`", .{absolute});
    defer testing.allocator.free(expected);

    // `absolute` is a real filesystem path, `\`-separated on Windows, so it
    // cannot be spliced into an Emerald string literal verbatim: `\a`, `\U`,
    // and the rest are not escapes the lexer recognizes.
    const literal = try escapeAsEmeraldStringLiteral(testing.allocator, absolute);
    defer testing.allocator.free(literal);

    for ([_][]const u8{ "File.read", "File.read_lines" }) |method| {
        const program = try std.fmt.allocPrint(testing.allocator, "{s}(\"{s}\")", .{ method, literal });
        defer testing.allocator.free(program);
        try expectFailure(program, expected);
    }
}

test "Directory.delete_recursive removes a populated tree and is idempotent on an already-gone path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "tree/nested");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "tree/nested/leaf.txt", .data = "hi" });

    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/tree", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(absolute);

    // Same reason as the UTF-8 test above: a real path may contain `\`,
    // which the lexer would otherwise read as an escape introducer.
    const literal = try escapeAsEmeraldStringLiteral(testing.allocator, absolute);
    defer testing.allocator.free(literal);

    const program = try std.fmt.allocPrint(
        testing.allocator,
        "print(Directory.exists?(\"{s}\"))\nDirectory.delete_recursive(\"{s}\")\nprint(Directory.exists?(\"{s}\"))\nDirectory.delete_recursive(\"{s}\")\nprint(\"still ok\")\n",
        .{ literal, literal, literal, literal },
    );
    defer testing.allocator.free(program);

    try expectOutput(program, "true\nfalse\nstill ok\n");

    // Independently confirms the whole tree is gone, not just what the
    // program's own `Directory.exists?` happened to report.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "tree/nested/leaf.txt", .{}));
}

fn escapeAsEmeraldStringLiteral(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(gpa);
    for (text) |byte| {
        if (byte == '\\' or byte == '"') try escaped.append(gpa, '\\');
        try escaped.append(gpa, byte);
    }
    return escaped.toOwnedSlice(gpa);
}

test "a step-limited run stops even when Emerald catches ordinary errors" {
    var source = try Source.init(testing.allocator, "test.em",
        \\try {
        \\    while true {
        \\    }
        \\}
        \\catch error {
        \\    print("caught")
        \\}
    );
    defer source.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try runWithStepLimit(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input }, 12);
    defer report.deinit();

    try testing.expect(report.failure != null);
    try testing.expectEqualStrings("this run exceeded its execution limit of 12 steps", report.failure.?.message);
    try testing.expectEqualStrings("", out.written());
}

test "section 15.2 exit reports its requested status after finally" {
    var source = try Source.init(testing.allocator, "test.em", "try {\n    exit(42)\n}\nfinally {\n    print(\"cleanup\")\n}\n");
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();
    try testing.expect(report.ok());
    try testing.expectEqual(@as(?u8, 42), report.exit_code);
    try testing.expectEqualStrings("cleanup\n", out.written());
}

test "section 14.1's Program.arguments carries the program's own CLI arguments" {
    var source = try Source.init(testing.allocator, "test.em", "print(Program.arguments, Program.arguments.count)\n");
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input, .arguments = &.{ "one", "two" } });
    defer report.deinit();
    try testing.expect(report.ok());
    try testing.expectEqualStrings("[\"one\", \"two\"] 2\n", out.written());
}

test "Program.arguments is empty by default, and each read is independent" {
    try expectOutput("print(Program.arguments)\n", "[]\n");
    // A `List` is copy-on-write value semantics (8.2), so mutating one read
    // never shows up in another.
    try expectOutput(
        "var mine = Program.arguments\nmine.append(\"extra\")\nprint(mine, Program.arguments)\n",
        "[\"extra\"] []\n",
    );
}

test "section 8.2's dictionary literal, lookup, and assignment" {
    try expectOutput("var ages = [\"Ava\": 12, \"Noah\": 13]\nprint(ages)\nprint(ages.count)\n", "[\"Ava\": 12, \"Noah\": 13]\n2\n");
    // Section 8.3: a lookup can miss, so it produces an optional.
    try expectOutput("const ages = [\"Ava\": 12]\nprint(ages[\"Ava\"], ages[\"Zed\"], ages[\"Zed\"].or(0))\n", "12 nothing 0\n");
    // Assignment inserts or replaces, and a replaced value keeps its place.
    try expectOutput(
        "var ages = [\"Ava\": 12, \"Noah\": 13]\nages[\"Mia\"] = 9\nages[\"Ava\"] = 20\nprint(ages)\n",
        "[\"Ava\": 20, \"Noah\": 13, \"Mia\": 9]\n",
    );
}

test "section 8.2's empty literals take their kind from the expected type" {
    try expectOutput("const names: List[String] = []\nprint(names)\n", "[]\n");
    try expectOutput("const ages: Dict[String, Int] = []\nprint(ages)\n", "[:]\n");
    try expectOutput("const seen: Set[String] = []\nprint(seen)\n", "{}\n");
    try expectFailure("var names = []\n", "an empty list needs a type");
}

test "section 8.2's set literal is bracketed where a set is expected" {
    try expectOutput("const seen: Set[String] = [\"red\", \"green\"]\nprint(seen)\n", "{\"red\", \"green\"}\n");
    // Section 8.4: repeats collapse to one, and the first keeps its position.
    try expectOutput("const seen: Set[Int] = [1, 2, 1, 3]\nprint(seen, seen.count)\n", "{1, 2, 3} 3\n");
    // Without an expected set type a bracketed list is a list, so 8.2 names
    // the conversion.
    try expectOutput("print([1, 2, 2, 3].to_set())\n", "{1, 2, 3}\n");
    // Only a literal takes its kind this way.
    try expectFailure(
        "const names = [\"a\"]\nconst seen: Set[String] = names\n",
        "this is List[String], but `seen` was declared as Set[String]",
    );
}

test "section 8.4 compares a dictionary by contents and a set by membership" {
    try expectOutput("print([\"a\": 1, \"b\": 2] == [\"b\": 2, \"a\": 1])\n", "true\n");
    try expectOutput("print([\"a\": 1] == [\"a\": 2], [\"a\": 1] == [\"a\": 1, \"b\": 2])\n", "false false\n");
    try expectOutput(
        "const one: Set[Int] = [1, 2, 3]\nconst two: Set[Int] = [3, 2, 1]\nprint(one == two)\n",
        "true\n",
    );
}

test "section 8.4 visits a dictionary and a set in insertion order" {
    try expectOutput(
        "for (name, age) in [\"Ava\": 12, \"Noah\": 13] {\n    print(name, age)\n}\n",
        "Ava 12\nNoah 13\n",
    );
    try expectOutput(
        "const seen: Set[String] = [\"red\", \"green\"]\nfor colour in seen {\n    print(colour)\n}\n",
        "red\ngreen\n",
    );
    // Section 8.6: a dictionary's block receives the entry as one tuple.
    try expectOutput(
        "print([\"a\": 1, \"b\": 2].map { (name, value) => \"#{name}=#{value}\" })\n",
        "[\"a=1\", \"b=2\"]\n",
    );
}

test "section 8.5's dictionary vocabulary" {
    const ages = "var ages = [\"Ava\": 12, \"Noah\": 13]\n";
    try expectOutput(ages ++ "print(ages.keys(), ages.values())\n", "[\"Ava\", \"Noah\"] [12, 13]\n");
    try expectOutput(ages ++ "print(ages.entries())\n", "[(\"Ava\", 12), (\"Noah\", 13)]\n");
    try expectOutput(ages ++ "print(ages.contains_key?(\"Ava\"), ages.contains_key?(\"Zed\"))\n", "true false\n");
    try expectOutput(ages ++ "print(ages.contains_value?(13), ages.contains_value?(99))\n", "true false\n");
    try expectOutput(ages ++ "print(ages.empty?(), ages.remove(\"Ava\"), ages.remove(\"Zed\"), ages)\n", "false 12 nothing [\"Noah\": 13]\n");
    try expectOutput(
        ages ++ "ages.merge([\"Zed\": 40, \"Ava\": 1])\nprint(ages)\n",
        "[\"Ava\": 1, \"Noah\": 13, \"Zed\": 40]\n",
    );
}

test "section 8.5's set vocabulary" {
    const seen = "var seen: Set[String] = [\"red\"]\n";
    try expectOutput(seen ++ "seen.add(\"blue\")\nseen.add(\"red\")\nprint(seen, seen.count)\n", "{\"red\", \"blue\"} 2\n");
    try expectOutput(seen ++ "print(seen.contains?(\"red\"), seen.contains?(\"blue\"))\n", "true false\n");
    try expectOutput(seen ++ "seen.remove(\"red\")\nprint(seen, seen.empty?())\n", "{} true\n");
}

test "section 8.1 gives a dictionary and a set value semantics" {
    try expectOutput(
        "var a = [\"x\": 1]\nvar b = a\nb[\"y\"] = 2\nprint(a, b)\n",
        "[\"x\": 1] [\"x\": 1, \"y\": 2]\n",
    );
    try expectOutput(
        "var a: Set[Int] = [1]\nvar b = a\nb.add(2)\nprint(a, b)\n",
        "{1} {1, 2}\n",
    );
    // Section 4.3: a `const` cannot be changed either way.
    try expectFailure("const ages = [\"a\": 1]\nages[\"b\"] = 2\n", "`ages` is a `const`, so its contents cannot change");
    try expectFailure("const seen: Set[Int] = [1]\nseen.add(2)\n", "`seen` is a `const`, so its contents cannot change");
}

test "section 8.3 accepts only keys that can be found again" {
    try expectFailure("var bad: Dict[List[Int], String] = []\n", "List[Int] cannot be a dictionary key");
    try expectFailure("var bad: Set[List[Int]] = []\n", "a set cannot hold List[Int]");
    try expectFailure("var bad: Dict[Int?, String] = []\n", "Int? cannot be a dictionary key");
    // A tuple qualifies when its positions do.
    try expectOutput(
        "var byPair: Dict[(String, Int), String] = [(\"a\", 1): \"first\"]\nprint(byPair[(\"a\", 1)], byPair[(\"b\", 2)])\n",
        "first nothing\n",
    );
}

test "section 9.2's normalized equality reaches dictionary keys and sets" {
    // The same text composed, and as `e` plus a combining acute accent.
    try expectOutput("const seen: Set[String] = [\"caf\u{e9}\"]\nprint(seen.contains?(\"cafe\\u{301}\"))\n", "true\n");
    try expectOutput("const byName = [\"caf\u{e9}\": 1]\nprint(byName[\"cafe\\u{301}\"])\n", "1\n");
}

test "a dictionary key is looked up at the type the dictionary holds" {
    try expectFailure("const ages = [\"Ava\": 12]\nprint(ages[1])\n", "this is Int, but the dictionary's keys are String");
    // Section 4.4: a whole number reaches a `Float` key by widening.
    try expectOutput("var rates: Dict[Float, String] = [1.5: \"low\"]\nrates[2] = \"high\"\nprint(rates, rates[2.0])\n", "[1.5: \"low\", 2.0: \"high\"] high\n");
}

test "section 8.5 names a dictionary's and a set's operations apart" {
    try expectFailure("const ages = [\"a\": 1]\nprint(ages.get(\"a\"))\n", "Dict[String, Int] has no method `get`");
    try expectFailure("const ages = [\"a\": 1]\nprint(ages.contains?(\"a\"))\n", "Dict[String, Int] has no method `contains?`");
    try expectFailure("const seen: Set[Int] = [1]\nprint(seen.contains_key?(1))\n", "Set[Int] has no method `contains_key?`");
    try expectFailure("const ages = [\"a\": 1]\nprint(ages.first)\n", "Dict[String, Int] has no property `first`");
}

test "a compound assignment needs an entry that is already there" {
    try expectOutput("var counts = [\"a\": 1]\ncounts[\"a\"] += 10\nprint(counts)\n", "[\"a\": 11]\n");
    try expectFailure("var counts = [\"a\": 1]\ncounts[\"b\"] += 1\n", "there is no entry for \"b\"");
}

test "section 8.2's tuple literal, and its positions" {
    try expectOutput("const entry = (\"score\", 10)\nprint(entry)\nprint(entry.0, entry.1)\n", "(\"score\", 10)\nscore 10\n");
    // Nested positions, which the lexer hands over as one decimal number.
    try expectOutput("const deep = ((1, (2, 3)), 4)\nprint(deep.0.1.0, deep.1)\n", "2 4\n");
    // A tuple's elements are quoted like a list's, so `("a, b")` and
    // `("a", "b")` cannot be mistaken for each other.
    try expectOutput("print((\"a, b\", 1), (\"a\", \"b\"))\n", "(\"a, b\", 1) (\"a\", \"b\")\n");
}

test "section 8.2 needs at least two positions, so one is a group" {
    try expectOutput("const grouped = (1)\nprint(grouped + 1)\n", "2\n");
    // A trailing comma never changes an expression's type.
    try expectOutput("const grouped = (1,)\nprint(grouped + 1)\n", "2\n");
    try expectFailure("print(())\n", "`()` is not a value");
    try expectFailure("var (only) = 1\n", "a tuple is unpacked into at least two names");
    try expectFailure("var pair: (Int) = 1\n", "a tuple type needs at least two positions");
}

test "section 8.4 compares tuples position by position" {
    try expectOutput("print((\"a\", 1) == (\"a\", 1), (\"a\", 1) == (\"a\", 2))\n", "true false\n");
    // Recursively, through whatever the positions hold.
    try expectOutput("print(([1, 2], (\"x\", 3)) == ([1, 2], (\"x\", 3)))\n", "true\n");
}

test "section 8.2 unpacks a tuple wherever names are introduced" {
    try expectOutput("var (name, age) = (\"Ada\", 36)\nprint(name, age)\n", "Ada 36\n");
    try expectOutput("const (name, _) = (\"Ada\", 36)\nprint(name)\n", "Ada\n");
    try expectOutput(
        "for (letter, number) in [(\"a\", 1), (\"b\", 2)] {\n    print(letter, number)\n}\n",
        "a 1\nb 2\n",
    );
    try expectOutput(
        "print([(\"a\", 1)].map { (letter, number) => letter + number.to_string() })\n",
        "[\"a1\"]\n",
    );
}

test "section 8.2's assignment unpacking evaluates the right side first" {
    try expectOutput("var a = 1\nvar b = 2\n(a, b) = (b, a)\nprint(a, b)\n", "2 1\n");
    // `_` discards its position, and the names must already exist.
    try expectOutput("var a = 1\nvar b = 2\n(a, _) = (9, 9)\nprint(a, b)\n", "9 2\n");
    try expectFailure("const a = 1\nvar b = 2\n(a, b) = (b, a)\n", "`a` cannot be reassigned");
    try expectFailure("var a = 1\n(a, b) = (1, 2)\n", "`b` is not defined");
    try expectFailure("var a = 1\n(a, b.c) = (1, 2)\n", "only a name can be assigned to here");
}

test "unpacking checks the shape before it binds anything" {
    try expectFailure("var (a, b, c) = (1, 2)\n", "this unpacks 3 names, but (Int, Int) has 2 positions");
    try expectFailure("var (a, b) = 5\n", "this is Int, which is not a tuple");
    try expectFailure(
        "const pair: (Int, Int)? = nothing\nvar (a, b) = pair\n",
        "this is (Int, Int)?, which may be absent, so it cannot be unpacked",
    );
}

test "a tuple position is checked where it is written" {
    try expectFailure("const pair = (1, 2)\nprint(pair.2)\n", "(Int, Int) has no position 2");
    try expectFailure("const pair = (1, 2)\nprint(pair.count)\n", "a tuple has no `count`");
    try expectFailure("print([1, 2].0)\n", "`List[Int]` has no positions");
}

test "section 4.4 widens a tuple position wherever one is expected" {
    try expectOutput("const rates: (Float, Int) = (1, 2)\nprint(rates)\n", "(1.0, 2)\n");
    try expectOutput(
        "func make(): (Float, String) {\n    return (3, \"x\")\n}\nprint(make())\n",
        "(3.0, \"x\")\n",
    );
    try expectOutput(
        "func take(pair: (Float, Int)) {\n    print(pair)\n}\ntake((7, 8))\n",
        "(7.0, 8)\n",
    );
    try expectOutput("const many: List[(Float, Int)] = [(1, 2)]\nprint(many)\n", "[(1.0, 2)]\n");
}

test "a tuple is a value, so holding one cannot change another" {
    // Nothing can assign to a position, so there is nothing to copy for, but
    // the list a tuple holds keeps its own value semantics.
    try expectOutput(
        "const pair = ([1, 2], 3)\nvar items = pair.0\nitems.append(9)\nprint(pair.0, items)\n",
        "[1, 2] [1, 2, 9]\n",
    );
}

test "a tuple carries whatever it holds, including a block" {
    try expectOutput(
        "const pair = (2, { value: Int => value * 3 })\nprint(pair.1(pair.0))\n",
        "6\n",
    );
}

/// One file of a project written inline, for the tests below. A real project
/// comes from directories; these state the same thing directly so a test does
/// not need a temporary directory to exercise namespaces.
const ProjectFile = struct {
    path: []const u8,
    namespace: []const u8 = "",
    text: []const u8,
};

/// Builds a project from files written inline. The first is the entry, as
/// section 14.1 makes `main.em`.
fn buildProject(gpa: std.mem.Allocator, files: []const ProjectFile) !Project {
    const built = try gpa.alloc(Project.File, files.len);
    errdefer gpa.free(built);
    for (files, built, 0..) |file, *slot, index| {
        slot.* = .{
            .source = try Source.init(gpa, file.path, file.text),
            .namespace = try gpa.dupe(u8, file.namespace),
            .entry = index == 0,
        };
    }
    return .{ .files = built, .entry = 0, .bad_directories = &.{} };
}

/// Small enough to keep `checkAllAllocationFailures`'s per-allocation-point
/// rerun affordable, but wide enough to reach a struct declaration and
/// construction, a method call, a list literal and iteration, arithmetic,
/// and string interpolation in one program — well past `Checker.zig`'s and
/// `Interpreter.zig`'s bare-statement paths that a one-line program never
/// touches.
const allocation_failure_program =
    \\struct Point {
    \\    var x: Int
    \\    var y: Int
    \\
    \\    func sum(): Int {
    \\        return self.x + self.y
    \\    }
    \\}
    \\
    \\var points = [Point(1, 2), Point(3, 4)]
    \\var total = 0
    \\for point in points {
    \\    total = total + point.sum()
    \\}
    \\print("Total: #{total}")
    \\
;

test "checking releases every allocation failure" {
    var project = try buildProject(testing.allocator, &.{
        .{ .path = "main.em", .text = allocation_failure_program },
    });
    defer project.deinit(testing.allocator);

    const Work = struct {
        fn run(gpa: std.mem.Allocator, input: *const Project) !void {
            var report = try checkProject(gpa, input);
            defer report.deinit();
            if (!report.ok()) return error.UnexpectedDiagnostic;
        }
    };

    try testing.checkAllAllocationFailures(testing.allocator, Work.run, .{&project});
}

test "running releases every allocation failure" {
    var project = try buildProject(testing.allocator, &.{
        .{ .path = "main.em", .text = allocation_failure_program },
    });
    defer project.deinit(testing.allocator);

    const Work = struct {
        fn run(gpa: std.mem.Allocator, input: *const Project) !void {
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var no_input: std.Io.Reader = .fixed("");
            // An `Allocating` writer can only ever fail by allocation, so its
            // `error.WriteFailed` (`std.Io.Writer.Error`, which `RunError`
            // legitimately includes for a real, non-memory-backed stream)
            // is exactly the failure this harness is injecting.
            var report = runProject(gpa, input, .{ .out = &out.writer, .in = &no_input }) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
            defer report.deinit();
            if (!report.ok()) return error.UnexpectedDiagnosticOrFailure;
        }
    };

    try testing.checkAllAllocationFailures(testing.allocator, Work.run, .{&project});
}

fn expectProjectOutput(files: []const ProjectFile, expected: []const u8) !void {
    var project = try buildProject(testing.allocator, files);
    defer project.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");

    var report = try runProject(testing.allocator, &project, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    if (report.diagnostics.len != 0) {
        const sources = try project.sources(testing.allocator);
        defer testing.allocator.free(sources);
        const rendered = try report.diagnostics[0].renderAlloc(testing.allocator, sources);
        defer testing.allocator.free(rendered);
        std.debug.print("\nexpected it to run, but:\n{s}", .{rendered});
        return error.ExpectedItToRun;
    }
    if (report.failure) |failure| {
        std.debug.print("\nexpected it to run, but it failed: {s}\n", .{failure.message});
        return error.ExpectedItToRun;
    }
    try testing.expectEqualStrings(expected, out.written());
}

/// Checks a project and returns the first problem's message and the file it was
/// reported in, which is the part a single-file test cannot cover.
fn expectProjectProblem(
    files: []const ProjectFile,
    expected_file: []const u8,
    expected_message: []const u8,
) !void {
    var project = try buildProject(testing.allocator, files);
    defer project.deinit(testing.allocator);

    var report = try checkProject(testing.allocator, &project);
    defer report.deinit();

    if (report.diagnostics.len == 0) return error.ExpectedAProblem;
    const problem = report.diagnostics[0];
    try testing.expectEqualStrings(expected_message, problem.message);
    try testing.expectEqualStrings(expected_file, project.files[problem.file].source.path);
}

/// The same for a problem found only while running.
fn expectProjectFailure(
    files: []const ProjectFile,
    expected_file: []const u8,
    expected_message: []const u8,
) !void {
    var project = try buildProject(testing.allocator, files);
    defer project.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");

    var report = try runProject(testing.allocator, &project, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    const problem = report.failure orelse
        if (report.diagnostics.len != 0) report.diagnostics[0] else return error.ExpectedAFailure;
    try testing.expectEqualStrings(expected_message, problem.message);
    try testing.expectEqualStrings(expected_file, project.files[problem.file].source.path);
}

const shapes_area: ProjectFile = .{
    .path = "shapes/rectangle.em",
    .namespace = "Shapes",
    .text = "func area(width: Int, height: Int): Int {\n    return width * height\n}\n",
};

test "a name in another directory is reached through its namespace" {
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "print(Shapes.area(4, 3))\n" },
        shapes_area,
    }, "12\n");
}

test "`using` makes a namespace's names directly visible" {
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "using Shapes\nprint(area(4, 3))\n" },
        shapes_area,
    }, "12\n");
}

test "`using` can alias a namespace or one name in it" {
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "using S = Shapes\nprint(S.area(4, 3))\n" },
        shapes_area,
    }, "12\n");
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "using rectangle = Shapes.area\nprint(rectangle(4, 3))\n" },
        shapes_area,
    }, "12\n");
}

test "files in one directory see each other without qualification" {
    // In file order the helper is walked second, so this also covers a name
    // being visible whichever order the files happen to be walked in.
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "print(Shapes.area(4, 3))\n" },
        .{
            .path = "shapes/area.em",
            .namespace = "Shapes",
            .text = "func area(width: Int, height: Int): Int {\n    return scale(width * height)\n}\n",
        },
        .{
            .path = "shapes/scale.em",
            .namespace = "Shapes",
            .text = "const factor = 2\nfunc scale(value: Int): Int {\n    return value * factor\n}\n",
        },
    }, "24\n");
}

test "section 14.2 keeps a leading underscore private to its own file" {
    try expectProjectProblem(&.{
        .{ .path = "main.em", .text = "print(Shapes._twice(2))\n" },
        .{
            .path = "shapes/rectangle.em",
            .namespace = "Shapes",
            .text = "func _twice(value: Int): Int {\n    return value * 2\n}\n",
        },
    }, "main.em", "`_twice` is private to the file that declares it");

    // Two files may each declare one, because the name is the file's.
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "print(Shapes.area(), Sizes.width())\n" },
        .{
            .path = "shapes/a.em",
            .namespace = "Shapes",
            .text = "func area(): Int {\n    return _value()\n}\nfunc _value(): Int {\n    return 1\n}\n",
        },
        .{
            .path = "sizes/b.em",
            .namespace = "Sizes",
            .text = "func width(): Int {\n    return _value()\n}\nfunc _value(): Int {\n    return 2\n}\n",
        },
    }, "1 2\n");
}

test "two files in one directory cannot declare the same public name" {
    try expectProjectProblem(&.{
        .{ .path = "main.em", .text = "print(Shapes.area(4, 3))\n" },
        shapes_area,
        .{
            .path = "shapes/square.em",
            .namespace = "Shapes",
            .text = "func area(side: Int): Int {\n    return side * side\n}\n",
        },
    }, "shapes/square.em", "`area` is already declared in `shapes/rectangle.em`");
}

test "section 14.1 gives only the entry file a top level that runs" {
    try expectProjectProblem(&.{
        .{ .path = "main.em", .text = "print(Shapes.area(4, 3))\n" },
        .{
            .path = "shapes/rectangle.em",
            .namespace = "Shapes",
            .text = "print(\"loaded\")\nfunc area(width: Int, height: Int): Int {\n    return width * height\n}\n",
        },
    }, "shapes/rectangle.em", "this would never run");

    // And so a binding there has nowhere to be assigned but its declaration.
    try expectProjectProblem(&.{
        .{ .path = "main.em", .text = "print(Shapes.total)\n" },
        .{ .path = "shapes/total.em", .namespace = "Shapes", .text = "var total: Int\n" },
    }, "shapes/total.em", "`total` needs its value here");
}

test "section 14.1 initializes a module file once, on first use" {
    try expectProjectOutput(&.{
        .{
            .path = "main.em",
            .text = "print(\"start\")\nprint(Store.label)\nprint(Store.label)\nprint(Store.shout())\n",
        },
        .{
            .path = "store/label.em",
            .namespace = "Store",
            .text =
            \\const label = build()
            \\
            \\func build(): String {
            \\    print("  building")
            \\    return "ready"
            \\}
            \\
            \\func shout(): String {
            \\    return label.upper()
            \\}
            \\
            ,
        },
    }, "start\n  building\nready\nready\nREADY\n");
}

test "project diagnostics keep bad directories and malformed source together" {
    var project = try buildProject(testing.allocator, &.{
        .{ .path = "main.em", .text = "func bad(1,\nvar ok = 2\n" },
        .{ .path = "2bad/helper.em", .namespace = "", .text = "var helper = 2\n" },
    });
    defer project.deinit(testing.allocator);
    const bad_path = try testing.allocator.dupe(u8, "2bad");
    project.bad_directories = try testing.allocator.dupe(Project.BadDirectory, &.{.{ .path = bad_path, .file = 1 }});

    var report = try checkProject(testing.allocator, &project);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.diagnostics.len);
    try testing.expectEqualStrings("the directory `2bad` cannot be a namespace", report.diagnostics[0].message);
    try testing.expectEqualStrings("main.em", project.files[report.diagnostics[1].file].source.path);
}

test "section 14.1 reports a cycle that reaches an unfinished binding" {
    try expectProjectFailure(&.{
        .{ .path = "main.em", .text = "print(First.value)\n" },
        .{ .path = "first/one.em", .namespace = "First", .text = "const value = Second.value\n" },
        .{ .path = "second/two.em", .namespace = "Second", .text = "const value = First.value\n" },
    }, "second/two.em", "`first/one.em` is still being set up, so `First.value` cannot be read yet");
}

test "a runtime error names the file each frame is in" {
    var project = try buildProject(testing.allocator, &.{
        .{ .path = "main.em", .text = "print(Math.halve(10, 0))\n" },
        .{
            .path = "math/divide.em",
            .namespace = "Math",
            .text = "func halve(value: Int, by: Int): Int {\n    return value // by\n}\n",
        },
    });
    defer project.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try runProject(testing.allocator, &project, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    const failure = report.failure orelse return error.ExpectedAFailure;
    try testing.expectEqualStrings("math/divide.em", project.files[failure.file].source.path);
    try testing.expectEqual(@as(usize, 1), failure.trace.len);
    // The call is in the caller's file, not the callee's.
    try testing.expectEqualStrings("main.em", project.files[failure.trace[0].file].source.path);
}

test "a block reads its own file's names wherever it is called" {
    // A block written in `main.em` and called from inside `tools/`, and one
    // written in `tools/` and called from `main.em`. Each reads a module-level
    // name of the file it was written in, which is what makes this a question
    // about where a block comes from rather than where it runs.
    try expectProjectOutput(&.{
        .{
            .path = "main.em",
            // Deliberately without `using Tools`: that would put `factor` in
            // this file's names too, and then the block would read the right
            // value whichever file it was taken to be from.
            .text =
            \\const scale = 10
            \\const triple = Tools.multiplier()
            \\
            \\print(Tools.apply([1, 2]) { value => value * scale })
            \\print([1, 2].map(triple))
            \\
            ,
        },
        .{
            .path = "tools/apply.em",
            .namespace = "Tools",
            .text =
            \\const factor = 3
            \\
            \\func apply(values: List[Int], block: func(Int): Int): List[Int] {
            \\    return values.map(block)
            \\}
            \\
            \\func multiplier(): func(Int): Int {
            \\    return { value => value * factor }
            \\}
            \\
            ,
        },
    }, "[10, 20]\n[3, 6]\n");
}

test "a local shadows a name its namespace declares" {
    try expectProjectOutput(&.{
        .{ .path = "main.em", .text = "print(Shapes.describe())\n" },
        .{
            .path = "shapes/describe.em",
            .namespace = "Shapes",
            .text = "const unit = \"cm\"\nfunc describe(): String {\n    const unit = \"mm\"\n    return unit\n}\n",
        },
    }, "mm\n");
}

test "the first milestone expression" {
    try expectOutput("print(2 + 3 * 4)\n", "14\n");
}

test "precedence and grouping" {
    try expectOutput("print((2 + 3) * 4)\n", "20\n");
    try expectOutput("print(10 - 2 - 3)\n", "5\n"); // left associative
    try expectOutput("print(2 + 3 * 4 - 6 / 3)\n", "12.0\n"); // `/` makes it a Float
}

test "exponentiation binds tighter than unary minus and associates right to left" {
    try expectOutput("print(-2 ** 2)\n", "-4\n");
    try expectOutput("print(2 ** 3 ** 2)\n", "512\n");
    try expectOutput("print((-2) ** 2)\n", "4\n");
    try expectOutput("print(2.0 ** -1)\n", "0.5\n");
}

test "exponentiation of two Ints is an Int, and a Float operand makes a Float" {
    try expectOutput("print(2 ** 10)\n", "1024\n");
    try expectOutput("var side = 7\nvar area: Int = side ** 2\nprint(area)\n", "49\n");
    try expectOutput("print(2 ** 0.5 > 1.41, 2.0 ** 3)\n", "true 8.0\n");
    try expectOutput("print(0 ** 0, (-1) ** 999999999999)\n", "1 -1\n");
    // The minimum Int is reachable exactly.
    try expectOutput("print((-2) ** 63)\n", "-9223372036854775808\n");
    try expectFailure("print(2 ** 63)\n", "exponentiation of 2 and 63 overflows Int");
    try expectFailure("print(2 ** -1)\n", "an Int cannot be raised to the negative power -1");
}

test "ordinary division always produces a Float" {
    try expectOutput("print(6 / 3)\n", "2.0\n");
    try expectOutput("print(7 / 2)\n", "3.5\n");
}

test "floor division rounds toward negative infinity" {
    try expectOutput("print(7 // 2)\n", "3\n");
    try expectOutput("print(-7 // 2)\n", "-4\n");
    try expectOutput("print(7 // -2)\n", "-4\n");
    try expectOutput("print(7.0 // 2)\n", "3.0\n");
}

test "remainder pairs with floor division and takes the divisor's sign" {
    try expectOutput("print(7 % 3)\n", "1\n");
    try expectOutput("print(-7 % 3)\n", "2\n");
    try expectOutput("print(7 % -3)\n", "-2\n");
}

test "the floor division law holds for the signs that make it interesting" {
    // a == (a // b) * b + (a % b)
    try expectOutput("print(-7 // 3 * 3 + -7 % 3)\n", "-7\n");
    try expectOutput("print(7 // -3 * -3 + 7 % -3)\n", "7\n");
}

test "an Int and a Float widen to Float" {
    try expectOutput("print(1 + 2.5)\n", "3.5\n");
    try expectOutput("print(2 * 1.5)\n", "3.0\n");
}

test "print takes zero or more values separated by one space" {
    try expectOutput("print()\n", "\n");
    try expectOutput("print(1, 2, 3)\n", "1 2 3\n");
}

test "several statements run in order" {
    try expectOutput("print(1)\nprint(2)\n", "1\n2\n");
}

test "integer overflow is reported rather than wrapping" {
    try expectFailure("print(9223372036854775807 + 1)\n", "addition of 9223372036854775807 and 1 overflows Int");
    try expectFailure("print(-9223372036854775807 - 2)\n", "subtraction of -9223372036854775807 and 2 overflows Int");
    try expectFailure("print(4611686018427387904 * 4)\n", "multiplication of 4611686018427387904 and 4 overflows Int");
}

test "division by zero is an error for both numeric types" {
    try expectFailure("print(1 / 0)\n", "division by zero");
    try expectFailure("print(1.0 / 0.0)\n", "division by zero");
    try expectFailure("print(1 // 0)\n", "floor division by zero");
    try expectFailure("print(1 % 0)\n", "remainder by zero");
}

test "a result that is never used is rejected with the likely correction" {
    try expectFailure("2 + 3\n", "this result is never used");
}

test "an undefined name is reported by name" {
    try expectFailure("print(score)\n", "`score` is not defined");
}

test "a number outside the Int range is rejected at its literal" {
    try expectFailure("print(99999999999999999999)\n", "this number is outside the range of Int");
}

test "the minimum Int can be written, although its digits alone are out of range" {
    try expectOutput("print(-9223372036854775808)\n", "-9223372036854775808\n");
    try expectOutput("print(-9_223_372_036_854_775_808 + 1)\n", "-9223372036854775807\n");
    try expectFailure("print(9223372036854775808)\n", "this number is outside the range of Int");
    // `**` binds tighter than the minus, so the literal stands alone.
    try expectFailure("print(-9223372036854775808 ** 2)\n", "this number is outside the range of Int");
    // Negating it still overflows, because the range is asymmetric.
    try expectFailure("print(-(-9223372036854775808))\n", "negating -9223372036854775808 overflows Int");
}

test "underscores in a literal carry no value" {
    try expectOutput("print(1_000_000)\n", "1000000\n");
}

// Section 4.3 and 6.1: bindings, assignment, and scope.

test "the first milestone program" {
    try expectOutput("var score = 2 + 3 * 4\nprint(score)\n", "14\n");
}

test "var rebinds and const does not" {
    try expectOutput("var n = 1\nn = 2\nprint(n)\n", "2\n");
    try expectFailure("const n = 1\nn = 2\n", "`n` cannot be reassigned");
}

test "a const needs its value where it is declared" {
    try expectFailure("const n: Int\n", "`n` is a `const`, so it needs a value where it is declared");
    try expectOutput("var n: Int\nn = 2\nprint(n)\n", "2\n");
}

test "compound assignment lowers through the matching operation" {
    try expectOutput("var n = 10\nn += 5\nprint(n)\n", "15\n");
    try expectOutput("var n = 10\nn -= 5\nprint(n)\n", "5\n");
    try expectOutput("var n = 10\nn *= 3\nprint(n)\n", "30\n");
    try expectOutput("var n = 7\nn //= 2\nprint(n)\n", "3\n");
    // `/=` follows `/`, which always produces a Float, so it needs a Float name.
    try expectOutput("var n = 10.0\nn /= 4\nprint(n)\n", "2.5\n");
    try expectFailure(
        "var n = 10\nn /= 4\n",
        "`/` produces Float, which `n` cannot hold because it is Int",
    );
}

test "assignment is a statement and cannot be chained" {
    try expectFailure("var a = 1\nvar b = 2\na = b = 3\n", "assignments cannot be chained");
}

test "shadowing a visible local is rejected, including across a block" {
    try expectFailure("var n = 1\nvar n = 2\n", "`n` is already declared");
    try expectFailure("var n = 1\nif true {\n  var n = 2\n}\n", "`n` is already declared");
}

test "sibling scopes may reuse a name" {
    try expectOutput(
        "if true {\n  var n = 1\n  print(n)\n}\nif true {\n  var n = 2\n  print(n)\n}\n",
        "1\n2\n",
    );
}

test "a local does not leak out of its block" {
    try expectFailure("if true {\n  var inner = 1\n}\nprint(inner)\n", "`inner` is not defined");
}

test "a name must be declared before it is used" {
    try expectFailure("print(missing)\n", "`missing` is not defined");
    try expectFailure("missing = 1\n", "`missing` is not defined");
    // The initializer resolves before the name is introduced, so this reports
    // the right-hand side rather than quietly seeing itself.
    try expectFailure("var n = n\n", "`n` is not defined");
}

// Section 6.2: conditionals.

test "if, else if, and else select one branch" {
    const program =
        \\var n = 5
        \\if n > 10 {
        \\    print(1)
        \\}
        \\else if n > 3 {
        \\    print(2)
        \\}
        \\else {
        \\    print(3)
        \\}
        \\
    ;
    try expectOutput(program, "2\n");
}

test "a condition must be a Bool" {
    try expectFailure("if 1 {\n  print(1)\n}\n", "a condition must be a Bool, but this is Int");
    try expectFailure("if nothing {\n  print(1)\n}\n", "a condition must be a Bool, but this is Nothing");
}

// Section 5.2: comparison and the word operators.

test "comparisons produce a Bool" {
    try expectOutput("print(1 < 2)\n", "true\n");
    try expectOutput("print(1 > 2)\n", "false\n");
    try expectOutput("print(2 == 2)\n", "true\n");
    try expectOutput("print(2 != 2)\n", "false\n");
    try expectOutput("print(2 <= 2, 2 >= 3)\n", "true false\n");
}

test "a chained comparison reads as the conjunction of its links" {
    try expectOutput("print(0 <= 5 <= 100)\n", "true\n");
    try expectOutput("print(0 <= 500 <= 100)\n", "false\n");
    try expectOutput("print(1 < 2 < 3 < 4)\n", "true\n");
}

test "a chained comparison short-circuits before evaluating the next operand" {
    // Dividing by zero raises. Reaching it would fail the program, so a plain
    // `false` proves the chain stopped at the first false link.
    try expectOutput("print(2 < 1 < 1 // 0)\n", "false\n");
}

test "and and or short-circuit" {
    try expectOutput("print(false and 1 // 0 == 0)\n", "false\n");
    try expectOutput("print(true or 1 // 0 == 0)\n", "true\n");
    try expectOutput("print(true and false)\n", "false\n");
    try expectOutput("print(false or true)\n", "true\n");
}

test "not inverts a Bool and rejects anything else" {
    try expectOutput("print(not true)\n", "false\n");
    try expectOutput("print(not (1 > 2))\n", "true\n");
    try expectFailure("print(not 1)\n", "`not` needs a Bool, but this is Int");
}

test "a mixed comparison compares mathematical values" {
    // Widening the Int would round it to the Float and make these equal.
    try expectOutput("print(9007199254740993 == 9007199254740992.0)\n", "false\n");
    try expectOutput("print(9007199254740993 > 9007199254740992.0)\n", "true\n");
    try expectOutput("print(2 == 2.0)\n", "true\n");
    try expectOutput("print(2 < 2.5)\n", "true\n");
}

test "NaN follows IEEE comparison behavior" {
    const nan = "var nan = 1e308 * 10 - 1e308 * 10\n";
    try expectOutput(nan ++ "print(nan == nan)\n", "false\n");
    try expectOutput(nan ++ "print(nan != nan)\n", "true\n");
    try expectOutput(nan ++ "print(nan < 1.0)\n", "false\n");
    try expectOutput(nan ++ "print(nan >= 1.0)\n", "false\n");
}

test "values of different kinds cannot be compared or added" {
    try expectFailure("print(1 < true)\n", "Int and Bool cannot be compared");
    try expectFailure("print(1 + true)\n", "addition needs numbers, but this is Int and Bool");
}

test "every type has equality, and only numbers have order" {
    try expectOutput("print(true == true, true != false, false == true)\n", "true true false\n");
    try expectOutput("print(nothing == nothing, nothing != nothing)\n", "true false\n");
    try expectOutput("var done = 1 > 2\nprint(done == false)\n", "true\n");
    try expectFailure("print(true < false)\n", "`<` needs numbers, but these are Bool values");
    try expectFailure("print(nothing >= nothing)\n", "`>=` needs numbers, but these are Nothing values");
    try expectFailure("print(1 == true)\n", "Int and Bool cannot be compared");
}

// Section 4.2 and 15.2: `nothing`.

test "nothing is a value and print has no result" {
    try expectOutput("print(nothing)\n", "nothing\n");
    try expectOutput("var result = print(1)\nprint(result)\n", "1\nnothing\n");
}

test "a program may declare a name matching a prelude function" {
    // The prelude is not a local, so this is not the shadowing section 6.1 forbids.
    try expectOutput("var print_count = 0\nprint(print_count)\n", "0\n");
}

// Section 4.1: static types, inference, and definite assignment.

test "a local is inferred from its initializer" {
    try expectOutput("var n = 1\nprint(n + 1)\n", "2\n");
    try expectFailure("var n = 1\nprint(not n)\n", "`not` needs a Bool, but this is Int");
}

test "an annotation is checked against the initializer" {
    try expectOutput("var n: Int = 1\nprint(n)\n", "1\n");
    try expectFailure("var n: Int = 1.5\n", "this is Float, but `n` was declared as Int");
    try expectFailure("var flag: Bool = 1\n", "this is Int, but `flag` was declared as Bool");
}

test "Int widens to Float in a declaration but Float does not narrow" {
    try expectOutput("var rate: Float = 1\nprint(rate)\n", "1.0\n");
    try expectFailure("var count: Int = 1.0\n", "this is Float, but `count` was declared as Int");
}

test "an unknown type name is rejected" {
    try expectFailure("var winner: Player\n", "`Player` is not a type");
}

test "section 4.2: the parser splits a trailing `?` in type position" {
    // The lexer hands over `Int?` as one identifier; the parser splits the
    // trailing `?`, which is what makes an optional type reachable at all.
    try expectOutput("var maybe: Int? = nothing\nprint(maybe)\n", "nothing\n");
    try expectOutput("var maybe: Int? = 5\nprint(maybe)\n", "5\n");
    // Section 4.5: optionals never nest.
    try expectFailure("var maybe: Int??\n", "a type cannot be optional twice");
    try expectFailure("var maybe: List[Int]??\n", "a type cannot be optional twice");
    try expectFailure("var maybe: Nothing?\n", "`Nothing?` is not a type");
    // Section 4.5: placement is structural.
    try expectOutput("var maybe: List[String]? = nothing\nprint(maybe)\n", "nothing\n");
    try expectOutput("var each: List[String?] = [nothing, \"Ava\"]\nprint(each)\n", "[nothing, \"Ava\"]\n");
    try expectFailure(
        "var names: List[String]? = nothing\nvar each: List[String?] = names\n",
        "this is List[String]?, but `each` was declared as List[String?]",
    );
}

test "section 4.2: the conformance declaration using both meanings of `?`" {
    const program =
        \\func valid?(input: Int?): Bool {
        \\    return input != nothing
        \\}
        \\print(valid?(1))
        \\print(valid?(nothing))
        \\
    ;
    try expectOutput(program, "true\nfalse\n");
}

test "an uninitialized variable needs an explicit type" {
    try expectFailure("var winner\n", "expected `=` after `winner`, found the end of the line");
}

test "reading before definite assignment is rejected" {
    try expectFailure("var n: Int\nprint(n)\n", "`n` may not have been assigned");
}

test "assignment on every branch proves definite assignment" {
    const program =
        \\var message: Int
        \\if 1 > 0 {
        \\    message = 1
        \\}
        \\else {
        \\    message = 2
        \\}
        \\print(message)
        \\
    ;
    try expectOutput(program, "1\n");
}

test "assignment on only one branch does not" {
    const program =
        \\var message: Int
        \\if 1 > 0 {
        \\    message = 1
        \\}
        \\print(message)
        \\
    ;
    try expectFailure(program, "`message` may not have been assigned");
}

test "an else-if chain without a final else proves nothing" {
    const program =
        \\var m: Int
        \\if 1 > 0 {
        \\    m = 1
        \\}
        \\else if 2 > 1 {
        \\    m = 2
        \\}
        \\print(m)
        \\
    ;
    try expectFailure(program, "`m` may not have been assigned");
}

test "operand errors are reported before execution rather than during it" {
    // Nothing is printed, because the program never starts.
    try expectFailure("print(1)\nprint(1 + true)\n", "addition needs numbers, but this is Int and Bool");
    try expectFailure("print(1)\nif 1 {\n  print(2)\n}\n", "a condition must be a Bool, but this is Int");
}

test "assignment checks the declared type" {
    try expectFailure("var n = 1\nn = true\n", "this is Bool, but `n` holds Int");
    try expectOutput("var rate = 1.0\nrate = 2\nprint(rate)\n", "2.0\n");
}

test "a compound assignment is checked through the operation it lowers to" {
    // `/` always produces a Float, so `/=` can never store into an Int.
    try expectFailure(
        "var count = 10\ncount /= 2\n",
        "`/` produces Float, which `count` cannot hold because it is Int",
    );
    try expectFailure("var n = 1\nn += true\n", "addition needs numbers, but this is Int and Bool");
}

test "one mistake produces one diagnostic rather than a cascade" {
    var source = try Source.init(testing.allocator, "test.em", "var n = 1 + true\nprint(n + 1)\nprint(n * 2)\n");
    defer source.deinit(testing.allocator);

    var report = try check(testing.allocator, &source);
    defer report.deinit();

    // The invalid type flows outward without being reported again.
    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
}

// Section 6.4: loops.

test "a for loop visits a range in order, and a range only counts upward" {
    try expectOutput("for i in 1..3 {\n    print(i)\n}\n", "1\n2\n3\n");
    try expectOutput("for i in 0..<3 {\n    print(i)\n}\n", "0\n1\n2\n");
    // A start past the end is empty, so computed bounds cannot reverse.
    try expectOutput("var count = 0\nfor i in 0..count - 1 {\n    print(i)\n}\nprint(9)\n", "9\n");
    // Written with two literals, a descending range can only be a mistake.
    try expectFailure("for i in 5..1 {\n    print(i)\n}\n", "this range is empty, because ranges count upward");
    try expectFailure("for i in -1..-3 {\n    print(i)\n}\n", "this range is empty, because ranges count upward");
    try expectOutput("for i in 3..<3 {\n    print(i)\n}\nprint(9)\n", "9\n");
    try expectOutput("for i in 3..3 {\n    print(i)\n}\n", "3\n");
}

test "counting down, stepping, and reversing say their direction in words" {
    const program =
        \\var out: List[Int] = []
        \\for i in 5.down_to(1) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in 10.down_to(0).step(4) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in (0..10).step(3) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in (1..4).reverse() {
        \\    out.append(i)
        \\}
        \\print(out)
        \\out.clear()
        \\for i in 2.up_to(4) {
        \\    out.append(i)
        \\}
        \\print(out)
        \\
    ;
    try expectOutput(program, "[5, 4, 3, 2, 1]\n[10, 6, 2]\n[0, 3, 6, 9]\n[4, 3, 2, 1]\n[2, 3, 4]\n");
}

test "reverse and step apply in the order written" {
    try expectOutput("for i in (0..10).step(3).reverse() {\n    print(i)\n}\n", "9\n6\n3\n0\n");
    try expectOutput("for i in (0..10).reverse().step(3) {\n    print(i)\n}\n", "10\n7\n4\n1\n");
}

test "a computed count on the wrong side is empty, so walking backwards is safe" {
    try expectOutput("var count = 0\nfor i in count.down_to(1) {\n    print(i)\n}\nprint(9)\n", "9\n");
    try expectOutput(
        "var items: List[Int] = []\nfor i in (0..<items.count).reverse() {\n    print(items[i])\n}\nprint(9)\n",
        "9\n",
    );
}

test "counting reaches both ends of the Int range without overflowing" {
    try expectOutput(
        "for i in 9223372036854775807.down_to(9223372036854775804).step(2) {\n    print(i)\n}\n",
        "9223372036854775807\n9223372036854775805\n",
    );
    try expectOutput(
        "for i in (-9223372036854775807).down_to(-9223372036854775807 - 1) {\n    print(i)\n}\n",
        "-9223372036854775807\n-9223372036854775808\n",
    );
}

test "a count written with literals that can only be empty is an error" {
    try expectFailure("for i in 1.down_to(10) {\n    print(i)\n}\n", "this is empty, because `down_to` only counts down");
    try expectFailure("for i in 10.up_to(1) {\n    print(i)\n}\n", "this is empty, because `up_to` only counts up");
}

test "a step is at least 1 and given once" {
    try expectFailure("for i in (1..5).step(0) {\n    print(i)\n}\n", "a step must be at least 1");
    try expectFailure("var n = -2\nfor i in (1..5).step(n) {\n    print(i)\n}\n", "a step must be at least 1, but this is -2");
    try expectFailure("for i in (1..9).step(2).reverse().step(2) {\n    print(i)\n}\n", "this already has a step");
    try expectOutput("var countdown = 10.down_to(1)\nprint(countdown.count)\n", "10\n");
}

test "ranges are immutable values that can be stored, passed, and iterated" {
    const program =
        \\func total(values: Range): Int {
        \\    var result = 0
        \\    for value in values {
        \\        result += value
        \\    }
        \\    return result
        \\}
        \\var odds = (1..10).step(2)
        \\print(odds.count, odds.empty?(), odds.to_list())
        \\print(total(odds))
        \\print((0..<0).count, (0..<0).empty?(), (0..<0).to_list())
        \\
    ;
    try expectOutput(program, "5 false [1, 3, 5, 7, 9]\n25\n0 true []\n");
}

test "integer counting block forms use the same Range semantics" {
    const program =
        \\var values: List[Int] = []
        \\4.times { index => values.append(index) }
        \\2.up_to(4) { number => values.append(number) }
        \\4.down_to(2) { number => values.append(number) }
        \\print(values)
        \\
    ;
    try expectOutput(program, "[0, 1, 2, 3, 2, 3, 4, 4, 3, 2]\n");
    try expectFailure("(-1).times { index => print(index) }\n", "`times` cannot repeat a negative count (-1)");
}

test "a full-domain Range never truncates its count" {
    try expectFailure(
        "var all = (-9223372036854775807 - 1)..9223372036854775807\nprint(all.count)\n",
        "this Range has too many values for `count`",
    );
}

test "a range may end at the largest Int without overflowing" {
    try expectOutput(
        "for i in 9223372036854775806..9223372036854775807 {\n    print(i)\n}\n",
        "9223372036854775806\n9223372036854775807\n",
    );
}

test "range endpoints are evaluated once, before the first iteration" {
    const program =
        \\var calls = 0
        \\func limit(): Int {
        \\    calls += 1
        \\    return 3
        \\}
        \\for i in 1..limit() {
        \\    print(i)
        \\}
        \\print(calls)
        \\
    ;
    try expectOutput(program, "1\n2\n3\n1\n");
}

test "an underscore visits each value without naming it" {
    try expectOutput("for _ in 1..3 {\n    print(0)\n}\n", "0\n0\n0\n");
}

test "while repeats until its condition is false" {
    try expectOutput("var n = 3\nwhile n > 0 {\n    print(n)\n    n -= 1\n}\n", "3\n2\n1\n");
    try expectOutput("while false {\n    print(1)\n}\nprint(2)\n", "2\n");
}

test "break and continue act on the innermost loop" {
    const program =
        \\for row in 1..3 {
        \\    for column in 1..3 {
        \\        continue if column == 2
        \\        break if column > row
        \\        print(row * 10 + column)
        \\    }
        \\}
        \\
    ;
    try expectOutput(program, "11\n21\n31\n33\n");
}

test "a local declared in a loop body is fresh every iteration" {
    try expectOutput("for i in 1..2 {\n    var doubled = i * 2\n    print(doubled)\n}\n", "2\n4\n");
}

test "after while true, a name is assigned when every break assigned it" {
    const assigned =
        \\var found: Int
        \\var n = 0
        \\while true {
        \\    n += 1
        \\    if n * n > 50 {
        \\        found = n
        \\        break
        \\    }
        \\}
        \\print(found)
        \\
    ;
    try expectOutput(assigned, "8\n");

    const not_on_every_break =
        \\var found: Int
        \\var n = 0
        \\while true {
        \\    n += 1
        \\    break if n > 9
        \\    found = n
        \\    break if n > 3
        \\}
        \\print(found)
        \\
    ;
    try expectFailure(not_on_every_break, "`found` may not have been assigned");
}

test "a loop may run zero times, so what it assigns is not known after it" {
    try expectFailure(
        "var x: Int\nvar n = 0\nwhile n < 3 {\n    x = n\n    n += 1\n}\nprint(x)\n",
        "`x` may not have been assigned",
    );
    try expectFailure(
        "var x: Int\nfor i in 1..3 {\n    x = i\n}\nprint(x)\n",
        "`x` may not have been assigned",
    );
}

test "a function may end in a loop that only a return leaves" {
    const program =
        \\func first_multiple(of: Int, above: Int): Int {
        \\    var n = above + 1
        \\    while true {
        \\        return n if n % of == 0
        \\        n += 1
        \\    }
        \\}
        \\print(first_multiple(7, 20))
        \\
    ;
    try expectOutput(program, "21\n");

    // Any other loop can finish, so the path after it still needs a return.
    try expectFailure(
        "func f(n: Int): Int {\n    while n > 0 {\n        return 1\n    }\n}\n",
        "not every path in `f` returns a value",
    );
}

test "break and continue only work inside a loop" {
    try expectFailure("break\n", "`break` can only be used inside a loop");
    try expectFailure("func f() {\n    continue\n}\n", "`continue` can only be used inside a loop");
    // A function body is not inside the loop that calls it.
    try expectFailure("func f() {\n    break\n}\nfor i in 1..2 {\n    f()\n}\n", "`break` can only be used inside a loop");
}

test "a loop variable is read-only and does not outlive its loop" {
    try expectFailure("for i in 1..3 {\n    i = 2\n}\n", "`i` cannot be reassigned");
    try expectFailure("for i in 1..3 {\n    print(i)\n}\nprint(i)\n", "`i` is not defined");
    try expectFailure("var i = 0\nfor i in 1..3 {\n    print(i)\n}\n", "`i` is already declared");
}

test "only an Int range can be looped over so far" {
    try expectFailure("for i in 1..2.5 {\n    print(i)\n}\n", "counting works with whole numbers, but this is Float");
    try expectFailure("for i in 5 {\n    print(i)\n}\n", "a `for` loop cannot visit Int");
    try expectOutput("var r = 1..3\nprint(r.count)\n", "3\n");
    try expectFailure("for i in 1..2..3 {\n    print(i)\n}\n", "a range has one start and one end");
}

test "memory stays flat however many times a loop runs" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var part = i * 2\n    total += part\n}}\nprint(total)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{20_000}));
    try testing.expect(many < few + 16 * 1024);
}

// Section 6.2: the trailing `if`.

test "a trailing if guards one statement" {
    try expectOutput("print(1) if true\nprint(2) if false\n", "1\n");
    try expectOutput("var score = 5\nscore += 10 if score > 3\nprint(score)\n", "15\n");
    try expectOutput(
        "func sign(n: Int): Int {\n    return -1 if n < 0\n    return 0 if n == 0\n    return 1\n}\nprint(sign(-4), sign(0), sign(9))\n",
        "-1 0 1\n",
    );
    try expectOutput("func greet(ready: Bool) {\n    return if not ready\n    print(1)\n}\ngreet(false)\ngreet(true)\n", "1\n");
}

test "a declaration cannot have a trailing if" {
    try expectFailure("var x = 1 if true\n", "a declaration cannot have a trailing `if`");
}

// Section 8: lists.

test "a list literal, indexing, and count" {
    try expectOutput("var scores = [10, 20, 30]\nprint(scores, scores.count, scores[0], scores[2])\n", "[10, 20, 30] 3 10 30\n");
    try expectOutput("print([[1, 2], [3]], [[1, 2], [3]][1][0])\n", "[[1, 2], [3]] 3\n");
    // A trailing comma is allowed, and newlines inside the brackets continue it.
    try expectOutput("var xs = [\n    1,\n    2,\n]\nprint(xs)\n", "[1, 2]\n");
}

test "an empty list takes its type from context" {
    try expectOutput("var names: List[Int] = []\nprint(names, names.empty?())\n", "[] true\n");
    try expectOutput("func none(): List[Int] {\n    return []\n}\nprint(none())\n", "[]\n");
    try expectOutput("var xs = [1]\nprint(xs == [], [] != xs)\n", "false true\n");
    try expectFailure("var names = []\n", "an empty list needs a type");
}

test "a list of Ints and Floats is a list of Floats, and a Float list widens what it stores" {
    try expectOutput("print([1, 2.5])\n", "[1.0, 2.5]\n");
    try expectOutput("var rates: List[Float] = [1, 2]\nrates.append(3)\nrates[0] = 4\nprint(rates)\n", "[4.0, 2.0, 3.0]\n");
    try expectOutput("var grid: List[List[Float]] = [[1], [2]]\nprint(grid)\n", "[[1.0], [2.0]]\n");
    try expectFailure("var xs = [1, true]\n", "this is Bool, but the list holds Int");
}

test "lists are invariant, so an Int list is not a Float list" {
    try expectFailure("var ints = [1]\nvar floats: List[Float] = ints\n", "this is List[Int], but `floats` was declared as List[Float]");
    try expectFailure("print([1] == [1.0])\n", "List[Int] and List[Float] cannot be compared");
}

test "assigning a list gives an independent copy" {
    try expectOutput(
        "var original = [1, 2]\nvar copy = original\ncopy.append(3)\ncopy[0] = 9\nprint(original, copy)\n",
        "[1, 2] [9, 2, 3]\n",
    );
    // Nested lists are copied too, at whatever depth the change happens.
    try expectOutput(
        "var rows = [[1], [2]]\nvar copy = rows\ncopy[0].append(9)\ncopy[1][0] = 5\nprint(rows, copy)\n",
        "[[1], [2]] [[1, 9], [5]]\n",
    );
}

test "a list passed to a function is independent of the caller's" {
    const program =
        \\var scores = [1]
        \\func show(items: List[Int]) {
        \\    scores.append(2)
        \\    print(items)
        \\}
        \\show(scores)
        \\print(scores)
        \\
    ;
    try expectOutput(program, "[1]\n[1, 2]\n");

    const returned =
        \\func with_guest(guests: List[Int], guest: Int): List[Int] {
        \\    var updated = guests
        \\    updated.append(guest)
        \\    return updated
        \\}
        \\var party = [1, 2]
        \\var bigger = with_guest(party, 3)
        \\print(party, bigger)
        \\
    ;
    try expectOutput(returned, "[1, 2] [1, 2, 3]\n");
}

test "a loop visits the list as it was when the loop began" {
    try expectOutput(
        "var items = [1, 2]\nfor item in items {\n    items.append(item * 10)\n}\nprint(items)\n",
        "[1, 2, 10, 20]\n",
    );
    try expectOutput("var total = 0\nfor value in [5, 6, 7] {\n    total += value\n}\nprint(total)\n", "18\n");
}

test "element assignment, including compound" {
    try expectOutput("var xs = [1, 2]\nxs[1] += 10\nxs[0] *= 3\nprint(xs)\n", "[3, 12]\n");
    try expectOutput("var grid = [[1, 2], [3, 4]]\ngrid[1][0] = 30\nprint(grid)\n", "[[1, 2], [30, 4]]\n");
}

test "the essential list methods" {
    const program =
        \\var xs = [3, 1, 3, 2, 3]
        \\xs.remove(3)
        \\print(xs)
        \\xs.remove_all(3)
        \\print(xs)
        \\xs.insert(0, 7)
        \\xs.insert(xs.count, 8)
        \\print(xs)
        \\print(xs.remove_at(1), xs)
        \\print(xs.remove_first(), xs.remove_last(), xs)
        \\print(xs.contains?(2), xs.contains?(9))
        \\xs.clear()
        \\print(xs, xs.count, xs.empty?())
        \\xs.remove(4)
        \\print(xs)
        \\
    ;
    try expectOutput(program, "[1, 3, 2, 3]\n[1, 2]\n[7, 1, 2, 8]\n1 [7, 2, 8]\n7 8 [2]\ntrue false\n[] 0 true\n[]\n");
}

test "lists compare element by element and print as they are written" {
    try expectOutput("print([1, 2] == [1, 2], [1, 2] != [2, 1], [[1]] == [[1]])\n", "true true true\n");
    try expectOutput("print([true, false], [0.5])\n", "[true, false] [0.5]\n");
}

test "an index outside the list names the index and the valid range" {
    try expectFailure("var xs = [1, 2, 3]\nprint(xs[3])\n", "index 3 is outside this list, which has 3 elements");
    try expectFailure("var xs = [1]\nxs[-1] = 0\n", "index -1 is outside this list, which has 1 element");
    try expectFailure("var xs: List[Int] = []\nprint(xs[0])\n", "index 0 is outside this list, which is empty");
    try expectFailure("var xs = [1]\nxs.insert(3, 2)\n", "cannot insert at index 3 in a list of 1 element");
    try expectFailure("var xs: List[Int] = []\nprint(xs.remove_last())\n", "cannot remove an element from an empty list");
}

test "a const, a parameter, a loop variable, and a temporary cannot change" {
    try expectFailure("const xs = [1]\nxs.append(2)\n", "`xs` is a `const`, so its contents cannot change");
    try expectFailure("const xs = [1]\nxs[0] = 2\n", "`xs` is a `const`, so its contents cannot change");
    try expectFailure(
        "func f(guests: List[Int]) {\n    guests.append(1)\n}\n",
        "`guests` is a parameter, so a change to it would be lost when the function returns",
    );
    try expectFailure(
        "var grid = [[1]]\nfor row in grid {\n    row[0] = 2\n}\n",
        "`row` is a loop variable, so a change to it would be lost",
    );
    try expectFailure(
        "func make(): List[Int] {\n    return [1]\n}\nmake().append(2)\n",
        "`append` changes a list, but this list is a temporary value, so the change would be lost",
    );
    // Reading through a const or a parameter is fine.
    try expectOutput("const xs = [1, 2]\nprint(xs.contains?(2), xs[1], xs.count)\n", "true 2 2\n");
}

test "a misspelled member names what Emerald calls it" {
    try expectFailure("var xs = [1]\nxs.push(2)\n", "List[Int] has no method `push`");
    try expectFailure("var xs = [1]\nprint(xs.length)\n", "List[Int] has no property `length`");
    try expectFailure("var xs = [1]\nprint(xs.count())\n", "`count` is a property, so it takes no parentheses");
    try expectFailure("var xs = [1]\nprint(xs.append)\n", "`append` is a method, so it needs parentheses");
    try expectFailure("var n = 5\nprint(n[0])\n", "Int cannot be indexed");
    try expectFailure("var xs = [1]\nprint(xs[true])\n", "an index must be an Int, but this is Bool");
}

test "memory stays flat however many lists a loop builds and drops" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var row = [i, i, i]\n    row.append(i)\n    var copy = row\n    copy[0] = 0\n    total += copy.count\n}}\nprint(total)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{5_000}));
    try testing.expect(many < few + 16 * 1024);
}

// Section 9: strings.

test "string literals: escapes, raw strings, and code points" {
    try expectOutput("print(\"a\\tb\\\\c \\\"q\\\" \\#{x}\")\n", "a\tb\\c \"q\" #{x}\n");
    try expectOutput("print('C:\\Users\\raw \\n')\n", "C:\\Users\\raw \\n\n");
    try expectOutput("print(\"caf\\u{E9} \\u{1F600}\")\n", "caf\u{E9} \u{1F600}\n");
    try expectFailure("print(\"\\u{D800}\")\n", "this `\\u` escape is not a Unicode character");
    try expectFailure("print(\"\\u0301\")\n", "this `\\u` escape is incomplete");
}

test "interpolation displays any value, and strings inside lists are quoted" {
    try expectOutput("var n = 3\nprint(\"n is #{n}, half is #{n / 2}, #{n > 2}\")\n", "n is 3, half is 1.5, true\n");
    try expectOutput("var n = 3\nprint(\"outer #{\"inner #{n + 1}\"} end\")\n", "outer inner 4 end\n");
    try expectOutput("print(\"#{[\"a, b\", \"c\"]}\")\n", "[\"a, b\", \"c\"]\n");
    try expectOutput("print([\"q\\\"\", \"line\\n\"])\n", "[\"q\\\"\", \"line\\n\"]\n");
    try expectFailure("print(\"#{}\")\n", "an interpolation needs an expression");
    try expectFailure("print(\"a #{1 + 2\")\n", "this `#{` is never closed");
}

test "a triple-quoted string removes the closing delimiter's indentation" {
    const program =
        \\var text = """
        \\    first
        \\      indented
        \\
        \\    last #{1 + 1}
        \\    """
        \\print(text)
        \\print(text.lines().count)
        \\
    ;
    try expectOutput(program, "first\n  indented\n\nlast 2\n4\n");
    // A Windows line ending becomes `\n`.
    try expectOutput("var text = \"\"\"\r\n  a\r\n  b\r\n  \"\"\"\r\nprint(text.count)\r\n", "3\n");
    try expectFailure("var s = \"\"\"text\"\"\"\n", "a triple-quoted string starts on the line after its `\"\"\"`");
    try expectFailure("var s = \"\"\"\n  text\"\"\"\n", "the closing `\"\"\"` of this string needs a line of its own");
    try expectFailure("var s = \"\"\"\n  a\n    \"\"\"\n", "this line is indented less than the closing `\"\"\"`");
}

test "count, indexing, and for measure characters, not bytes" {
    try expectOutput("var s = \"h\\u{E9}llo \\u{1F44B}\"\nprint(s.count, s[1], s[6])\n", "7 \u{E9} \u{1F44B}\n");
    // `e` and a combining accent are one character.
    try expectOutput("for c in \"e\\u{301}x\" {\n    write(c, \"|\")\n}\nprint()\n", "e\u{301} |x |\n");
    try expectFailure("print(\"abc\"[3])\n", "index 3 is outside this String, which has 3 characters");
    try expectFailure("var s = \"abc\"\ns[0] = \"x\"\n", "a String cannot be changed in place");
}

test "strings compare by canonical equivalence and order by code point" {
    try expectOutput("print(\"caf\\u{E9}\" == \"cafe\\u{301}\", \"a\" != \"b\")\n", "true true\n");
    try expectOutput("print(\"apple\" < \"banana\", \"Zebra\" < \"apple\", \"b\" >= \"b\")\n", "true true true\n");
    try expectOutput("print([\"caf\\u{E9}\"].contains?(\"cafe\\u{301}\"))\n", "true\n");
}

test "plus joins strings, and nothing else mixes text with arithmetic" {
    try expectOutput("var s = \"a\"\ns += \"b\"\ns = s + \"c\"\nprint(s)\n", "abc\n");
    try expectOutput("var names = [\"x\"]\nnames[0] += \"y\"\nprint(names)\n", "[\"xy\"]\n");
    try expectFailure("print(\"n = \" + 3)\n", "`+` joins two Strings, but this is String and Int");
    try expectFailure("print(\"a\" - \"b\")\n", "subtraction needs numbers, but this is String and String");
}

test "the string vocabulary" {
    try expectOutput("print(\"Stra\\u{DF}e\".upper(), \"ABC\".lower(), \"\\u{E9}lan\".capitalize())\n", "STRASSE abc \u{C9}lan\n");
    try expectOutput("print(\"  hi  \".trim() + \"|\", \"  hi  \".trim_start() + \"|\", \"  hi  \".trim_end() + \"|\")\n", "hi| hi  |   hi|\n");
    try expectOutput("print(\"caf\\u{E9}\".contains?(\"e\"), \"cafe\".contains?(\"e\"), \"ab\".starts_with?(\"a\"), \"ab\".ends_with?(\"b\"))\n", "false true true true\n");
    try expectOutput("print(\"a,b,,c\".split(\",\"), \"one\\ntwo\\n\".lines(), \"ab\".chars())\n", "[\"a\", \"b\", \"\", \"c\"] [\"one\", \"two\"] [\"a\", \"b\"]\n");
    try expectOutput("print(\"ha\".repeat(3), \"stressed\".reverse(), \"a-b-c\".replace(\"-\", \"+\"))\n", "hahaha desserts a+b+c\n");
    try expectOutput("print(\"hello\".substring(1), \"hello\".substring(1, 3), \"hello\".substring(5) == \"\")\n", "ello ell true\n");
    try expectOutput("print(\" \".blank?(), \"\".empty?(), \"a\".empty?())\n", "true true false\n");
    try expectFailure("print(\"abc\".substring(1, 5))\n", "a substring of 5 characters from 1 runs past the end of a String of 3");
    try expectFailure("print(\"abc\".split(\"\"))\n", "`split` needs a separator, but this is an empty String");
    try expectFailure("print(\"abc\".length)\n", "String has no property `length`");
}

test "converting between strings and numbers" {
    try expectOutput("print(\"42\".to_int() + 1, \" -7 \".to_int(), \"x\".to_int_or(-1))\n", "43 -7 -1\n");
    try expectOutput("print(\"2.5\".to_float(), \"3\".to_float(), \"no\".to_float_or(0))\n", "2.5 3.0 0.0\n");
    try expectOutput("print(12.to_string() + \"!\", 2.0.to_string(), false.to_string())\n", "12! 2.0 false\n");
    try expectFailure("print(\"4 2\".to_int())\n", "\"4 2\" is not a whole number");
    try expectFailure("print(\"99999999999999999999\".to_int())\n", "\"99999999999999999999\" is outside the range of Int");
}

test "the first program: input and interpolation" {
    const program = "var name = input(\"What is your name? \")\nprint(\"Hello, #{name}!\")\n";
    try expectOutputWithInput(program, "Ada\n", "What is your name? Hello, Ada!\n");
    // A Windows line ending is removed with the newline; Enter alone gives "".
    try expectOutputWithInput("print(input().count, input().count)\n", "ab\r\n\n", "2 0\n");
    // The last line may end without a newline.
    try expectOutputWithInput("print(input())\n", "last", "last\n");
    try expectFailure("var name = input()\n", "`input` reached the end of the input");
    try expectOutput("write(\"a\", \"b\")\nwrite(\"c\")\nprint()\n", "a bc\n");
}

test "names follow Unicode identifier rules and normalize" {
    try expectOutput("var \u{FC}ber = 1\nprint(\u{FC}ber)\n", "1\n");
    // A precomposed and a decomposed spelling are the same name (3.3).
    try expectOutput("var caf\u{E9} = 2\nprint(cafe\u{301})\n", "2\n");
    try expectFailure("var \u{1F600} = 1\n", "this character cannot be used in a name");
}

test "memory stays flat however many strings a loop builds and drops" {
    const program = "var total = 0\nfor i in 1..{d} {{\n    var line = \"item #{{i}}: \" + i.to_string()\n    total += line.upper().count\n}}\nprint(total > 0)\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{5_000}));
    try testing.expect(many < few + 16 * 1024);
}

// Section 7: functions.

test "a function takes arguments and returns a value" {
    try expectOutput("func add(left: Int, right: Int): Int {\n    return left + right\n}\nprint(add(2, 3))\n", "5\n");
}

test "a function with no result may omit its return type" {
    try expectOutput("func greet(n: Int) {\n    print(n)\n}\ngreet(7)\n", "7\n");
    try expectOutput("func early(n: Int) {\n    if n > 0 {\n        return\n    }\n    print(n)\n}\nearly(1)\nearly(0)\n", "0\n");
}

test "a call with no result evaluates to nothing" {
    try expectOutput("func f() {\n    print(1)\n}\nvar result = f()\nprint(result)\n", "1\nnothing\n");
}

test "print evaluates every argument before writing any of them" {
    const functions =
        \\func first(): Int {
        \\    print(10)
        \\    return 1
        \\}
        \\func second(): Int {
        \\    print(20)
        \\    return 2
        \\}
        \\
    ;
    try expectOutput(functions ++ "print(first(), second())\n", "10\n20\n1 2\n");

    // An argument that fails leaves no half-written line behind.
    var source = try Source.init(testing.allocator, "test.em", "print(1, 1 // 0)\n");
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();
    try testing.expect(report.failure != null);
    try testing.expectEqualStrings("", out.written());
}

/// Tracks the most memory live at once, to show that finished calls give theirs
/// back.
const PeakAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn record(self: *PeakAllocator, old_len: usize, new_len: usize) void {
        self.live = self.live - old_len + new_len;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const memory = self.child.rawAlloc(len, alignment, ret) orelse return null;
        self.record(0, len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, len, ret)) return false;
        self.record(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        const moved = self.child.rawRemap(memory, alignment, len, ret) orelse return null;
        self.record(memory.len, len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret);
        self.record(memory.len, 0);
    }
};

fn peakMemory(text: []const u8) !usize {
    var tracking: PeakAllocator = .{ .child = testing.allocator };
    const output = try runToString(tracking.allocator(), text, "");
    tracking.allocator().free(output);
    return tracking.peak;
}

test "memory stays flat however many calls a program makes" {
    // `calls(n)` makes 2^(n+1) - 1 calls but is never more than n + 1 deep.
    const program = "func calls(n: Int): Int {{\n    if n == 0 {{\n        return 1\n    }}\n    return calls(n - 1) + calls(n - 1)\n}}\nprint(calls({d}))\n";
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{3}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{14}));
    // 32,767 calls against 15. Keeping a frame per call would cost megabytes.
    try testing.expect(many < few + 16 * 1024);
}

test "recursion and mutual recursion run when annotated" {
    const factorial =
        \\func factorial(n: Int): Int {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\print(factorial(10))
        \\
    ;
    try expectOutput(factorial, "3628800\n");

    const parity =
        \\func even?(n: Int): Bool {
        \\    if n == 0 {
        \\        return true
        \\    }
        \\    return odd?(n - 1)
        \\}
        \\func odd?(n: Int): Bool {
        \\    if n == 0 {
        \\        return false
        \\    }
        \\    return even?(n - 1)
        \\}
        \\print(even?(10), odd?(7))
        \\
    ;
    try expectOutput(parity, "true true\n");
}

test "functions are hoisted, so a call may come before the declaration" {
    try expectOutput("print(double(21))\nfunc double(n: Int): Int {\n    return n * 2\n}\n", "42\n");
}

test "a recursive function needs an explicit return type" {
    const program =
        \\func factorial(n: Int) {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\
    ;
    try expectFailure(program, "`factorial` is recursive and needs an explicit return type");

    // The same holds through a cycle of two.
    const cycle = "func a(n: Int) {\n    return b(n)\n}\nfunc b(n: Int) {\n    return a(n)\n}\n";
    try expectFailure(cycle, "`a` is recursive and needs an explicit return type");
}

test "a recursive function with no result needs no annotation" {
    // Its return type is `Nothing` without looking inside, so section 7.2 asks
    // for no annotation: there is nothing to infer circularly.
    try expectOutput("func countdown(n: Int) {\n    if n < 0 {\n        return\n    }\n    print(n)\n    countdown(n - 1)\n}\ncountdown(2)\n", "2\n1\n0\n");
}

test "a return type is inferred from a non-recursive body" {
    try expectOutput("func square(n: Int) {\n    return n * n\n}\nprint(square(6) + 1)\n", "37\n");
    // Section 4.4's widening applies when merging returns.
    try expectOutput("func pick(flag: Bool) {\n    if flag {\n        return 1\n    }\n    return 2.5\n}\nprint(pick(true), pick(false))\n", "1.0 2.5\n");
}

test "incompatible returns make an inferred type ambiguous" {
    try expectFailure(
        "func f(flag: Bool) {\n    if flag {\n        return 1\n    }\n    return true\n}\n",
        "the return type of `f` is ambiguous",
    );
    // A bare return alongside a valued one is Nothing beside a value.
    try expectFailure(
        "func f(flag: Bool) {\n    if flag {\n        return\n    }\n    return 1\n}\n",
        "the return type of `f` is ambiguous",
    );
}

test "every path in a value-producing function must return" {
    try expectFailure("func f(n: Int): Int {\n    if n > 0 {\n        return 1\n    }\n}\n", "not every path in `f` returns a value");
    try expectOutput("func sign(n: Int): Int {\n    if n > 0 {\n        return 1\n    }\n    else if n < 0 {\n        return -1\n    }\n    else {\n        return 0\n    }\n}\nprint(sign(-5))\n", "-1\n");
}

test "return is checked against the function's type" {
    try expectFailure("func f(): Int {\n    return true\n}\n", "this is Bool, but the function returns Int");
    try expectFailure("func f(): Int {\n    return\n}\n", "this function must return a value");
    try expectFailure("func f(): Nothing {\n    return 1\n}\n", "this function returns Nothing, so `return` cannot produce a value");
    try expectFailure("return\nprint(1)\n", "this code can never run");
    try expectFailure("return 1\n", "a top-level `return` cannot return a value");
    // Section 14.1: a bare top-level `return` ends the program successfully,
    // right where it runs, unlike inside a function.
    try expectOutput("print(1)\nreturn\nprint(2)\n", "1\n");
    try expectOutput("func half(n: Int): Float {\n    return n\n}\nprint(half(3))\n", "3.0\n");
}

test "calls are checked for arity and argument types" {
    const add = "func add(a: Int, b: Int): Int {\n    return a + b\n}\n";
    try expectFailure(add ++ "print(add(1))\n", "`add` takes 2 arguments, but this call passes 1");
    try expectFailure(add ++ "print(add(1, true))\n", "this is Bool, but parameter `b` of `add` needs Int");
    // Int widens to a Float parameter.
    try expectOutput("func show(x: Float) {\n    print(x)\n}\nshow(2)\n", "2.0\n");
}

test "only a function can be called, and the diagnostic says what it is instead" {
    try expectFailure("var x = 5\nprint(x())\n", "`x` is Int, which is not a function");
    try expectFailure("var x = [1]\nprint(x())\n", "`x` is List[Int], which is not a function");
    // Section 15.2's prelude functions take any number of arguments of any
    // type, which no written type describes, so they can only be called.
    try expectFailure("var p = print\n", "`print` is built in, and built-in functions cannot be used as values");
}

test "parameters are read-only and share the body's scope" {
    try expectFailure("func f(n: Int) {\n    n = 5\n}\n", "`n` cannot be reassigned");
    try expectFailure("func f(n: Int) {\n    var n = 5\n}\n", "`n` is already declared");
    try expectFailure("func f(n: Int, n: Int) {\n}\n", "`n` is already a parameter");
}

test "a function sees module variables declared above it" {
    try expectOutput("const limit = 10\nfunc clamp(n: Int): Int {\n    if n > limit {\n        return limit\n    }\n    return n\n}\nprint(clamp(25), clamp(3))\n", "10 3\n");
    try expectFailure("func show() {\n    print(limit)\n}\nconst limit = 10\n", "`limit` is not declared until later in the file");
}

test "a function may update module state" {
    try expectOutput("var count = 0\nfunc bump() {\n    count += 1\n}\nbump()\nbump()\nprint(count)\n", "2\n");
    try expectFailure("const limit = 1\nfunc f() {\n    limit = 2\n}\n", "`limit` cannot be reassigned");
}

test "crossing a function boundary allows reusing a module-level name" {
    try expectOutput("const n = 100\nfunc twice(n: Int): Int {\n    return n * 2\n}\nprint(twice(4), n)\n", "8 100\n");
}

test "functions and variables share one namespace" {
    try expectFailure("var greet = 1\nfunc greet() {\n}\n", "`greet` is already declared");
    try expectFailure("func f() {\n}\nfunc f() {\n}\n", "`f` is already declared");
    try expectFailure("func f() {\n}\nf = 1\n", "`f` is a function and cannot be assigned to");
}

test "a program function shadows a prelude function" {
    try expectOutput("func print(n: Int) {\n}\nprint(1)\n", "");
}

test "hoisting never permits reading an uninitialized captured variable" {
    try expectFailure(
        "print(area(2.0))\nconst pi = 3.14159\nfunc area(r: Float): Float {\n    return pi * r * r\n}\n",
        "`area` reads `pi`, which is not assigned yet here",
    );
    // Through another function.
    try expectFailure(
        "func outer(): Int {\n    return inner()\n}\nprint(outer())\nvar limit = 5\nfunc inner(): Int {\n    return limit\n}\n",
        "`outer` reads `limit`, which is not assigned yet here",
    );
    // A variable assigned on the path that makes the call.
    try expectOutput(
        "var ready: Int\nif 1 > 0 {\n    ready = 1\n    report()\n}\nfunc report() {\n    print(ready)\n}\n",
        "1\n",
    );
    // A plain assignment in the function needs no earlier value.
    try expectOutput("var total: Int\nfunc reset() {\n    total = 0\n}\nreset()\nprint(1)\n", "1\n");
}

test "a nested function is hoisted within its block and shares its variables" {
    try expectOutput(
        "if true {\n    var total = 0\n    add(2)\n    add(3)\n    print(total)\n    func add(n: Int) {\n        total += n\n    }\n}\n",
        "5\n",
    );
}

test "an early return leaves a branch out of definite assignment" {
    const program =
        \\func classify(n: Int): Int {
        \\    var label: Int
        \\    if n > 0 {
        \\        label = 1
        \\    }
        \\    else {
        \\        return 0
        \\    }
        \\    return label
        \\}
        \\print(classify(5), classify(-5))
        \\
    ;
    try expectOutput(program, "1 0\n");
}

test "a runtime error inside a function carries its stack trace" {
    const program =
        \\func divide(left: Int, right: Int): Float {
        \\    return left / right
        \\}
        \\func ratio(n: Int): Float {
        \\    return divide(n, 0)
        \\}
        \\print(ratio(4))
        \\
    ;
    var source = try Source.init(testing.allocator, "main.em", program);
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    const rendered = try report.failure.?.renderAlloc(testing.allocator, &.{source});
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(
        \\main.em:2:12: division by zero
        \\      return left / right
        \\             ^^^^^^^^^^^^
        \\Check the divisor before dividing. Division by zero has no result for either numeric type.
        \\in `divide`, called at main.em:5:12
        \\in `ratio`, called at main.em:7:7
        \\
    , rendered);
}

test "unbounded recursion is caught at the limit, with repeated frames summarized" {
    const program =
        \\func forever(n: Int): Int {
        \\    return forever(n + 1)
        \\}
        \\print(forever(0))
        \\
    ;
    var source = try Source.init(testing.allocator, "main.em", program);
    defer source.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var no_input: std.Io.Reader = .fixed("");
    var report = try run(testing.allocator, &source, .{ .out = &out.writer, .in = &no_input });
    defer report.deinit();

    const failure = report.failure.?;
    try testing.expectEqualStrings("too much recursion calling `forever`", failure.message);
    // Exactly the 1,000 active calls section 7.2 guarantees.
    try testing.expectEqual(@as(usize, 1000), failure.trace.len);

    const rendered = try failure.renderAlloc(testing.allocator, &.{source});
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.endsWith(u8, rendered,
        \\in `forever`, called at main.em:2:12 (999 times)
        \\in `forever`, called at main.em:4:7
        \\
    ));
}

test "a body nested 250 deep still supports 1,000 calls" {
    // Section 7.2's call guarantee has to hold at section 3.4's nesting
    // guarantee, in whichever build mode the tests run.
    var expression: std.ArrayList(u8) = .empty;
    defer expression.deinit(testing.allocator);
    for (0..250) |_| try expression.appendSlice(testing.allocator, "0 + (");
    try expression.appendSlice(testing.allocator, "deep(n - 1)");
    for (0..250) |_| try expression.append(testing.allocator, ')');

    const program = try std.fmt.allocPrint(
        testing.allocator,
        "func deep(n: Int): Int {{\n    if n == 0 {{\n        return 0\n    }}\n    return {s}\n}}\nprint(deep(999))\n",
        .{expression.items},
    );
    defer testing.allocator.free(program);
    try expectOutput(program, "0\n");
}

test "section 3.4: 256 levels of nesting are accepted and the 257th is reported" {
    const allocator = testing.allocator;
    for ([_]usize{ 255, 256 }) |depth| {
        // `print(` is one level, so this makes `depth` in total.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        try text.appendSlice(allocator, "print(");
        for (0..depth - 1) |_| try text.append(allocator, '(');
        try text.append(allocator, '1');
        for (0..depth) |_| try text.append(allocator, ')');
        try text.append(allocator, '\n');

        if (depth == 256) {
            try expectOutput(text.items, "1\n");
            // One more level.
            try text.insert(allocator, 6, '(');
            try text.insert(allocator, text.items.len - 1, ')');
            try expectFailure(text.items, "this is nested too deeply");
        }
    }
}

test "a long flat chain is a diagnostic, not a crash" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "print(1");
    for (0..Parser.max_expression_depth) |_| try text.appendSlice(testing.allocator, " + 1");
    try text.appendSlice(testing.allocator, ")\n");
    try expectFailure(text.items, "this expression is too long");
}

// Section 7.4 and 7.5: lambdas, closures, and callable values.

test "a lambda is a value that can be called" {
    try expectOutput("const double = { value: Int => value * 2 }\nprint(double(21))\n", "42\n");
    try expectOutput("const answer = { => 42 }\nprint(answer())\n", "42\n");
    try expectOutput("print({ value: Int => value + 1 }(41))\n", "42\n");
}

test "a lambda takes its parameter types from the type expected where it is written" {
    try expectOutput(
        "const apply: func(func(Int): Int, Int): Int = { block, value => block(value) }\nprint(apply({ n => n * 2 }, 21))\n",
        "42\n",
    );
    // With nothing to take them from, they have to be written (7.2).
    try expectFailure("const double = { value => value * 2 }\n", "`value` needs a type");
}

test "a lambda body on more than one line returns its result" {
    const program =
        \\const classify = { n: Int =>
        \\    return "big" if n > 10
        \\    return "small"
        \\}
        \\print(classify(3))
        \\print(classify(30))
        \\
    ;
    try expectOutput(program, "small\nbig\n");
}

test "a one-line lambda body may be a statement rather than a value" {
    try expectOutput("var total = 0\n[1, 2, 3].each { n => total += n }\nprint(total)\n", "6\n");
}

test "section 7.4: capture is by reference, so the variable is shared both ways" {
    try expectOutput("var count = 0\nconst bump = { => count += 1 }\nbump()\nbump()\nprint(count)\n", "2\n");
    // And the other direction: the block sees a change made after it was made.
    try expectOutput(
        "var count = 0\nconst show = { => print(count) }\ncount = 7\nshow()\n",
        "7\n",
    );
}

test "captured variables outlive the call that made them, one set per call" {
    const program =
        \\func counter_from(start: Int): func(): Int {
        \\    var next = start
        \\    return { =>
        \\        next += 1
        \\        return next - 1
        \\    }
        \\}
        \\const first = counter_from(1)
        \\const second = counter_from(100)
        \\print("#{first()} #{first()} #{second()} #{first()}")
        \\
    ;
    try expectOutput(program, "1 2 100 3\n");
}

test "section 6.1: a loop variable is fresh each iteration, so blocks keep their own" {
    const program =
        \\var blocks: List[func(): Int] = []
        \\for i in 1..3 {
        \\    blocks.append({ => i })
        \\}
        \\print(blocks.map { block => block() })
        \\
    ;
    try expectOutput(program, "[1, 2, 3]\n");
}

test "section 8.5's each and section 8.6's map" {
    try expectOutput("[1, 2, 3].each { n => write(\"#{n} \") }\nprint(\"\")\n", "1 2 3 \n");
    try expectOutput("print([1, 2, 3].map { n => n * n })\n", "[1, 4, 9]\n");
    // The block's result type is the new list's element type.
    try expectOutput("print([1, 2].map { n => \"n#{n}\" })\n", "[\"n1\", \"n2\"]\n");
    try expectOutput("print([1, 2].map { n => n / 2 })\n", "[0.5, 1.0]\n");
    try expectFailure("[1, 2].each { n => n * 2 }\n", "this block produces a value, and `each` does not use it");
    try expectFailure("print([1, 2].map { n => print(n) })\n", "this block produces nothing, so there is nothing for `map` to collect");
    try expectFailure("[1, 2].each(5)\n", "`each` needs a block, but this is Int");
    try expectFailure("[1, 2].each { a, b => print(a) }\n", "this lambda takes 2 values, but it will be given 1");
}

test "a block traverses the list as it was, even when the block changes it" {
    // The traversal holds the buffer, so section 8.1's copy-on-write gives the
    // block its own copy to append to rather than a list growing underfoot.
    try expectOutput(
        "var numbers = [1, 2, 3]\nnumbers.each { n => numbers.append(n) }\nprint(numbers)\n",
        "[1, 2, 3, 1, 2, 3]\n",
    );
}

test "section 7.5: a named function is a value" {
    const program =
        \\func triple(value: Int): Int {
        \\    return value * 3
        \\}
        \\const tripler = triple
        \\print(tripler(5))
        \\print([1, 2].map(triple))
        \\
    ;
    try expectOutput(program, "15\n[3, 6]\n");
    // Two captures of the same named function are the same function.
    try expectOutput("func f(): Int {\n    return 1\n}\nconst a = f\nconst b = f\nprint(a == b)\n", "true\n");
}

test "a function type is written the way a declaration is" {
    try expectOutput("const f: func(Int): Int = { n => n }\nprint(f(1))\n", "1\n");
    try expectOutput("const f: func() = { => print(1) }\nf()\n", "1\n");
    try expectOutput("const f: func(Int, String) = { _, _ => print(1) }\nf(1, \"a\")\n", "1\n");
    // Section 7.1 omits a `Nothing` result, so that is how a function type
    // with no result prints.
    try expectFailure(
        "const f: func(Int) = { n => print(n) }\nvar g: Int = f\n",
        "this is func(Int), but `g` was declared as Int",
    );
    // A block given a result type must produce one of that type.
    try expectFailure("const f: func(Int) = { n => n }\n", "this lambda produces Int, but Nothing is expected here");
}

test "section 7.4: `_` takes a value without naming it, more than once" {
    try expectOutput("const f: func(Int, Int): Int = { _, _ => 7 }\nprint(f(1, 2))\n", "7\n");
    // `_` names nothing, so there is nothing to read back.
    try expectFailure("const f: func(Int): Int = { _ => _ }\n", "expected an expression, found _");
}

test "return leaves only the lambda, and break cannot leave one at all" {
    const program =
        \\func f(): Int {
        \\    [1, 2].each { n =>
        \\        return
        \\    }
        \\    return 9
        \\}
        \\print(f())
        \\
    ;
    try expectOutput(program, "9\n");
    try expectFailure(
        "for i in 1..2 {\n    [1].each { n =>\n        break\n    }\n}\n",
        "`break` can only be used inside a loop",
    );
}

test "section 7.4: a trailing block in a control-flow header needs parentheses" {
    try expectOutput("if ([1, 2].map { n => n }).count == 2 {\n    print(1)\n}\n", "1\n");
    // Without them the `{` opens the statement's body, which is exactly what
    // the diagnostic says.
    try expectFailure(
        "if [1, 2].map { n => n } {\n    print(1)\n}\n",
        "this `{` opens the body, so the block before it has nowhere to go",
    );
}

test "a captured block runs against the scopes it captured, not the caller's" {
    const program =
        \\var name = "outer"
        \\func run(block: func(): String): String {
        \\    var name = "inner"
        \\    return block()
        \\}
        \\print(run({ => name }))
        \\
    ;
    try expectOutput(program, "outer\n");
}

test "a call through a value names the binding when there is one" {
    try expectFailure(
        "const f = { n: Int => n }\nprint(f(1, 2))\n",
        "`f` takes 1 argument, but this call passes 2",
    );
    try expectFailure(
        "const fs: List[func(Int): Int] = [{ n => n }]\nprint(fs[0](1, 2))\n",
        "this takes 1 argument, but this call passes 2",
    );
    // A function stored in a list is called through the element.
    try expectOutput(
        "const fs: List[func(Int): Int] = [{ n => n }, { n => n * 2 }]\nprint(fs[1](5))\n",
        "10\n",
    );
}

test "each and map belong to lists, not to every value" {
    try expectFailure("\"abc\".each { c => print(c) }\n", "String has no method `each`");
    try expectFailure("print(5.map { n => n })\n", "Int has no method `map`");
    // Names from other languages point at Emerald's.
    try expectFailure("[1].collect { n => n }\n", "List[Int] has no method `collect`");
}

// Section 19.5's collector.

test "memory stays flat when a loop keeps making closures" {
    // `const block = { => i }` stores the closure in the very scope it
    // captured, so the two hold each other and reference counting alone never
    // reclaims either. This is the ordinary way to write a block, so without a
    // collector the cost grows with the loop.
    const program =
        \\var total = 0
        \\for i in 1..{d} {{
        \\    const block = {{ => i }}
        \\    total += block()
        \\}}
        \\print(total)
        \\
    ;
    var buffer: [256]u8 = undefined;
    const few = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{100}));
    const many = try peakMemory(try std.fmt.bufPrint(&buffer, program, .{50_000}));
    try testing.expect(many < few + 4 * 1024 * 1024);
}

test "a collection in the middle of building a value keeps the half-built value" {
    // Every allocation is a chance to collect, including the ones made while a
    // list literal or an interpolation is still being assembled. The pieces
    // already in hand are held by Zig locals and nothing else, which is exactly
    // the case the collector has to get right.
    const program =
        \\func label(n: Int): String {
        \\    return "#{n}:#{n * 2}"
        \\}
        \\var rows: List[List[String]] = []
        \\for i in 1..2000 {
        \\    rows.append([label(i), label(i + 1), label(i + 2)])
        \\}
        \\print(rows.count)
        \\print(rows[1999])
        \\
    ;
    try expectOutput(program, "2000\n[\"2000:4000\", \"2001:4002\", \"2002:4004\"]\n");
}

// Sections 4.2 and 4.5: optionals.

test "section 4.5: `or` supplies the value to use when there is none" {
    try expectOutput("print(\"42\".to_int_maybe().or(0))\n", "42\n");
    try expectOutput("print(\"no\".to_int_maybe().or(0))\n", "0\n");
    try expectOutput("print(\"no\".to_float_maybe().or(1.5))\n", "1.5\n");
    // The fallback widens the way it does anywhere else (4.4).
    try expectOutput("var rate: Float? = nothing\nprint(rate.or(1))\n", "1.0\n");
    // And it runs only when it is needed, as the `or` operator does.
    const lazily =
        \\var asked = 0
        \\func fallback(): Int {
        \\    asked += 1
        \\    return -1
        \\}
        \\var present: Int? = 7
        \\print(present.or(fallback()))
        \\print(asked)
        \\
    ;
    try expectOutput(lazily, "7\n0\n");
    try expectFailure("var n: Int = 1\nprint(n.or(0))\n", "`or` needs a value that may be absent, and this is already Int");
    try expectFailure("var n: Int? = 1\nprint(n.or(\"x\"))\n", "this is String, but the value it stands in for is Int");
}

test "section 4.5: comparison with `nothing` narrows" {
    try expectOutput("var n: Int? = 5\nif n != nothing {\n    print(n + 1)\n}\n", "6\n");
    try expectOutput("var n: Int? = 5\nif n == nothing {\n    print(0)\n} else {\n    print(n + 1)\n}\n", "6\n");
    // A guard narrows the whole rest of the block.
    const guard =
        \\func size(text: String?): Int {
        \\    return 0 if text == nothing
        \\    return text.count
        \\}
        \\print(size("hello"))
        \\print(size(nothing))
        \\
    ;
    try expectOutput(guard, "5\n0\n");
    // A `while` proves the same thing for its body.
    try expectOutputWithInput(
        "var line = input_maybe()\nwhile line != nothing {\n    print(line.upper())\n    line = input_maybe()\n}\n",
        "a\nb\n",
        "A\nB\n",
    );
}

test "narrowing does not escape the branch that proved it" {
    // Assigning inside a branch proves nothing after it.
    try expectFailure(
        "var n: Int? = nothing\nif 1 == 1 {\n    n = 5\n}\nprint(n + 1)\n",
        "addition needs numbers, but this is Int? and Int",
    );
    // Nor does a loop body, which may not have run.
    try expectFailure(
        "var n: Int? = nothing\nwhile 1 == 2 {\n    n = 5\n}\nprint(n + 1)\n",
        "addition needs numbers, but this is Int? and Int",
    );
    // Assigning `nothing` ends a proof that was holding.
    try expectFailure(
        "var n: Int? = 5\nif n != nothing {\n    n = nothing\n    print(n + 1)\n}\n",
        "addition needs numbers, but this is Int? and Int",
    );
    // Section 4.5: a `var` a block can reassign is never narrowed, because
    // calling the block between the test and the use is all it takes.
    try expectFailure(
        "var n: Int? = 5\nconst clear = { => n = nothing }\nif n != nothing {\n    clear()\n    print(n + 1)\n}\n",
        "addition needs numbers, but this is Int? and Int",
    );
    // A `const` keeps it, because it cannot be rebound at all.
    try expectOutput(
        "const n: Int? = 5\nconst show = { => print(1) }\nif n != nothing {\n    show()\n    print(n + 1)\n}\n",
        "1\n6\n",
    );
}

test "assigning a value that is certainly there proves it is" {
    try expectOutput("var n: Int? = nothing\nn = 5\nprint(n + 1)\n", "6\n");
    try expectFailure(
        "var n: Int? = 5\nn = nothing\nprint(n + 1)\n",
        "addition needs numbers, but this is Int? and Int",
    );
}

test "a value that may be absent cannot be used until it is there" {
    try expectFailure("var s: String? = \"a\"\nprint(s.count)\n", "this is String?, so `count` may not be there to use");
    try expectFailure("var s: String? = \"a\"\nprint(s.upper())\n", "this is String?, so `upper` may not be there to use");
    try expectFailure("var s: String? = \"a\"\nprint(s + \"b\")\n", "`+` joins two Strings, but this is String? and String");
    try expectFailure("var xs: List[Int]? = nothing\nprint(xs[0])\n", "this is List[Int]?, so it may not be there to use");
    try expectFailure("var xs: List[Int]? = nothing\nfor x in xs {\n    print(x)\n}\n", "this is List[Int]?, so it may not be there to use");
    try expectFailure("var xs: List[Int]? = nothing\nxs[0] = 1\n", "this is List[Int]?, so there may be nothing to assign into");
    try expectFailure("var n: Int? = 1\nprint(n < 2)\n", "`<` needs numbers, but these are Int? values");
}

test "sections 8.5, 8.6, and 9.2: what may come back empty-handed" {
    try expectOutput("print([3, 8].first.or(-1))\nprint([3, 8].last.or(-1))\n", "3\n8\n");
    try expectOutput("const e: List[Int] = []\nprint(e.first.or(-1))\nprint(e.last.or(-1))\n", "-1\n-1\n");
    try expectOutput("print([3, 8, 9].find { n => n > 5 }.or(-1))\n", "8\n");
    try expectOutput("print([3, 8, 9].find { n => n > 90 }.or(-1))\n", "-1\n");
    try expectOutput("print([3, 8, 9].find_index { n => n > 5 }.or(-1))\n", "1\n");
    try expectOutput("print([3, 8, 9].find_index { n => n > 90 }.or(-1))\n", "-1\n");
    // Section 9.2: the index counts characters, so it indexes directly.
    try expectOutput("print(\"hello\".index_of(\"ll\").or(-1))\n", "2\n");
    try expectOutput("print(\"hello\".index_of(\"z\").or(-1))\n", "-1\n");
    try expectOutput("const t = \"héllo\"\nprint(t[t.index_of(\"llo\").or(0)])\n", "l\n");
}

test "section 15.2: input_maybe reports the end of the input as absence" {
    try expectOutputWithInput("print(input_maybe().or(\"none\"))\n", "", "none\n");
    try expectOutputWithInput("print(input_maybe().or(\"none\"))\n", "Ada\n", "Ada\n");
    // `input` still raises there, and now names the companion.
    try expectFailure("var p = print\n", "`print` is built in, and built-in functions cannot be used as values");
}

test "section 4.5: a literal mixing `nothing` needs its type from context" {
    try expectOutput("var each: List[String?] = [nothing, \"Ava\"]\nprint(each)\n", "[nothing, \"Ava\"]\n");
    try expectFailure("var each = [nothing, \"Ava\"]\n", "this list mixes `nothing` with String, so its type has to be written");
    // Placement is structural: these are different types.
    try expectFailure(
        "var whole: List[String]? = nothing\nvar each: List[String?] = whole\n",
        "this is List[String]?, but `each` was declared as List[String?]",
    );
}

test "section 3.4: a keyword may name a member, which is what `.or` needs" {
    try expectOutput("var n: Int? = nothing\nprint(n.or(7))\n", "7\n");
    // Declaring one is still an ordinary name.
    try expectFailure("func or(): Int {\n    return 1\n}\n", "expected a name after `func`, found or");
}
