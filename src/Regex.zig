//! Section 15.4's regular expressions: Emerald's own engine
//! (docs/regex-design-plan.md). A pattern is parsed into a small syntax tree,
//! compiled to instructions, and run by a Pike VM: every way the pattern could
//! match advances through the text together, one grapheme at a time, so
//! matching takes time in proportion to the pattern times the text, whatever
//! the pattern. That guarantee is why backreferences and lookaround are
//! refused rather than supported.
//!
//! The text is matched as graphemes, the characters section 9.1 counts, so `.`
//! is one character as `count` sees it and no match splits one. A literal
//! compares canonically, as `==` does, and a set such as `[a-z]` decides by a
//! character's first code point in its NFC form, so the same character matches
//! the same way however it is encoded. Positions are grapheme indices.

const std = @import("std");
const unicode = @import("unicode.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    ignore_case: bool = false,
    multiline: bool = false,
};

/// The largest count a repetition such as `x{3}` may ask for.
pub const max_repetition = 1000;
/// The most instructions a pattern may compile to, and the most capture slots
/// a matcher may track at once, so no pattern asks for unbounded memory.
pub const max_instructions = 50_000;
pub const max_thread_slots = 4_000_000;

pub const CompileError = Allocator.Error || error{InvalidPattern};

/// Why a pattern was refused, and where: `position` counts the pattern's
/// graphemes from zero. The message does not quote the pattern; the caller
/// adds that.
pub const Problem = struct {
    position: usize = 0,
    buffer: [400]u8 = undefined,
    length: usize = 0,

    pub fn message(self: *const Problem) []const u8 {
        return self.buffer[0..self.length];
    }

    fn fail(self: *Problem, position: usize, comptime format: []const u8, arguments: anytype) error{InvalidPattern} {
        self.position = position;
        const written: []const u8 = std.fmt.bufPrint(&self.buffer, format, arguments) catch &self.buffer;
        self.length = written.len;
        return error.InvalidPattern;
    }
};

/// Why a construct other engines accept is refused.
const linear_reason = "which Emerald's regular expressions do not support, so that matching always takes time in proportion to the text";

// Sets of characters.

const Shorthand = enum { digit, word, space };

const ClassItem = union(enum) {
    range: [2]u21,
    shorthand: struct { kind: Shorthand, negated: bool },
};

pub const Class = struct {
    negated: bool = false,
    items: []const ClassItem,

    fn contains(self: *const Class, code_point: u21) bool {
        for (self.items) |item| switch (item) {
            .range => |range| if (range[0] <= code_point and code_point <= range[1]) return true,
            .shorthand => |shorthand| if (shorthandMatches(shorthand.kind, code_point) != shorthand.negated) return true,
        };
        return false;
    }

    fn matches(self: *const Class, code_point: u21, ignore_case: bool) bool {
        var found = self.contains(code_point);
        if (!found and ignore_case) {
            const folded = unicode.simpleFold(code_point);
            for ([_]u21{ folded, unicode.simpleLower(code_point), unicode.simpleUpper(code_point), unicode.simpleUpper(folded) }) |variant| {
                if (variant != code_point and self.contains(variant)) {
                    found = true;
                    break;
                }
            }
        }
        return found != self.negated;
    }
};

fn shorthandMatches(kind: Shorthand, code_point: u21) bool {
    return switch (kind) {
        // ASCII only, so a matched number always converts with `to_int`.
        .digit => code_point >= '0' and code_point <= '9',
        .word => unicode.isWordCharacter(code_point),
        .space => unicode.isWhiteSpace(code_point),
    };
}

// The program.

const Assertion = enum { line_start, line_end, word_boundary, not_word_boundary };

const Instruction = union(enum) {
    /// One grapheme, in NFC.
    literal: []const u8,
    /// Any grapheme except a line break.
    any,
    class: *const Class,
    /// Try `first`, and failing that `second`.
    split: struct { first: u32, second: u32 },
    jump: u32,
    save: u32,
    assert: Assertion,
    match,
};

pub const Name = struct { name: []const u8, number: u32 };

pub const Program = struct {
    arena_state: std.heap.ArenaAllocator,
    instructions: []const Instruction,
    /// Numbered groups, not counting group 0, the whole match.
    group_count: u32,
    names: []const Name,
    options: Options,

    pub fn deinit(self: *Program) void {
        self.arena_state.deinit();
    }

    /// Two slots per group, group 0 included: where it starts and ends.
    pub fn slotCount(self: *const Program) usize {
        return 2 * (@as(usize, self.group_count) + 1);
    }

    pub fn groupNumber(self: *const Program, name: []const u8) ?u32 {
        for (self.names) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.number;
        return null;
    }
};

pub fn compile(gpa: Allocator, pattern: []const u8, options: Options, problem: *Problem) CompileError!Program {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var characters: std.ArrayList([]const u8) = .empty;
    var clusters: unicode.Graphemes = .init(pattern);
    while (clusters.next()) |cluster| try characters.append(arena, cluster);

    var parser: Parser = .{ .arena = arena, .characters = characters.items, .problem = problem };
    const tree = try parser.parseAlternation();
    if (parser.at < parser.characters.len) {
        // Only an unmatched `)` stops the top level early.
        return problem.fail(parser.at, "a \")\" here has no \"(\" to close", .{});
    }

    var compiler: Compiler = .{ .arena = arena, .problem = problem };
    _ = try compiler.emit(.{ .save = 0 });
    try compiler.compile(tree);
    _ = try compiler.emit(.{ .save = 1 });
    _ = try compiler.emit(.match);

    const slots = 2 * (@as(usize, parser.group_count) + 1);
    if (compiler.instructions.items.len * slots > max_thread_slots) {
        return problem.fail(0, "this pattern is too large: it has too many groups for its size", .{});
    }
    return .{
        .arena_state = arena_state,
        .instructions = compiler.instructions.items,
        .group_count = parser.group_count,
        .names = parser.names.items,
        .options = options,
    };
}

// Parsing.

const Node = struct {
    position: usize,
    kind: union(enum) {
        empty,
        literal: []const u8,
        any,
        class: *const Class,
        assertion: Assertion,
        group: struct { child: *const Node, number: ?u32 },
        concat: []const *const Node,
        alternate: []const *const Node,
        repeat: struct { child: *const Node, min: u32, max: ?u32, greedy: bool },
    },
};

