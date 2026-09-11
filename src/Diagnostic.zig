//! One reported problem in a source file, and its canonical rendering.
//!
//! The rendered shape is fixed by section 17.1 of the rewrite context and answers
//! four questions: where the problem is, what the compiler understood, why that is
//! invalid, and what correction is likely.
//!
//!     main.em:7:9: `score` may not have been assigned
//!       print(score)
//!             ^^^^^
//!     Assign `score` on every branch before reading it.
//!
//! The format is covered by tests because section 17.2 requires diagnostic text
//! itself to receive behavioral tests.
//!
//! A runtime error raised inside a function also carries its stack trace, which
//! section 13.2 asks for: each active call, innermost first, with where it was
//! called from.
//!
//!     main.em:2:12: division by zero
//!       return left / right
//!              ^^^^^^^^^^^^
//!     Check the divisor before dividing. ...
//!     in `divide`, called at main.em:6:7
//!
//! Section 7.2 asks for repeated frames to be summarized, so a run of identical
//! frames prints once with a count: `in `loop`, called at main.em:2:12 (999 times)`.

const std = @import("std");
const Source = @import("Source.zig");

const Diagnostic = @This();

/// One active call when a runtime error was raised.
pub const Frame = struct {
    function: []const u8,
    call_span: Source.Span,
};

/// What is wrong, in the user's vocabulary. Never names an implementation detail.
message: []const u8,
/// The source range to underline.
span: Source.Span,
/// The concrete correction to suggest.
help: []const u8,
/// The calls active when a runtime error was raised, innermost first. Empty for
/// every diagnostic reported before a program runs.
trace: []const Frame = &.{},

/// The indentation applied to the quoted source line and its underline.
const gutter = "  ";

pub fn render(self: Diagnostic, source: Source, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const start = source.location(self.span.start);
    try writer.print("{s}:{d}:{d}: {s}\n", .{
        source.path,
        start.line,
        start.column,
        self.message,
    });

    const line_text = source.lineText(start.line);
    try writer.print("{s}{s}\n", .{ gutter, line_text });

    try writer.writeAll(gutter);
    try writer.splatByteAll(' ', start.column - 1);
    try writer.splatByteAll('^', self.underlineWidth(source, start.line));
    try writer.writeAll("\n");

    try writer.print("{s}\n", .{self.help});

    var index: usize = 0;
    while (index < self.trace.len) {
        const frame = self.trace[index];
        var repeats: usize = 1;
        while (index + repeats < self.trace.len and sameFrame(self.trace[index + repeats], frame)) {
            repeats += 1;
        }

        const called_at = source.location(frame.call_span.start);
        try writer.print("in `{s}`, called at {s}:{d}:{d}", .{
            frame.function,
            source.path,
            called_at.line,
            called_at.column,
        });
        if (repeats > 1) try writer.print(" ({d} times)", .{repeats});
        try writer.writeAll("\n");

        index += repeats;
    }
}

fn sameFrame(a: Frame, b: Frame) bool {
    return a.call_span.start == b.call_span.start and std.mem.eql(u8, a.function, b.function);
}

/// The underline covers the span, measured in scalars so it lines up with the
/// column arithmetic, and never extends past the end of the quoted line. A span
/// that is empty or crosses a line boundary still marks one column.
fn underlineWidth(self: Diagnostic, source: Source, line: u32) u32 {
    const line_text = source.lineText(line);
    const line_start = source.line_starts[line - 1];
    const line_end: u32 = line_start + @as(u32, @intCast(line_text.len));

    const clipped_end = @min(self.span.end, line_end);
    if (clipped_end <= self.span.start) return 1;

    const width = scalarCount(source.text[self.span.start..clipped_end]);
    return @max(width, 1);
}

fn scalarCount(bytes: []const u8) u32 {
    var count: u32 = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// Renders into freshly allocated memory. The caller owns the result.
pub fn renderAlloc(
    self: Diagnostic,
    gpa: std.mem.Allocator,
    source: Source,
) std.mem.Allocator.Error![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(gpa);
    errdefer allocating.deinit();
    self.render(source, &allocating.writer) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

const testing = std.testing;

test "renders the canonical shape from section 17.1" {
    const text =
        \\func play() {
        \\    var score: Int
        \\
        \\    if won?() {
        \\        score = 1
        \\    }
        \\
        \\    print(score)
        \\}
        \\
    ;
    var source = try Source.init(testing.allocator, "main.em", text);
    defer source.deinit(testing.allocator);

    const start: u32 = @intCast(std.mem.indexOf(u8, source.text, "score)").?);
    const diagnostic: Diagnostic = .{
        .message = "`score` may not have been assigned",
        .span = .{ .start = start, .end = start + 5 },
        .help = "Assign `score` on every branch before reading it.",
    };

    const rendered = try diagnostic.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        \\main.em:8:11: `score` may not have been assigned
        \\      print(score)
        \\            ^^^^^
        \\Assign `score` on every branch before reading it.
        \\
    , rendered);
}

test "the underline aligns past multi-byte scalars" {
    var source = try Source.init(testing.allocator, "main.em", "var gift = \"héllo\" + 1\n");
    defer source.deinit(testing.allocator);

    const start: u32 = @intCast(std.mem.indexOf(u8, source.text, "+ 1").? + 2);
    const diagnostic: Diagnostic = .{
        .message = "`String` and `Int` cannot be added",
        .span = .{ .start = start, .end = start + 1 },
        .help = "Convert the number with `to_string()` first.",
    };

    const rendered = try diagnostic.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);

    // "héllo" is six bytes but five scalars, so the caret sits under `1` at column 22.
    try testing.expectEqualStrings(
        \\main.em:1:22: `String` and `Int` cannot be added
        \\  var gift = "héllo" + 1
        \\                       ^
        \\Convert the number with `to_string()` first.
        \\
    , rendered);
}

test "an underline never runs past the end of its line" {
    var source = try Source.init(testing.allocator, "main.em", "abc\ndef\n");
    defer source.deinit(testing.allocator);

    const diagnostic: Diagnostic = .{
        .message = "spans stop at the line end",
        .span = .{ .start = 0, .end = 7 },
        .help = "Nothing to do.",
    };

    const rendered = try diagnostic.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        \\main.em:1:1: spans stop at the line end
        \\  abc
        \\  ^^^
        \\Nothing to do.
        \\
    , rendered);
}

test "an empty span still marks one column" {
    var source = try Source.init(testing.allocator, "main.em", "abc\n");
    defer source.deinit(testing.allocator);

    const diagnostic: Diagnostic = .{
        .message = "empty spans are still visible",
        .span = .{ .start = 1, .end = 1 },
        .help = "Nothing to do.",
    };

    const rendered = try diagnostic.renderAlloc(testing.allocator, source);
    defer testing.allocator.free(rendered);

    try testing.expectEqualStrings(
        \\main.em:1:2: empty spans are still visible
        \\  abc
        \\   ^
        \\Nothing to do.
        \\
    , rendered);
}
