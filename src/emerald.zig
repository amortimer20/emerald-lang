//! The Emerald frontend library.
//!
//! The pipeline described in section 19.2 is source manager, lexer, parser,
//! resolver, checker, interpreter. Only the source manager and diagnostics exist
//! so far; later stages are added as their slices land.

const std = @import("std");

pub const Source = @import("Source.zig");
pub const Diagnostic = @import("Diagnostic.zig");

/// Reports the first problem in an already-loaded source file, or null when there
/// is nothing to report.
///
/// Encoding is currently the only thing that can be checked: section 3.1 requires
/// source to be UTF-8 and requires malformed input to be reported at the offending
/// byte span. Lexical and semantic checks join this function as they are built.
pub fn check(source: Source) ?Diagnostic {
    if (Source.findInvalidUtf8(source.text)) |span| {
        return .{
            .message = "this is not valid UTF-8 text",
            .span = span,
            .help = "Emerald source files are always UTF-8. Re-save this file as UTF-8.",
        };
    }
    return null;
}

const testing = std.testing;

test {
    _ = Source;
    _ = Diagnostic;
}

test "a well-formed file reports nothing" {
    var source = try Source.init(testing.allocator, "main.em", "var score = 2 + 3 * 4\n");
    defer source.deinit(testing.allocator);

    try testing.expect(check(source) == null);
}

test "a malformed byte is reported where it occurs" {
    var source = try Source.init(testing.allocator, "main.em", "var name = \"Ava\"\nvar bad = \"\xFF\"\n");
    defer source.deinit(testing.allocator);

    const diagnostic = check(source).?;
    const rendered = try diagnostic.renderAlloc(testing.allocator, source);
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