const Parser = struct {
    arena: Allocator,
    characters: []const []const u8,
    problem: *Problem,
    at: usize = 0,
    group_count: u32 = 0,
    names: std.ArrayList(Name) = .empty,

    fn is(character: []const u8, byte: u8) bool {
        return character.len == 1 and character[0] == byte;
    }

    fn peekIs(self: *const Parser, byte: u8) bool {
        return self.at < self.characters.len and is(self.characters[self.at], byte);
    }

    fn peekAheadIs(self: *const Parser, offset: usize, byte: u8) bool {
        return self.at + offset < self.characters.len and is(self.characters[self.at + offset], byte);
    }

    fn node(self: *Parser, position: usize, kind: @FieldType(Node, "kind")) Allocator.Error!*const Node {
        const result = try self.arena.create(Node);
        result.* = .{ .position = position, .kind = kind };
        return result;
    }

    fn parseAlternation(self: *Parser) CompileError!*const Node {
        const position = self.at;
        var branches: std.ArrayList(*const Node) = .empty;
        try branches.append(self.arena, try self.parseConcat());
        while (self.peekIs('|')) {
            self.at += 1;
            try branches.append(self.arena, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(position, .{ .alternate = branches.items });
    }

    fn parseConcat(self: *Parser) CompileError!*const Node {
        const position = self.at;
        var items: std.ArrayList(*const Node) = .empty;
        while (self.at < self.characters.len and !self.peekIs('|') and !self.peekIs(')')) {
            const item = try self.parseRepeat();
            // Two literals that together make one character, such as `\r\n`
            // or `e` and a combining accent, match that one character.
            if (item.kind == .literal and items.items.len > 0) {
                const previous = items.items[items.items.len - 1];
                if (previous.kind == .literal) {
                    const joined = try std.mem.concat(self.arena, u8, &.{ previous.kind.literal, item.kind.literal });
                    if (unicode.graphemeCount(joined) == 1) {
                        items.items[items.items.len - 1] = try self.node(previous.position, .{ .literal = try unicode.normalize(self.arena, joined) });
                        continue;
                    }
                }
            }
            try items.append(self.arena, item);
        }
        return switch (items.items.len) {
            0 => self.node(position, .empty),
            1 => items.items[0],
            else => self.node(position, .{ .concat = items.items }),
        };
    }

    fn parseRepeat(self: *Parser) CompileError!*const Node {
        const atom = try self.parseAtom();
        if (self.at >= self.characters.len) return atom;
        const position = self.at;
        var min: u32 = undefined;
        var max: ?u32 = undefined;
        const character = self.characters[self.at];
        if (is(character, '*')) {
            min = 0;
            max = null;
            self.at += 1;
        } else if (is(character, '+')) {
            min = 1;
            max = null;
            self.at += 1;
        } else if (is(character, '?')) {
            min = 0;
            max = 1;
            self.at += 1;
        } else if (is(character, '{')) {
            const counts = try self.parseCounts();
            min = counts[0];
            max = counts[1];
        } else return atom;

        if (atom.kind == .assertion) {
            return self.problem.fail(position, "\"{s}\" here repeats an anchor, which matches no characters; remove the repetition", .{character});
        }
        var greedy = true;
        if (self.peekIs('?')) {
            greedy = false;
            self.at += 1;
        } else if (self.peekIs('+')) {
            return self.problem.fail(self.at, "\"{s}+\" is possessive repetition, {s}", .{ character, linear_reason });
        }
        if (self.peekIs('*') or self.peekIs('+') or self.peekIs('?') or self.peekIs('{')) {
            return self.problem.fail(self.at, "\"{s}\" here repeats a repetition; wrap the first in (?:...) to repeat it again", .{self.characters[self.at]});
        }
        return self.node(position, .{ .repeat = .{ .child = atom, .min = min, .max = max, .greedy = greedy } });
    }

    /// `{3}`, `{2,}`, or `{2,5}`, starting at the `{`.
    fn parseCounts(self: *Parser) CompileError!struct { u32, ?u32 } {
        const position = self.at;
        self.at += 1;
        const min = self.parseNumber() orelse return self.badBrace(position);
        var max: ?u32 = min;
        if (self.peekIs(',')) {
            self.at += 1;
            max = if (self.peekIs('}')) null else self.parseNumber() orelse return self.badBrace(position);
        }
        if (!self.peekIs('}')) return self.badBrace(position);
        self.at += 1;
        if (min > max_repetition or (max != null and max.? > max_repetition)) {
            return self.problem.fail(position, "a repetition count above {d} is too large", .{max_repetition});
        }
        if (max != null and max.? < min) {
            return self.problem.fail(position, "the repetition {{{d},{d}}} asks for at most fewer than at least; write {{{d},{d}}}", .{ min, max.?, max.?, min });
        }
        return .{ min, max };
    }

    fn badBrace(self: *Parser, position: usize) error{InvalidPattern} {
        return self.problem.fail(position, "\"{{\" here does not start a repetition such as {{3}} or {{2,5}}; write \\{{ for a literal brace", .{});
    }

    fn parseNumber(self: *Parser) ?u32 {
        var value: u32 = 0;
        const start = self.at;
        while (self.at < self.characters.len) {
            const character = self.characters[self.at];
            if (character.len != 1 or !std.ascii.isDigit(character[0])) break;
            value = @min(value * 10 + (character[0] - '0'), max_repetition + 1);
            self.at += 1;
        }
        return if (self.at == start) null else value;
    }

    fn parseAtom(self: *Parser) CompileError!*const Node {
        const position = self.at;
        const character = self.characters[self.at];
        if (character.len == 1) switch (character[0]) {
            '(' => return self.parseGroup(),
            '[' => return self.node(position, .{ .class = try self.parseClass() }),
            '.' => {
                self.at += 1;
                return self.node(position, .any);
            },
            '^' => {
                self.at += 1;
                return self.node(position, .{ .assertion = .line_start });
            },
            '$' => {
                self.at += 1;
                return self.node(position, .{ .assertion = .line_end });
            },
            '\\' => return self.parseEscape(),
            '*', '+', '?', '{' => return self.problem.fail(position, "\"{s}\" here has nothing before it to repeat; write \\{s} to match it literally", .{ character, character }),
            else => {},
        };
        self.at += 1;
        return self.node(position, .{ .literal = try unicode.normalize(self.arena, character) });
    }

    fn parseGroup(self: *Parser) CompileError!*const Node {
        const position = self.at;
        self.at += 1;
        var number: ?u32 = null;
        if (self.peekIs('?')) {
            self.at += 1;
            if (self.peekIs(':')) {
                self.at += 1;
            } else if (self.peekIs('=') or self.peekIs('!')) {
                return self.problem.fail(position, "\"(?{s}\" here is lookahead, {s}", .{ self.characters[self.at], linear_reason });
            } else if (self.peekIs('<') and (self.peekAheadIs(1, '=') or self.peekAheadIs(1, '!'))) {
                return self.problem.fail(position, "\"(?<{s}\" here is lookbehind, {s}", .{ self.characters[self.at + 1], linear_reason });
            } else if (self.peekIs('<')) {
                self.at += 1;
                number = try self.parseName(position);
            } else if (self.peekIs('>')) {
                return self.problem.fail(position, "\"(?>\" here is an atomic group, {s}", .{linear_reason});
            } else if (self.peekIs('P')) {
                return self.problem.fail(position, "\"(?P\" here is Python's spelling; write (?<name>...) for a named group", .{});
            } else if (self.at < self.characters.len and self.characters[self.at].len == 1 and
                (std.ascii.isAlphabetic(self.characters[self.at][0]) or self.characters[self.at][0] == '-'))
            {
                return self.problem.fail(position, "\"(?{s}\" here is an inline flag; pass ignore_case: true or multiline: true to Regex instead", .{self.characters[self.at]});
            } else {
                return self.problem.fail(position, "\"(?\" here does not start a kind of group Emerald knows; use (?:...) or (?<name>...)", .{});
            }
        } else {
            self.group_count += 1;
            number = self.group_count;
        }
        const child = try self.parseAlternation();
        if (!self.peekIs(')')) return self.problem.fail(position, "a \"(\" here has no matching \")\"", .{});
        self.at += 1;
        return self.node(position, .{ .group = .{ .child = child, .number = number } });
    }

    /// A group's name after `(?<`, through the `>`; returns its number.
    fn parseName(self: *Parser, position: usize) CompileError!u32 {
        const start = self.at;
        var name: std.ArrayList(u8) = .empty;
        while (self.at < self.characters.len and !self.peekIs('>')) : (self.at += 1) {
            const character = self.characters[self.at];
            const code_point, const length = unicode.decode(character, 0);
            const allowed = length == character.len and if (self.at == start)
                unicode.isIdentifierStart(code_point)
            else
                unicode.isIdentifierContinue(code_point);
            if (!allowed) return self.problem.fail(self.at, "a group name is letters, digits, and underscores, starting with a letter or underscore", .{});
            try name.appendSlice(self.arena, character);
        }
        if (!self.peekIs('>')) return self.problem.fail(position, "a group name here has no closing \">\"", .{});
        if (name.items.len == 0) return self.problem.fail(position, "a named group needs a name between \"<\" and \">\"", .{});
        self.at += 1;
        for (self.names.items) |entry| {
            if (std.mem.eql(u8, entry.name, name.items)) return self.problem.fail(start, "the group name \"{s}\" is already used; each name belongs to one group", .{name.items});
        }
        self.group_count += 1;
        try self.names.append(self.arena, .{ .name = name.items, .number = self.group_count });
        return self.group_count;
    }

    fn parseEscape(self: *Parser) CompileError!*const Node {
        const position = self.at;
        self.at += 1;
        if (self.at >= self.characters.len) {
            return self.problem.fail(position, "a pattern cannot end with a single backslash; write \\\\ for a backslash", .{});
        }
        const character = self.characters[self.at];
        self.at += 1;
        if (character.len == 1) switch (character[0]) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                const item = shorthandItem(character[0]);
                const items = try self.arena.alloc(ClassItem, 1);
                items[0] = item;
                const class = try self.arena.create(Class);
                class.* = .{ .items = items };
                return self.node(position, .{ .class = class });
            },
            'b' => return self.node(position, .{ .assertion = .word_boundary }),
            'B' => return self.node(position, .{ .assertion = .not_word_boundary }),
            else => {},
        };
        const code_point = try self.escapedCharacter(position, character);
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch unreachable;
        return self.node(position, .{ .literal = try unicode.normalize(self.arena, buffer[0..length]) });
    }

    fn shorthandItem(letter: u8) ClassItem {
        const kind: Shorthand = switch (std.ascii.toLower(letter)) {
            'd' => .digit,
            'w' => .word,
            else => .space,
        };
        return .{ .shorthand = .{ .kind = kind, .negated = std.ascii.isUpper(letter) } };
    }

    /// The one character an escape such as `\n`, `\.`, or `\u{1F600}` stands
    /// for; `character` is what followed the backslash.
    fn escapedCharacter(self: *Parser, position: usize, character: []const u8) CompileError!u21 {
        if (character.len != 1) {
            return self.problem.fail(position, "\"\\{s}\" is not an escape; write {s} without the backslash", .{ character, character });
        }
        const letter = character[0];
        switch (letter) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'u' => return self.parseCodePoint(position),
            '1'...'9' => return self.problem.fail(position, "\"\\{c}\" here refers back to a group, {s}", .{ letter, linear_reason }),
            'k' => return self.problem.fail(position, "\"\\k\" here refers back to a group, {s}", .{linear_reason}),
            'A', 'z', 'Z', 'G' => return self.problem.fail(position, "\"\\{c}\" is not supported; use ^ and $ for the start and end of the text", .{letter}),
            'p', 'P' => return self.problem.fail(position, "Unicode property classes such as \\p{{L}} are not supported yet; use \\w, \\d, \\s, or a set such as [a-z]", .{}),
            else => {},
        }
        if (std.ascii.isAlphanumeric(letter)) {
            return self.problem.fail(position, "\"\\{c}\" is not an escape Emerald's regular expressions know; write {c} without the backslash to match it", .{ letter, letter });
        }
        // Any escaped punctuation or space stands for itself.
        return letter;
    }

    /// `\u{...}` after the `u`: one to six hex digits naming a code point.
    fn parseCodePoint(self: *Parser, position: usize) CompileError!u21 {
        if (!self.peekIs('{')) return self.badCodePoint(position);
        self.at += 1;
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.at < self.characters.len and !self.peekIs('}')) : (self.at += 1) {
            const character = self.characters[self.at];
            if (character.len != 1 or !std.ascii.isHex(character[0]) or digits == 6) return self.badCodePoint(position);
            value = value * 16 + (std.fmt.charToDigit(character[0], 16) catch unreachable);
            digits += 1;
        }
        if (!self.peekIs('}') or digits == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return self.badCodePoint(position);
        self.at += 1;
        return @intCast(value);
    }

    fn badCodePoint(self: *Parser, position: usize) error{InvalidPattern} {
        return self.problem.fail(position, "\\u{{...}} here needs one to six hex digits naming a Unicode character, such as \\u{{1F600}}", .{});
    }

    fn parseClass(self: *Parser) CompileError!*const Class {
        const position = self.at;
        self.at += 1;
        var negated = false;
        if (self.peekIs('^')) {
            negated = true;
            self.at += 1;
        }
        var items: std.ArrayList(ClassItem) = .empty;
        while (true) {
            if (self.at >= self.characters.len) return self.problem.fail(position, "a \"[\" here has no matching \"]\"", .{});
            if (self.peekIs(']')) {
                self.at += 1;
                break;
            }
            const start = self.at;
            const low = try self.parseClassAtom();
            if (self.peekIs('-') and self.at + 1 < self.characters.len and !self.peekAheadIs(1, ']')) {
                self.at += 1;
                const high = try self.parseClassAtom();
                if (low != .range or high != .range) {
                    return self.problem.fail(start, "a range in a set runs between two characters, not a shorthand such as \\d", .{});
                }
                if (low.range[0] > high.range[0]) {
                    return self.problem.fail(start, "this range runs backwards; put the smaller character first", .{});
                }
                try items.append(self.arena, .{ .range = .{ low.range[0], high.range[0] } });
            } else {
                try items.append(self.arena, low);
            }
        }
        if (items.items.len == 0) {
            return self.problem.fail(position, "an empty set \"[]\" matches nothing; write \\[\\] to match the brackets", .{});
        }
        const class = try self.arena.create(Class);
        class.* = .{ .negated = negated, .items = items.items };
        return class;
    }

    /// One character of a set, as a one-character range, or a shorthand.
    fn parseClassAtom(self: *Parser) CompileError!ClassItem {
        const position = self.at;
        const character = self.characters[self.at];
        if (is(character, '[')) {
            return self.problem.fail(position, "a \"[\" inside a set needs a backslash: write \\[", .{});
        }
        if (is(character, '\\')) {
            self.at += 1;
            if (self.at >= self.characters.len) return self.problem.fail(position, "a \"[\" here has no matching \"]\"", .{});
            const escaped = self.characters[self.at];
            self.at += 1;
            if (escaped.len == 1) switch (escaped[0]) {
                'd', 'D', 'w', 'W', 's', 'S' => return shorthandItem(escaped[0]),
                'b', 'B' => return self.problem.fail(position, "\"\\{s}\" is a word boundary, which a set cannot hold", .{escaped}),
                else => {},
            };
            const code_point = try self.escapedCharacter(position, escaped);
            return .{ .range = .{ code_point, code_point } };
        }
        self.at += 1;
        const normalized = try unicode.normalize(self.arena, character);
        const code_point, const length = unicode.decode(normalized, 0);
        if (length != normalized.len) {
            return self.problem.fail(position, "\"{s}\" is more than one code point, so a set cannot hold it; use (?:{s}|...) instead", .{ character, character });
        }
        return .{ .range = .{ code_point, code_point } };
    }
};

