//! Section 7.3's matching of a call's arguments to the parameters it reaches.
//!
//! Positional arguments fill parameters from the left; named arguments fill the
//! parameter they name, which lets a call skip defaulted parameters. The checker
//! reports the first problem this finds, and the interpreter repeats the same
//! matching on a call the checker accepted, so the two cannot disagree about
//! which value goes where.

const std = @import("std");
const Ast = @import("Ast.zig");

pub const Problem = union(enum) {
    none,
    /// The argument at this index has no name but follows one that does.
    positional_after_named: usize,
    /// More positional arguments than parameters; the index of the first extra.
    too_many: usize,
    /// The argument at this index names no parameter.
    unknown_name: usize,
    /// The argument at this index names a parameter already given a value.
    duplicate: usize,
    /// The parameter at this index has no argument and no default.
    missing: usize,
    /// A trailing block for a final parameter that a named argument already
    /// gave a value.
    trailing_duplicate: usize,
};

/// Fills `out[p]` with the index of the argument that gives parameter `p` its
/// value, or null when it is left to its default.
pub fn bind(
    call: Ast.Expression.Call,
    parameter_names: []const []const u8,
    has_default: []const bool,
    out: []?usize,
) Problem {
    std.debug.assert(out.len == parameter_names.len);
    @memset(out, null);
    var next_position: usize = 0;
    var seen_named = false;
    for (call.arguments, 0..) |_, index| {
        // Section 7.4: a trailing block occupies the final argument position,
        // whatever was named or skipped inside the parentheses.
        if (call.trailing and index + 1 == call.arguments.len) {
            if (parameter_names.len == 0 or next_position >= parameter_names.len) return .{ .too_many = index };
            const last = parameter_names.len - 1;
            if (out[last] != null) return .{ .trailing_duplicate = last };
            out[last] = index;
            continue;
        }
        if (nameOf(call, index)) |name| {
            seen_named = true;
            const parameter = for (parameter_names, 0..) |candidate, position| {
                if (std.mem.eql(u8, candidate, name.text)) break position;
            } else return .{ .unknown_name = index };
            if (out[parameter] != null) return .{ .duplicate = index };
            out[parameter] = index;
            continue;
        }
        if (seen_named) return .{ .positional_after_named = index };
        if (next_position >= parameter_names.len) return .{ .too_many = index };
        out[next_position] = index;
        next_position += 1;
    }
    for (out, has_default, 0..) |bound, defaulted, position| {
        if (bound == null and !defaulted) return .{ .missing = position };
    }
    return .none;
}

pub fn nameOf(call: Ast.Expression.Call, index: usize) ?Ast.Expression.Call.ArgumentName {
    if (call.names.len == 0) return null;
    return call.names[index];
}

/// Whether the call is the plain shape every call had before 7.3: no names,
/// and one argument for every parameter. A trailing block is then the last of
/// them, where it belongs anyway.
pub fn isPlain(call: Ast.Expression.Call, parameter_count: usize) bool {
    return call.names.len == 0 and call.arguments.len == parameter_count;
}

test "positional then named, skipping a default" {
    const names = [_][]const u8{ "a", "b", "c" };
    const defaults = [_]bool{ false, true, true };
    var expression: Ast.Expression = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .nothing_literal = {} } };
    const arguments = [_]*const Ast.Expression{ &expression, &expression };
    const call_names = [_]?Ast.Expression.Call.ArgumentName{ null, .{ .text = "c", .span = .{ .start = 0, .end = 0 } } };
    const call: Ast.Expression.Call = .{ .callee = &expression, .arguments = &arguments, .names = &call_names };
    var out: [3]?usize = undefined;
    try std.testing.expectEqual(Problem.none, bind(call, &names, &defaults, &out));
    try std.testing.expectEqual(@as(?usize, 0), out[0]);
    try std.testing.expectEqual(@as(?usize, null), out[1]);
    try std.testing.expectEqual(@as(?usize, 1), out[2]);
}

test "a trailing block fills the final parameter after named ones" {
    const names = [_][]const u8{ "times", "gap", "block" };
    const defaults = [_]bool{ false, true, false };
    var expression: Ast.Expression = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .nothing_literal = {} } };
    const arguments = [_]*const Ast.Expression{ &expression, &expression };
    const call_names = [_]?Ast.Expression.Call.ArgumentName{ .{ .text = "times", .span = .{ .start = 0, .end = 0 } }, null };
    const call: Ast.Expression.Call = .{ .callee = &expression, .arguments = &arguments, .names = &call_names, .trailing = true };
    var out: [3]?usize = undefined;
    try std.testing.expectEqual(Problem.none, bind(call, &names, &defaults, &out));
    try std.testing.expectEqual(@as(?usize, 0), out[0]);
    try std.testing.expectEqual(@as(?usize, null), out[1]);
    try std.testing.expectEqual(@as(?usize, 1), out[2]);
}

test "a missing required parameter is found after every argument is placed" {
    const names = [_][]const u8{ "a", "b" };
    const defaults = [_]bool{ false, false };
    var expression: Ast.Expression = .{ .span = .{ .start = 0, .end = 0 }, .data = .{ .nothing_literal = {} } };
    const arguments = [_]*const Ast.Expression{&expression};
    const call_names = [_]?Ast.Expression.Call.ArgumentName{.{ .text = "b", .span = .{ .start = 0, .end = 0 } }};
    const call: Ast.Expression.Call = .{ .callee = &expression, .arguments = &arguments, .names = &call_names };
    var out: [2]?usize = undefined;
    try std.testing.expectEqual(Problem{ .missing = 0 }, bind(call, &names, &defaults, &out));
}
