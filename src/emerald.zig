//! The Emerald frontend library.
//!
//! The pipeline described in section 19.2 is source manager, lexer, parser,
//! resolver, checker, interpreter. The source manager, diagnostics, and lexer
//! exist so far; later stages are added as their slices land.

const std = @import("std");

pub const Source = @import("Source.zig");
pub const Diagnostic = @import("Diagnostic.zig");
pub const Token = @import("Token.zig");
pub const Lexer = @import("Lexer.zig");

/// Everything `check` found. Empty means the file passed every check that exists.
pub const Report = struct {
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        gpa.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn ok(self: Report) bool {
        return self.diagnostics.len == 0;
    }
};

/// Analyses an already-loaded source file without running it.
///
/// Encoding and lexical structure are what exist to check so far. Parsing,
/// resolution, and type checking join this function as they are built.
pub fn check(gpa: std.mem.Allocator, source: *const Source) !Report {
    // An encoding failure stops the pipeline. Section 3.1 requires the offending
    // byte span, and lexing bytes that are not text would only invent confusion
    // on top of a problem the reader must fix first.
    if (Source.findInvalidUtf8(source.text)) |span| {
        const only = try gpa.alloc(Diagnostic, 1);
        only[0] = .{
            .message = "this is not valid UTF-8 text",
            .span = span,
            .help = "Emerald source files are always UTF-8. Re-save this file as UTF-8.",
        };
        return .{ .diagnostics = only };
    }

    // Nothing consumes tokens yet; the parser slice will keep them.
    const tokenized = try Lexer.tokenize(gpa, source);
    gpa.free(tokenized.tokens);
    return .{ .diagnostics = tokenized.diagnostics };
}

const testing = std.testing;

test {
    _ = Source;
    _ = Diagnostic;
    _ = Token;
    _ = Lexer;
}

test "a well-formed file reports nothing" {
    var source = try Source.init(testing.allocator, "main.em", "var score = 2 + 3 * 4\nprint(score)\n");
    defer source.deinit(testing.allocator);

    var report = try check(testing.allocator, &source);
    defer report.deinit(testing.allocator);

    try testing.expect(report.ok());
}

test "a lexical problem is reported" {
    var source = try Source.init(testing.allocator, "main.em", "var count = 0xFF\n");
    defer source.deinit(testing.allocator);

    var report = try check(testing.allocator, &source);
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try testing.expectEqualStrings(
        "Emerald writes numbers in decimal only",
        report.diagnostics[0].message,
    );
}

test "a malformed byte is reported where it occurs" {
    var source = try Source.init(testing.allocator, "main.em", "var name = \"Ava\"\nvar bad = \"\xFF\"\n");
    defer source.deinit(testing.allocator);

    var report = try check(testing.allocator, &source);
    defer report.deinit(testing.allocator);

    const rendered = try report.diagnostics[0].renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);

    // Written with escapes rather than a multiline literal so the offending byte
    // is a real 0xFF in the expected text.
    const expected =
        "main.em:2:12: this is not valid UTF-8 text\n" ++
        "  var bad = \"\xFF\"\n" ++
        "             ^\n" ++
        "Emerald source files are always UTF-8. Re-save this file as UTF-8.\n";

    try testing.expectEqualStrings(expected, rendered);
}