// Compiling.

const Compiler = struct {
    arena: Allocator,
    problem: *Problem,
    instructions: std.ArrayList(Instruction) = .empty,

    fn emit(self: *Compiler, instruction: Instruction) CompileError!u32 {
        if (self.instructions.items.len >= max_instructions) {
            return self.problem.fail(0, "this pattern is too large: it would compile to more than {d} steps", .{max_instructions});
        }
        try self.instructions.append(self.arena, instruction);
        return @intCast(self.instructions.items.len - 1);
    }

    fn here(self: *const Compiler) u32 {
        return @intCast(self.instructions.items.len);
    }

    fn compile(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.kind) {
            .empty => {},
            .literal => |text| _ = try self.emit(.{ .literal = text }),
            .any => _ = try self.emit(.any),
            .class => |class| _ = try self.emit(.{ .class = class }),
            .assertion => |assertion| _ = try self.emit(.{ .assert = assertion }),
            .group => |group| {
                if (group.number) |number| _ = try self.emit(.{ .save = 2 * number });
                try self.compile(group.child);
                if (group.number) |number| _ = try self.emit(.{ .save = 2 * number + 1 });
            },
            .concat => |items| for (items) |item| try self.compile(item),
            .alternate => |branches| {
                // split L1, next; L1: first; jump end; next: split L2, ...
                var exits: std.ArrayList(u32) = .empty;
                for (branches, 0..) |branch, index| {
                    if (index + 1 < branches.len) {
                        const split = try self.emit(.{ .split = .{ .first = 0, .second = 0 } });
                        try self.compile(branch);
                        try exits.append(self.arena, try self.emit(.{ .jump = 0 }));
                        self.instructions.items[split].split = .{ .first = split + 1, .second = self.here() };
                    } else {
                        try self.compile(branch);
                    }
                }
                for (exits.items) |exit| self.instructions.items[exit].jump = self.here();
            },
            .repeat => |repeat| {
                for (0..repeat.min) |_| try self.compile(repeat.child);
                if (repeat.max) |max| {
                    // Each optional copy may be skipped, which skips the rest.
                    var skips: std.ArrayList(u32) = .empty;
                    for (repeat.min..max) |_| {
                        try skips.append(self.arena, try self.emit(.{ .split = .{ .first = 0, .second = 0 } }));
                        try self.compile(repeat.child);
                    }
                    const end = self.here();
                    for (skips.items) |skip| self.setSplit(skip, skip + 1, end, repeat.greedy);
                } else {
                    const loop = try self.emit(.{ .split = .{ .first = 0, .second = 0 } });
                    try self.compile(repeat.child);
                    _ = try self.emit(.{ .jump = loop });
                    self.setSplit(loop, loop + 1, self.here(), repeat.greedy);
                }
            },
        }
    }

    fn setSplit(self: *Compiler, at: u32, body: u32, skip: u32, greedy: bool) void {
        self.instructions.items[at].split = if (greedy) .{ .first = body, .second = skip } else .{ .first = skip, .second = body };
    }
};

// The text.

/// A text divided into graphemes, once, for however many searches use it.
pub const Text = struct {
    bytes: []const u8,
    /// Where each grapheme starts, then the text's length.
    starts: []const usize,

    pub fn init(gpa: Allocator, bytes: []const u8) Allocator.Error!Text {
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(gpa);
        var clusters: unicode.Graphemes = .init(bytes);
        while (clusters.next()) |cluster| try starts.append(gpa, @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr));
        try starts.append(gpa, bytes.len);
        return .{ .bytes = bytes, .starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: Text, gpa: Allocator) void {
        gpa.free(self.starts);
    }

    pub fn count(self: Text) usize {
        return self.starts.len - 1;
    }

    pub fn grapheme(self: Text, index: usize) []const u8 {
        return self.bytes[self.starts[index]..self.starts[index + 1]];
    }

    /// The bytes from grapheme `start` up to grapheme `end`.
    pub fn slice(self: Text, start: usize, end: usize) []const u8 {
        return self.bytes[self.starts[start]..self.starts[end]];
    }
};

/// A slot no group has filled.
pub const unset = std.math.maxInt(usize);

pub const Mode = enum {
    /// The leftmost match at or after the start.
    search,
    /// A match that begins at the start and ends at the end of the text.
    whole,
};

// Matching.

/// What one grapheme is, worked out once for every thread that looks at it.
const Character = struct {
    /// In NFC.
    normalized: []const u8,
    /// The first code point of `normalized`.
    first: u21,
    line_break: bool,
    word: bool,
};

fn describe(scratch: Allocator, grapheme: []const u8) Allocator.Error!Character {
    if (grapheme.len == 1 and grapheme[0] < 0x80) {
        // ASCII on its own, the common case, is already in NFC.
        const byte = grapheme[0];
        return .{ .normalized = grapheme, .first = byte, .line_break = byte == '\n', .word = std.ascii.isAlphanumeric(byte) or byte == '_' };
    }
    const normalized = if (unicode.quickCheck(grapheme) == .yes) grapheme else try unicode.normalize(scratch, grapheme);
    const first, _ = unicode.decode(normalized, 0);
    return .{
        .normalized = normalized,
        .first = first,
        .line_break = std.mem.eql(u8, grapheme, "\n") or std.mem.eql(u8, grapheme, "\r\n"),
        .word = unicode.isWordCharacter(first),
    };
}

fn literalMatches(literal: []const u8, character: Character, ignore_case: bool) bool {
    if (std.mem.eql(u8, literal, character.normalized)) return true;
    if (!ignore_case) return false;
    var left: usize = 0;
    var right: usize = 0;
    while (left < literal.len and right < character.normalized.len) {
        const a, const a_length = unicode.decode(literal, left);
        const b, const b_length = unicode.decode(character.normalized, right);
        if (unicode.simpleFold(a) != unicode.simpleFold(b)) return false;
        left += a_length;
        right += b_length;
    }
    return left == literal.len and right == character.normalized.len;
}

/// The threads alive at one position: a sparse set of instruction indices, in
/// priority order, each with its capture slots.
const Threads = struct {
    dense: []u32,
    sparse: []u32,
    slots: []usize,
    len: usize = 0,

    fn init(gpa: Allocator, instruction_count: usize, slot_count: usize) Allocator.Error!Threads {
        const dense = try gpa.alloc(u32, instruction_count);
        errdefer gpa.free(dense);
        const sparse = try gpa.alloc(u32, instruction_count);
        errdefer gpa.free(sparse);
        const slots = try gpa.alloc(usize, instruction_count * slot_count);
        return .{ .dense = dense, .sparse = sparse, .slots = slots };
    }

    fn deinit(self: Threads, gpa: Allocator) void {
        gpa.free(self.dense);
        gpa.free(self.sparse);
        gpa.free(self.slots);
    }

    fn contains(self: *const Threads, pc: u32) bool {
        const index = self.sparse[pc];
        return index < self.len and self.dense[index] == pc;
    }

    fn insert(self: *Threads, pc: u32) usize {
        self.sparse[pc] = @intCast(self.len);
        self.dense[self.len] = pc;
        self.len += 1;
        return self.len - 1;
    }
};

const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, value: usize },
};

const Machine = struct {
    program: *const Program,
    slot_count: usize,
    stack: std.ArrayList(Frame) = .empty,
    gpa: Allocator,
    count: usize,
    /// Whether the characters just before and at the current position are
    /// line breaks and word characters, for the assertions.
    before: ?Character = null,
    current: ?Character = null,

    fn holds(self: *const Machine, assertion: Assertion, position: usize) bool {
        const multiline = self.program.options.multiline;
        return switch (assertion) {
            .line_start => position == 0 or (multiline and self.before.?.line_break),
            .line_end => position == self.count or (multiline and self.current.?.line_break),
            .word_boundary => self.isWordBefore() != self.isWordAt(),
            .not_word_boundary => self.isWordBefore() == self.isWordAt(),
        };
    }

    fn isWordBefore(self: *const Machine) bool {
        return if (self.before) |character| character.word else false;
    }

    fn isWordAt(self: *const Machine) bool {
        return if (self.current) |character| character.word else false;
    }

    /// Follows every instruction that consumes nothing from `start`, adding a
    /// thread to `list` at each one that does, with `slots` as the thread's
    /// captures so far. `slots` is changed while this runs and restored after.
    fn add(self: *Machine, list: *Threads, start: u32, position: usize, slots: []usize) Allocator.Error!void {
        self.stack.clearRetainingCapacity();
        try self.stack.append(self.gpa, .{ .explore = start });
        while (self.stack.pop()) |frame| switch (frame) {
            .restore => |restore| slots[restore.slot] = restore.value,
            .explore => |pc| {
                if (list.contains(pc)) continue;
                const index = list.insert(pc);
                switch (self.program.instructions[pc]) {
                    .jump => |target| try self.stack.append(self.gpa, .{ .explore = target }),
                    .split => |split| {
                        try self.stack.append(self.gpa, .{ .explore = split.second });
                        try self.stack.append(self.gpa, .{ .explore = split.first });
                    },
                    .save => |slot| {
                        try self.stack.append(self.gpa, .{ .restore = .{ .slot = slot, .value = slots[slot] } });
                        slots[slot] = position;
                        try self.stack.append(self.gpa, .{ .explore = pc + 1 });
                    },
                    .assert => |assertion| if (self.holds(assertion, position)) {
                        try self.stack.append(self.gpa, .{ .explore = pc + 1 });
                    },
                    .literal, .any, .class, .match => @memcpy(list.slots[index * self.slot_count ..][0..self.slot_count], slots),
                }
            },
        };
    }
};

/// Runs `program` over `text` from grapheme `start`. On a match, fills
/// `slots` (length `program.slotCount()`) with grapheme positions, `unset`
/// for a group that took no part, and returns true.
pub fn run(program: *const Program, gpa: Allocator, text: Text, start: usize, mode: Mode, slots: []usize) Allocator.Error!bool {
    var matcher = try Matcher.init(gpa, program);
    defer matcher.deinit();
    return matcher.run(text, start, mode, slots);
}

/// The working space for running one program, kept between runs so that
/// finding every match in a text allocates only once.
pub const Matcher = struct {
    program: *const Program,
    gpa: Allocator,
    current: Threads,
    next: Threads,
    working: []usize,
    scratch_state: std.heap.ArenaAllocator,
    stack: std.ArrayList(Frame) = .empty,

    pub fn init(gpa: Allocator, program: *const Program) Allocator.Error!Matcher {
        const slot_count = program.slotCount();
        const instruction_count = program.instructions.len;
        var current = try Threads.init(gpa, instruction_count, slot_count);
        errdefer current.deinit(gpa);
        var next = try Threads.init(gpa, instruction_count, slot_count);
        errdefer next.deinit(gpa);
        return .{
            .program = program,
            .gpa = gpa,
            .current = current,
            .next = next,
            .working = try gpa.alloc(usize, slot_count),
            .scratch_state = .init(gpa),
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.current.deinit(self.gpa);
        self.next.deinit(self.gpa);
        self.gpa.free(self.working);
        self.scratch_state.deinit();
        self.stack.deinit(self.gpa);
    }

    /// As `Regex.run`.
    pub fn run(self: *Matcher, text: Text, start: usize, mode: Mode, slots: []usize) Allocator.Error!bool {
        const program = self.program;
        std.debug.assert(slots.len == program.slotCount());
        std.debug.assert(start <= text.count());
        const count = text.count();
        const slot_count = program.slotCount();
        var current = &self.current;
        var next = &self.next;
        current.len = 0;
        const working = self.working;
        defer _ = self.scratch_state.reset(.retain_capacity);
        const scratch = self.scratch_state.allocator();

        var machine: Machine = .{ .program = program, .slot_count = slot_count, .gpa = self.gpa, .count = count, .stack = self.stack };
        defer self.stack = machine.stack;

        var matched = false;
        var position = start;
        // The characters just before, at, and just after the position. Only
        // `here` and `ahead` keep their normalized bytes, so the scratch space can
        // be reset as the search moves on.
        var behind: ?Character = if (start > 0) try describe(scratch, text.grapheme(start - 1)) else null;
        var here: ?Character = if (start < count) try describe(scratch, text.grapheme(start)) else null;
        while (true) {
            const ahead: ?Character = if (position + 1 < count) try describe(scratch, text.grapheme(position + 1)) else null;
            machine.before = behind;
            machine.current = here;
            // A new attempt starts here, behind every thread already running, so
            // an earlier start always wins.
            if (!matched and (mode == .search or position == start)) {
                @memset(working, unset);
                try machine.add(current, 0, position, working);
            }
            if (current.len == 0 and (matched or mode == .whole or position >= count)) break;

            next.len = 0;
            // Threads that consume this character continue at the next position,
            // whose assertions look at this character and the one after it.
            machine.before = here;
            machine.current = ahead;
            for (0..current.len) |index| {
                const pc = current.dense[index];
                const thread_slots = current.slots[index * slot_count ..][0..slot_count];
                const consumes = switch (program.instructions[pc]) {
                    .match => {
                        if (mode == .whole and position != count) continue;
                        @memcpy(slots, thread_slots);
                        matched = true;
                        // Every thread after this one has lower priority.
                        break;
                    },
                    .literal => |literal| here != null and literalMatches(literal, here.?, program.options.ignore_case),
                    .any => here != null and !here.?.line_break,
                    .class => |class| here != null and class.matches(here.?.first, program.options.ignore_case),
                    else => false,
                };
                if (consumes) {
                    @memcpy(working, thread_slots);
                    try machine.add(next, pc + 1, position + 1, working);
                }
            }
            if (position >= count) break;
            std.mem.swap(*Threads, &current, &next);
            behind = here;
            here = ahead;
            position += 1;
            if (position % 256 == 0) {
                // `behind` needs only its flags; `here` is described afresh.
                _ = self.scratch_state.reset(.retain_capacity);
                if (here != null) here = try describe(scratch, text.grapheme(position));
            }
        }
        return matched;
    }
};

// Tests.

const testing = std.testing;

/// The first match's groups as text, `null` for a group that took no part, or
/// null for no match at all.
fn findGroups(pattern: []const u8, options: Options, subject: []const u8) !?[]const ?[]const u8 {
    var problem: Problem = .{};
    var program = compile(testing.allocator, pattern, options, &problem) catch |err| {
        std.debug.print("pattern {s} refused: {s}\n", .{ pattern, problem.message() });
        return err;
    };
    defer program.deinit();
    const text = try Text.init(testing.allocator, subject);
    defer text.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(usize, program.slotCount());
    defer testing.allocator.free(slots);
    if (!try run(&program, testing.allocator, text, 0, .search, slots)) return null;
    const groups = try testing.allocator.alloc(?[]const u8, program.group_count + 1);
    for (groups, 0..) |*group, number| {
        const begin = slots[2 * number];
        const end = slots[2 * number + 1];
        group.* = if (begin == unset or end == unset) null else text.slice(begin, end);
    }
    return groups;
}

fn expectFind(pattern: []const u8, subject: []const u8, expected: ?[]const ?[]const u8) !void {
    return expectFindWith(pattern, .{}, subject, expected);
}

fn expectFindWith(pattern: []const u8, options: Options, subject: []const u8, expected: ?[]const ?[]const u8) !void {
    const found = try findGroups(pattern, options, subject);
    defer if (found) |groups| testing.allocator.free(groups);
    if (expected == null) {
        if (found != null) std.debug.print("{s} on {s}: expected no match, found \"{?s}\"\n", .{ pattern, subject, found.?[0] });
        return testing.expect(found == null);
    }
    if (found == null) std.debug.print("{s} on {s}: expected a match\n", .{ pattern, subject });
    try testing.expect(found != null);
    try testing.expectEqual(expected.?.len, found.?.len);
    for (expected.?, found.?) |want, got| {
        if (want == null) {
            try testing.expect(got == null);
        } else {
            try testing.expectEqualStrings(want.?, got.?);
        }
    }
}

fn expectWhole(pattern: []const u8, subject: []const u8, expected: bool) !void {
    var problem: Problem = .{};
    var program = try compile(testing.allocator, pattern, .{}, &problem);
    defer program.deinit();
    const text = try Text.init(testing.allocator, subject);
    defer text.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(usize, program.slotCount());
    defer testing.allocator.free(slots);
    try testing.expectEqual(expected, try run(&program, testing.allocator, text, 0, .whole, slots));
}

fn expectRefused(pattern: []const u8, position: usize, fragment: []const u8) !void {
    var problem: Problem = .{};
    const result = compile(testing.allocator, pattern, .{}, &problem);
    if (result) |program| {
        var owned = program;
        owned.deinit();
        std.debug.print("{s}: expected a refusal\n", .{pattern});
        return error.TestUnexpectedResult;
    } else |err| try testing.expectEqual(error.InvalidPattern, err);
    if (std.mem.indexOf(u8, problem.message(), fragment) == null or problem.position != position) {
        std.debug.print("{s}: got \"{s}\" at {d}\n", .{ pattern, problem.message(), problem.position });
        return error.TestUnexpectedResult;
    }
}

test "literals, sets, and shorthands" {
    try expectFind("cat", "concatenate", &.{"cat"});
    try expectFind("dog", "concatenate", null);
    try expectFind("\\d+", "Room 101, floor 3", &.{"101"});
    try expectFind("[a-c]+", "xxabcabd", &.{"abcab"});
    try expectFind("[^a-z ]+", "hello World", &.{"W"});
    try expectFind("\\w+", "  café_2 ok", &.{"café_2"});
    try expectFind("\\s+", "a \t b", &.{" \t "});
    try expectFind("\\S+", "  word  ", &.{"word"});
    try expectFind("[\\d.]+", "v1.25!", &.{"1.25"});
    try expectFind("a.c", "abc", &.{"abc"});
    try expectFind("\\.", "a.b", &.{"."});
    try expectFind("\\u{1F600}", "smile 😀", &.{"😀"});
    // \d is ASCII only, so a matched number always converts with to_int.
    try expectFind("\\d", "٣", null);
    try expectFind("\\w", "٣", &.{"٣"});
}

test "alternation and repetition prefer the first and the most" {
    try expectFind("a|ab", "ab", &.{"a"});
    try expectFind("ab|a", "ab", &.{"ab"});
    try expectFind("a*", "aaab", &.{"aaa"});
    try expectFind("a*?", "aaab", &.{""});
    try expectFind("a+?", "aaab", &.{"a"});
    try expectFind("a{2}", "aaaa", &.{"aa"});
    try expectFind("a{2,}", "aaaa", &.{"aaaa"});
    try expectFind("a{1,3}", "aaaa", &.{"aaa"});
    try expectFind("a{1,3}?", "aaaa", &.{"a"});
    try expectFind("(?:ab)+", "abababx", &.{"ababab"});
    try expectFind("colou?r", "the color", &.{"color"});
    try expectFind("x*", "abc", &.{""});
    // The leftmost match wins even when a later one is longer.
    try expectFind("b+|a", "abbb", &.{"a"});
}

test "anchors and word boundaries" {
    try expectFind("^abc", "abcabc", &.{"abc"});
    try expectFind("^bc", "abc", null);
    try expectFind("c$", "abc", &.{"c"});
    try expectFind("b$", "ab\n", null);
    try expectFindWith("^b", .{ .multiline = true }, "a\nb", &.{"b"});
    try expectFindWith("a$", .{ .multiline = true }, "a\r\nb", &.{"a"});
    try expectFind("\\bcat\\b", "concat cat", &.{"cat"});
    try expectFind("\\Bcat", "concat cat", &.{"cat"});
    try expectWhole("\\d+", "123", true);
    try expectWhole("\\d+", "123a", false);
    try expectWhole("a|ab", "ab", true);
}

test "groups capture the last time round" {
    try expectFind("(\\d+)-(\\d+)", "call 555-1234", &.{ "555-1234", "555", "1234" });
    try expectFind("(a)|(b)", "b", &.{ "b", null, "b" });
    try expectFind("(?:(a)|b)+", "ab", &.{ "ab", "a" });
    try expectFind("(a|b)*", "abba", &.{ "abba", "a" });
    try expectFind("((a)(b))", "ab", &.{ "ab", "ab", "a", "b" });
    try expectFind("(?<year>\\d{4})-(?<month>\\d{2})", "on 2026-09", &.{ "2026-09", "2026", "09" });
    try expectFind("(x)?y", "y", &.{ "y", null });
}

test "a character is a grapheme" {
    // é written as one code point or as e and a combining accent is one
    // character either way, and matches the same.
    try expectFind("é", "caf\u{65}\u{301}", &.{"e\u{301}"});
    try expectFind("e\u{301}", "café", &.{"é"});
    try expectFind("e", "caf\u{65}\u{301}", null);
    try expectFind("caf.", "caf\u{65}\u{301}!", &.{"caf\u{65}\u{301}"});
    try expectFind("[é]", "e\u{301}", &.{"e\u{301}"});
    try expectFind("[a-z]", "e\u{301}", null);
    // A family emoji is one character, and \r\n is one line break.
    try expectFind("^.$", "👨‍👩‍👧", &.{"👨‍👩‍👧"});
    try expectFind("a.b", "a\r\nb", null);
    try expectFind("a\\r\\nb", "a\r\nb", &.{"a\r\nb"});
}

test "ignoring case" {
    const ignore: Options = .{ .ignore_case = true };
    try expectFindWith("hello", ignore, "Say HeLLo", &.{"HeLLo"});
    try expectFindWith("[a-z]+", ignore, "ABC1", &.{"ABC"});
    try expectFindWith("[A-Z]+", ignore, "abc1", &.{"abc"});
    try expectFindWith("[^a-z]", ignore, "aBc1", &.{"1"});
    try expectFindWith("éclair", ignore, "ÉCLAIR", &.{"ÉCLAIR"});
    try expectFindWith("σ", ignore, "ΣΑΣ", &.{"Σ"});
    try expectFindWith("k", ignore, "\u{212A}", &.{"\u{212A}"});
    try expectFind("hello", "HELLO", null);
}

test "matching takes time in proportion to the text" {
    // A backtracking engine takes exponential time here; this finishes at once.
    const subject = try testing.allocator.alloc(u8, 20_000);
    defer testing.allocator.free(subject);
    @memset(subject, 'a');
    subject[subject.len - 1] = 'b';
    var problem: Problem = .{};
    for ([_][]const u8{ "(a+)+$", "(a|a)*c", "(a*)*c$", "(?:a?){30}a{30}c" }) |pattern| {
        var program = try compile(testing.allocator, pattern, .{}, &problem);
        defer program.deinit();
        const text = try Text.init(testing.allocator, subject);
        defer text.deinit(testing.allocator);
        const slots = try testing.allocator.alloc(usize, program.slotCount());
        defer testing.allocator.free(slots);
        try testing.expect(!try run(&program, testing.allocator, text, 0, .whole, slots));
    }
}

test "searching from a later position" {
    var problem: Problem = .{};
    var program = try compile(testing.allocator, "\\bx", .{}, &problem);
    defer program.deinit();
    const text = try Text.init(testing.allocator, "ax x");
    defer text.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(usize, program.slotCount());
    defer testing.allocator.free(slots);
    // Starting at the first x, which a word character precedes, the boundary
    // is not there, so the match is the second x.
    try testing.expect(try run(&program, testing.allocator, text, 1, .search, slots));
    try testing.expectEqual(@as(usize, 3), slots[0]);
    try testing.expect(!try run(&program, testing.allocator, text, 4, .search, slots));
}

test "a matcher runs again from where the last match ended" {
    var problem: Problem = .{};
    var program = try compile(testing.allocator, "(\\w)\\w*", .{}, &problem);
    defer program.deinit();
    // Long enough that one run resets its scratch space along the way.
    const subject = "é" ++ "a" ** 300 ++ " be\u{301}e, x";
    const text = try Text.init(testing.allocator, subject);
    defer text.deinit(testing.allocator);
    const slots = try testing.allocator.alloc(usize, program.slotCount());
    defer testing.allocator.free(slots);
    var matcher = try Matcher.init(testing.allocator, &program);
    defer matcher.deinit();
    const expected = [_][4]usize{ .{ 0, 301, 0, 1 }, .{ 302, 305, 302, 303 }, .{ 307, 308, 307, 308 } };
    var position: usize = 0;
    for (expected) |want| {
        try testing.expect(try matcher.run(text, position, .search, slots));
        try testing.expectEqualSlices(usize, &want, slots);
        position = slots[1];
    }
    try testing.expect(!try matcher.run(text, position, .search, slots));
    try testing.expect(try matcher.run(text, 302, .whole, slots) == false);
}

test "names find their groups" {
    var problem: Problem = .{};
    var program = try compile(testing.allocator, "(a)(?<middle>b)(?:c)(d)", .{}, &problem);
    defer program.deinit();
    try testing.expectEqual(@as(u32, 3), program.group_count);
    try testing.expectEqual(@as(?u32, 2), program.groupNumber("middle"));
    try testing.expectEqual(@as(?u32, null), program.groupNumber("other"));
}

test "refused patterns say what and where" {
    try expectRefused("(\\d+", 0, "no matching \")\"");
    try expectRefused("ab)", 2, "no \"(\" to close");
    try expectRefused("*a", 0, "nothing before it to repeat");
    try expectRefused("a**", 2, "repeats a repetition");
    try expectRefused("a*+", 2, "possessive");
    try expectRefused("[abc", 0, "no matching \"]\"");
    try expectRefused("[z-a]", 1, "runs backwards");
    try expectRefused("[]", 0, "empty set");
    try expectRefused("[[:alpha:]]", 1, "needs a backslash");
    try expectRefused("a\\q", 1, "not an escape");
    try expectRefused("ab\\", 2, "single backslash");
    try expectRefused("(a)\\1", 3, "refers back");
    try expectRefused("a(?=b)", 1, "lookahead");
    try expectRefused("(?<!a)b", 0, "lookbehind");
    try expectRefused("(?>a)", 0, "atomic");
    try expectRefused("(?i)a", 0, "ignore_case: true");
    try expectRefused("(?P<n>a)", 0, "Python");
    try expectRefused("\\Aa", 0, "use ^ and $");
    try expectRefused("\\p{L}", 0, "not supported yet");
    try expectRefused("a{2", 1, "does not start a repetition");
    try expectRefused("a{5,2}", 1, "at most fewer than at least");
    try expectRefused("a{1001}", 1, "too large");
    try expectRefused("(?<n>a)(?<n>b)", 10, "already used");
    try expectRefused("\\u{110000}", 0, "hex digits");
    try expectRefused("^*", 1, "repeats an anchor");
    // Positions count characters, not bytes.
    try expectRefused("é(", 1, "no matching \")\"");
    try expectRefused("(?:a{1000}){1000}", 0, "too large");
}
