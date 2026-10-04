//! Execute the real checker on signatures from the catalog. In particular,
//! comparing inferred results (not assignability) catches widening and optional
//! mismatches that a well-typed assignment alone would hide.
const std = @import("std");
const emerald = @import("emerald.zig");
const Builtins = emerald.Builtins;
const value_owners = [_][]const u8{
    "String", "List", "Dict",      "Set",     "Int",    "Float",       "Bool",       "Range",     "Bytes",
    "Tuple",  "Task", "TaskGroup", "Channel", "Random", "ProbeStruct", "ProbeClass", "ProbeEnum",
};
const helpers = "func maybe_int(): Int? { return 2 }\nfunc maybe_string(): String? { return \"text\" }\n" ++
    "struct ProbeStruct { const value: Int }\nclass ProbeClass { const value: Int }\nenum ProbeEnum { red, green }\n";

const Probe = struct {
    start: u32,
    end: u32,
    label: []const u8,
    result: []const u8,
    block_start: ?u32 = null,
    block_types: []const []const u8 = &.{},
    rejected: bool = false,
};

const Builder = struct {
    arena: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    probes: std.ArrayList(Probe) = .empty,

    fn add(self: *Builder, text: []const u8) !void {
        try self.text.appendSlice(self.arena, text);
    }

    fn print(self: *Builder, comptime format: []const u8, args: anytype) !void {
        try self.add(try std.fmt.allocPrint(self.arena, format, args));
    }
};

/// Distinct substitutions exercise transformations rather than accidentally
/// accepting, for example, a map that returns the input element type.
fn concrete(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const start = index;
        if (std.ascii.isAlphabetic(text[index])) {
            while (index < text.len and std.ascii.isAlphanumeric(text[index])) : (index += 1) {}
            const word = text[start..index];
            const replacement = if (std.mem.eql(u8, word, "T")) "Int" else if (std.mem.eql(u8, word, "U") or std.mem.eql(u8, word, "K")) "String" else if (std.mem.eql(u8, word, "V")) "Float" else if (std.mem.eql(u8, word, "A")) "String" else if (std.mem.eql(u8, word, "K2")) "Int" else if (std.mem.eql(u8, word, "V2")) "Bool" else word;
            try result.appendSlice(arena, replacement);
        } else {
            try result.append(arena, text[index]);
            index += 1;
        }
    }
    return result.items;
}

fn value(text: []const u8) ![]const u8 {
    const fixtures = std.StaticStringMap([]const u8).initComptime(.{
        .{ "Int", "2" },                        .{ "Float", "2.5" },                     .{ "Bool", "true" },
        .{ "String", "\"text\"" },              .{ "Any", "2" },                         .{ "Int?", "maybe_int()" },
        .{ "String?", "maybe_string()" },       .{ "Range", "1..3" },                    .{ "List[Int]", "[1, 2]" },
        .{ "List[String]", "[\"a\", \"b\"]" },  .{ "Set[Int]", "[1, 2].to_set()" },      .{ "Dict[String, Float]", "[\"a\": 2.5]" },
        .{ "(String, Float)", "(\"a\", 2.5)" }, .{ "Duration", "Duration(seconds: 1)" },
    });
    return fixtures.get(text) orelse {
        std.debug.print("no checker probe fixture for `{s}`\n", .{text});
        return error.MissingFixture;
    };
}

fn receiver(member: Builtins.Member) []const u8 {
    const owner = member.owner orelse return "";
    if (member.kind == .type_method or member.kind == .type_property) return owner;
    const fixtures = std.StaticStringMap([]const u8).initComptime(.{
        .{ "String", "text" },       .{ "List", "items" },        .{ "Dict", "entries" },
        .{ "Set", "values" },        .{ "Int", "number" },        .{ "Float", "decimal" },
        .{ "Bool", "flag" },         .{ "Range", "span" },        .{ "Bytes", "bytes" },
        .{ "Random", "randomizer" }, .{ "Task", "task" },         .{ "TaskGroup", "tasks" },
        .{ "Channel", "channel" },   .{ "Tuple", "pair" },        .{ "ProbeStruct", "point" },
        .{ "Optional", "maybe" },    .{ "ProbeClass", "object" }, .{ "ProbeEnum", "shade" },
    });
    return fixtures.get(owner) orelse owner;
}

fn appendBlock(builder: *Builder, written: []const u8, task_result: bool) !void {
    const arrow = std.mem.indexOf(u8, written, "=>") orelse return error.InvalidBlock;
    const parameters = written[0..arrow];
    try builder.add(" { ");
    // Copy names and tuple destructuring, but leave types to contextual
    // checking. We separately compare the inferred lambda's signature below.
    var index: usize = 0;
    while (index < parameters.len) {
        if (parameters[index] == ':') {
            index += 1;
            while (index < parameters.len and parameters[index] != ',' and parameters[index] != ')') : (index += 1) {}
        } else {
            try builder.text.append(builder.arena, parameters[index]);
            index += 1;
        }
    }
    try builder.add("=> ");
    const result = std.mem.trim(u8, written[arrow + 2 ..], " ");
    if (std.mem.eql(u8, result, "...")) {
        try builder.add(if (task_result) "2" else "print(1)");
    } else {
        try builder.add(try value(try concrete(builder.arena, result)));
    }
    try builder.add(" }");
}

fn blockTypes(arena: std.mem.Allocator, written: []const u8) ![]const []const u8 {
    const arrow = std.mem.indexOf(u8, written, "=>").?;
    var types: std.ArrayList([]const u8) = .empty;
    var parameters = std.mem.trim(u8, written[0..arrow], " ");
    if (std.mem.startsWith(u8, parameters, "(")) {
        const close = std.mem.indexOfScalar(u8, parameters, ')').?;
        const tuple = parameters[1..close];
        var parts = std.mem.splitScalar(u8, tuple, ',');
        var tuple_types: std.ArrayList(u8) = .empty;
        try tuple_types.append(arena, '(');
        while (parts.next()) |part| {
            const colon = std.mem.indexOfScalar(u8, part, ':').?;
            if (tuple_types.items.len > 1) try tuple_types.appendSlice(arena, ", ");
            try tuple_types.appendSlice(arena, try concrete(arena, std.mem.trim(u8, part[colon + 1 ..], " ")));
        }
        try tuple_types.append(arena, ')');
        try types.append(arena, tuple_types.items);
        parameters = std.mem.trimStart(u8, parameters[close + 1 ..], ", ");
    }
    var parts = std.mem.splitScalar(u8, parameters, ',');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, part, ':').?;
        try types.append(arena, try concrete(arena, std.mem.trim(u8, part[colon + 1 ..], " ")));
    }
    return types.items;
}

fn appendProbe(builder: *Builder, member: Builtins.Member, signature: Builtins.Signature, count: usize, rejected: bool) !void {
    const number = builder.probes.items.len;
    try builder.print("func probe_{d}() {{\n", .{number});
    try builder.add(
        "var items = [1, 2, 3]\n" ++
            "var entries: Dict[String, Float] = [\"a\": 2.5]\n" ++
            "var values: Set[Int] = [1, 2].to_set()\n" ++
            "var text = \"abc\"\nvar number = 2\nvar decimal = 2.5\n" ++
            "var flag = true\nvar span = 1..3\nvar bytes = text.to_bytes()\n" ++
            "var randomizer = Random(1)\nvar channel: Channel[Int] = Channel()\n",
    );
    try builder.add("const maybe: Int? = maybe_int()\n");
    try builder.add("const pair = (1, \"a\")\nconst point = ProbeStruct(1)\nconst object = ProbeClass(1)\nconst shade = ProbeEnum.red\n");
    // to_dictionary is defined only for a list of pairs.
    if (std.mem.eql(u8, member.name, "to_dictionary")) try builder.add("var pairs = [(\"a\", 2.5)]\n");
    const in_group = Builtins.sameOwner(member.owner, "Task") or Builtins.sameOwner(member.owner, "TaskGroup");
    if (in_group) try builder.add("Tasks.run { tasks =>\nvar task = tasks.start { => 2 }\n");
    const statement = member.kind == .statement;
    var block_start: ?u32 = null;
    if (!statement) try builder.add("print(");
    const start: u32 = @intCast(builder.text.items.len);
    if (member.owner != null) {
        try builder.add(if (std.mem.eql(u8, member.name, "to_dictionary")) "pairs" else receiver(member));
        try builder.add(".");
    }
    try builder.add(member.name);
    if ((member.kind != .property and member.kind != .type_property) or rejected) {
        try builder.add(if (statement) " " else "(");
        for (0..count) |index| {
            const parameter: Builtins.Parameter = if (signature.parameters.len == 0) .{ .name = "extra", .type = "Int" } else signature.parameters[@min(index, signature.parameters.len - 1)];
            if (index != 0) try builder.add(", ");
            try builder.add(if (Builtins.sameOwner(member.owner, "Random") and std.mem.eql(u8, member.name, "shuffle!")) "items" else try value(try concrete(builder.arena, parameter.type)));
        }
        if (!statement) try builder.add(")");
        if (signature.block) |block| {
            block_start = @intCast(builder.text.items.len + 1);
            try appendBlock(builder, block, Builtins.sameOwner(member.owner, "TaskGroup"));
        }
    }
    const end: u32 = @intCast(builder.text.items.len);
    if (!statement) try builder.add(")");
    try builder.add("\n");
    if (in_group) try builder.add("}\n");
    try builder.add("}\n");
    try builder.probes.append(builder.arena, .{
        .start = start,
        .end = end,
        .label = try std.fmt.allocPrint(builder.arena, "{s}.{s} ({d} arguments{s})", .{ member.owner orelse "prelude", member.name, count, if (signature.block != null) ", block" else "" }),
        .result = try concrete(builder.arena, signature.result),
        .block_start = block_start,
        .block_types = if (signature.block) |block| try blockTypes(builder.arena, block) else &.{},
        .rejected = rejected,
    });
}

pub fn checkResults() !void {
    const gpa = std.testing.allocator;
    const catalog = try Builtins.load(gpa);
    defer catalog.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var builder: Builder = .{ .arena = arena_state.allocator() };
    try builder.add(helpers);
    for (catalog.value.members) |member| {
        if (isSpecialTypedCall(member)) continue;
        if (Builtins.sameOwner(member.owner, "*")) {
            for (value_owners) |owner| {
                var specialized = member;
                specialized.owner = owner;
                try appendProbe(&builder, specialized, member.signatures[0], 0, false);
            }
            continue;
        }
        for (member.signatures) |signature| {
            var minimum = signature.parameters.len;
            while (minimum > 0) {
                const last = signature.parameters[minimum - 1];
                if (last.default == null and !last.optional and !last.variadic) break;
                minimum -= 1;
            }
            for (minimum..signature.parameters.len + 1) |count| try appendProbe(&builder, member, signature, count, false);
            if (signature.parameters.len > 0 and signature.parameters[signature.parameters.len - 1].variadic) try appendProbe(&builder, member, signature, 3, false);
        }
    }
    var source = try emerald.Source.init(gpa, "builtin-parity.em", builder.text.items);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
    var analysis = (try emerald.analyzeProject(gpa, &project)) orelse {
        var report = try emerald.check(gpa, &source);
        defer report.deinit();
        for (report.diagnostics) |diagnostic| std.debug.print("{d}: {s}\n", .{ diagnostic.span.start, diagnostic.message });
        return error.ProbeDoesNotParse;
    };
    defer analysis.deinit(gpa);
    var mismatches: usize = 0;
    for (analysis.checked.diagnostics) |diagnostic| {
        if (diagnostic.severity != .err) continue;
        std.debug.print("checker probe at {d}: {s}\n", .{ diagnostic.span.start, diagnostic.message });
        mismatches += 1;
    }
    for (builder.probes.items) |probe| {
        // assert is a statement, not an expression, and gives no value.
        if (std.mem.startsWith(u8, probe.label, "prelude.assert")) continue;
        var found = false;
        var iterator = analysis.checked.expression_types.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.file != 0) continue;
            const expression = entry.key_ptr.*;
            if (expression.span.start != probe.start or expression.span.end != probe.end) continue;
            found = true;
            const actual = try std.fmt.allocPrint(builder.arena, "{f}", .{entry.value_ptr.type});
            if (!std.mem.eql(u8, probe.result, actual)) {
                std.debug.print("{s}: data result `{s}`, checker result `{s}`\n", .{ probe.label, probe.result, actual });
                mismatches += 1;
            }
            if (probe.block_start != null) {
                const block = expression.data.call.arguments[expression.data.call.arguments.len - 1];
                const block_type = analysis.checked.literal_types.get(block).?;
                const parameters = block_type.signature.?.parameters;
                if (parameters.len != probe.block_types.len) {
                    std.debug.print("{s}: data block has {d} parameters, checker has {d}\n", .{ probe.label, probe.block_types.len, parameters.len });
                    mismatches += 1;
                } else for (parameters, probe.block_types) |parameter, wanted| {
                    const shown = try std.fmt.allocPrint(builder.arena, "{f}", .{parameter});
                    if (!std.mem.eql(u8, wanted, shown)) {
                        std.debug.print("{s}: data block parameter `{s}`, checker parameter `{s}`\n", .{ probe.label, wanted, shown });
                        mismatches += 1;
                    }
                }
            }
            break;
        }
        if (!found) {
            std.debug.print("{s}: checker lacks a result for the data signature\n", .{probe.label});
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

const Names = struct {
    owner: ?[]const u8,
    kind: Builtins.Kind,
    names: []const []const u8,
};

pub fn checkNames() !void {
    const Checker = emerald.Checker;
    const Type = emerald.Type;
    const catalog = try Builtins.load(std.testing.allocator);
    defer catalog.deinit();
    // Tables are authoritative where they exist; branch lists live beside
    // their checker branches, not here or in the language server.
    const inventories = [_]Names{
        .{ .owner = "Optional", .kind = .method, .names = &Checker.optional_methods },
        .{ .owner = "Json", .kind = .type_method, .names = &Checker.typed_json_methods },
        .{ .owner = "Csv", .kind = .type_method, .names = &Checker.typed_csv_methods },
        .{ .owner = "Console", .kind = .type_method, .names = &Checker.typed_console_methods },
        .{ .owner = "*", .kind = .property, .names = &.{"type_name"} },
        .{ .owner = "String", .kind = .method, .names = Type.string_methods.keys() },
        .{ .owner = "String", .kind = .method, .names = &Checker.string_branch_methods },
        .{ .owner = "String", .kind = .property, .names = &.{"count"} },
        .{ .owner = "List", .kind = .method, .names = Type.list_methods.keys() },
        .{ .owner = "List", .kind = .method, .names = &Checker.list_branch_methods },
        .{ .owner = "List", .kind = .property, .names = &Checker.list_properties },
        .{ .owner = "Dict", .kind = .method, .names = &Checker.map_block_methods },
        .{ .owner = "Dict", .kind = .method, .names = &Checker.dictionary_methods },
        .{ .owner = "Dict", .kind = .property, .names = &.{"count"} },
        .{ .owner = "Set", .kind = .method, .names = &Checker.map_block_methods },
        .{ .owner = "Set", .kind = .method, .names = &Checker.set_methods },
        .{ .owner = "Set", .kind = .property, .names = &.{"count"} },
        .{ .owner = "Int", .kind = .method, .names = Type.int_methods.keys() },
        .{ .owner = "Int", .kind = .method, .names = &Checker.int_branch_methods },
        .{ .owner = "Float", .kind = .method, .names = Type.float_methods.keys() },
        .{ .owner = "Float", .kind = .method, .names = &Checker.float_branch_methods },
        .{ .owner = "Float", .kind = .type_property, .names = &.{ "infinity", "nan" } },
        .{ .owner = "Bool", .kind = .method, .names = &.{"to_string"} },
        .{ .owner = "Range", .kind = .method, .names = &Checker.range_methods },
        .{ .owner = "Range", .kind = .property, .names = &.{"count"} },
        .{ .owner = "Bytes", .kind = .method, .names = &Checker.bytes_methods },
        .{ .owner = "Bytes", .kind = .property, .names = &.{"count"} },
        .{ .owner = "Bytes", .kind = .type_method, .names = &.{ "from_list", "from_hex", "from_hex_maybe" } },
        .{ .owner = "Math", .kind = .type_method, .names = Type.math_functions.keys() },
        .{ .owner = "Math", .kind = .type_property, .names = &.{ "pi", "e" } },
        .{ .owner = "Program", .kind = .type_method, .names = &.{"sleep"} },
        .{ .owner = "Program", .kind = .type_property, .names = &.{"arguments"} },
        .{ .owner = "Task", .kind = .method, .names = &Checker.task_methods },
        .{ .owner = "TaskGroup", .kind = .method, .names = &Checker.task_group_methods },
        .{ .owner = "Channel", .kind = .method, .names = &Checker.channel_methods },
        .{ .owner = "Random", .kind = .method, .names = &Checker.random_methods },
        .{ .owner = null, .kind = .function, .names = &emerald.Resolver.prelude },
        .{ .owner = null, .kind = .statement, .names = &.{"assert"} },
    };
    var mismatches: usize = 0;
    for (inventories) |inventory| {
        for (inventory.names) |name| {
            const member = Builtins.find(catalog.value, inventory.owner, name) orelse {
                std.debug.print("{s}.{s}: checker accepts the member, data lacks it\n", .{ inventory.owner orelse "prelude", name });
                mismatches += 1;
                continue;
            };
            if (member.kind != inventory.kind) {
                std.debug.print("{s}.{s}: data kind `{s}`, checker kind `{s}`\n", .{ inventory.owner orelse "prelude", name, @tagName(member.kind), @tagName(inventory.kind) });
                mismatches += 1;
            }
        }
    }
    for (catalog.value.members) |member| {
        var found = false;
        for (inventories) |inventory| {
            if (!Builtins.sameOwner(member.owner, inventory.owner)) continue;
            for (inventory.names) |name| {
                if (std.mem.eql(u8, member.name, name)) found = true;
            }
        }
        if (!found) {
            std.debug.print("{s}.{s}: data describes the member, checker lacks it\n", .{ member.owner orelse "prelude", member.name });
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

pub fn checkArity() !void {
    const gpa = std.testing.allocator;
    const catalog = try Builtins.load(gpa);
    defer catalog.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var builder: Builder = .{ .arena = arena_state.allocator() };
    try builder.add(helpers);
    for (catalog.value.members) |member| {
        if (isSpecialTypedCall(member)) continue;
        if (member.kind == .property or member.kind == .type_property or member.kind == .statement) continue;
        for (member.signatures, 0..) |signature, index| {
            var already_tested = false;
            for (member.signatures[0..index]) |earlier| {
                if ((earlier.block != null) == (signature.block != null)) already_tested = true;
            }
            if (already_tested) continue;
            var minimum: usize = std.math.maxInt(usize);
            var maximum: usize = 0;
            var widest = signature;
            var variadic = false;
            for (member.signatures) |candidate| {
                if ((candidate.block != null) != (signature.block != null)) continue;
                var least = candidate.parameters.len;
                while (least > 0) {
                    const last = candidate.parameters[least - 1];
                    if (last.default == null and !last.optional and !last.variadic) break;
                    least -= 1;
                }
                minimum = @min(minimum, least);
                if (candidate.parameters.len >= maximum) {
                    maximum = candidate.parameters.len;
                    widest = candidate;
                }
                for (candidate.parameters) |parameter| variadic = variadic or parameter.variadic;
            }
            if (minimum > 0) try appendProbe(&builder, member, widest, minimum - 1, true);
            if (!variadic) try appendProbe(&builder, member, widest, maximum + 1, true);
            if (signature.block != null) {
                var has_blockless = false;
                for (member.signatures) |candidate| has_blockless = has_blockless or candidate.block == null;
                if (!has_blockless) {
                    var missing = signature;
                    missing.block = null;
                    try appendProbe(&builder, member, missing, signature.parameters.len, true);
                }
            }
        }
    }
    var source = try emerald.Source.init(gpa, "builtin-arity.em", builder.text.items);
    defer source.deinit(gpa);
    var files = [_]emerald.Project.File{.{ .source = source, .namespace = "", .entry = true }};
    const project: emerald.Project = .{ .files = &files, .entry = 0, .bad_directories = &.{} };
    var analysis = (try emerald.analyzeProject(gpa, &project)).?;
    defer analysis.deinit(gpa);
    var mismatches: usize = 0;
    for (builder.probes.items) |probe| {
        var rejected = false;
        for (analysis.checked.diagnostics) |diagnostic| {
            if (diagnostic.severity != .err) continue;
            if (diagnostic.span.start >= probe.start and diagnostic.span.start <= probe.end) rejected = true;
        }
        if (!rejected) {
            std.debug.print("{s}: checker accepts arguments outside the data's arity/block shape\n", .{probe.label});
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

/// The editor checks unfinished calls continually. Check *every* catalog
/// member at both boundaries, even when zero arguments is legal. Legal
/// defaults/zero-arity/variadic calls must remain legal, not be forced to fail.
pub fn checkCallBoundaries() !void {
    const gpa = std.testing.allocator;
    const catalog = try Builtins.load(gpa);
    defer catalog.deinit();
    var mismatches: usize = 0;
    for (catalog.value.members) |member| {
        if (isSpecialTypedCall(member)) continue;
        if (Builtins.sameOwner(member.owner, "*")) {
            for (value_owners) |owner| {
                var specialized = member;
                specialized.owner = owner;
                mismatches += try checkMemberBoundaries(specialized);
            }
        } else mismatches += try checkMemberBoundaries(member);
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

fn isSpecialTypedCall(member: Builtins.Member) bool {
    const owner = member.owner orelse return false;
    return (Builtins.sameOwner(owner, "Json") and (std.mem.eql(u8, member.name, "encode") or std.mem.eql(u8, member.name, "decode"))) or
        (Builtins.sameOwner(owner, "Csv") and (std.mem.eql(u8, member.name, "encode") or std.mem.eql(u8, member.name, "decode"))) or
        (Builtins.sameOwner(owner, "Console") and std.mem.eql(u8, member.name, "table"));
}

fn checkMemberBoundaries(member: Builtins.Member) !usize {
    const gpa = std.testing.allocator;
    var maximum: usize = 0;
    var widest = member.signatures[0];
    var zero_allowed = false;
    var variadic = false;
    for (member.signatures) |signature| {
        if (signature.parameters.len >= maximum) {
            maximum = signature.parameters.len;
            widest = signature;
        }
        var required: usize = 0;
        for (signature.parameters) |parameter| {
            if (!parameter.optional and parameter.default == null and !parameter.variadic) required += 1;
            variadic = variadic or parameter.variadic;
        }
        zero_allowed = zero_allowed or (required == 0 and signature.block == null);
    }
    const property = member.kind == .property or member.kind == .type_property;
    var mismatches: usize = 0;
    for ([_]usize{ 0, maximum + 1 }) |count| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var builder: Builder = .{ .arena = arena_state.allocator() };
        try builder.add(helpers);
        var signature = widest;
        signature.block = null;
        try appendProbe(&builder, member, signature, count, true);
        var source = try emerald.Source.init(gpa, "builtin-boundaries.em", builder.text.items);
        defer source.deinit(gpa);
        var report = try emerald.check(gpa, &source);
        defer report.deinit();
        const expected_error = property or (if (count == 0) !zero_allowed else !variadic);
        const has_error = emerald.Diagnostic.anyErrors(report.diagnostics);
        if (has_error != expected_error) {
            std.debug.print("{s}: {s}, expected {s}\n", .{ builder.probes.items[0].label, if (has_error) "checker rejects the call" else "checker accepts the call", if (expected_error) "a diagnostic" else "a legal call" });
            for (report.diagnostics) |diagnostic| std.debug.print("{s}\n", .{diagnostic.message});
            mismatches += 1;
        }
    }
    return mismatches;
}

pub fn checkUniversalPlacement() !void {
    const gpa = std.testing.allocator;
    const catalog = try Builtins.load(gpa);
    defer catalog.deinit();
    const member = Builtins.find(catalog.value, "*", "type_name").?;
    try std.testing.expectEqual(Builtins.Kind.property, member.kind);
    try std.testing.expectEqualStrings("String", member.signatures[0].result);
    // Positive coverage is in checkResults, including all built-in value
    // owners and a tuple, struct, class, and enum. A callable, nothing, and
    // an optional exercise the universal rule beyond the owner's list too.
    var positive = try emerald.Source.init(gpa, "universal-values.em", "const maybe: Int? = nothing\nprint(nothing.type_name, maybe.type_name, { x: Int => x }.type_name)\n");
    defer positive.deinit(gpa);
    var accepted = try emerald.check(gpa, &positive);
    defer accepted.deinit();
    try std.testing.expect(accepted.ok());
    const type_names = [_][]const u8{ "String", "List", "Dict", "Set", "Int", "Float", "Bool", "Range", "Bytes", "Tuple", "Task", "TaskGroup", "Channel", "Random", "ProbeStruct", "ProbeClass", "ProbeEnum", "Math", "Program", "Emerald" };
    for (type_names) |owner| {
        const text = try std.fmt.allocPrint(gpa, "{s}print({s}.type_name)\n", .{ helpers, owner });
        defer gpa.free(text);
        var source = try emerald.Source.init(gpa, "universal-type.em", text);
        defer source.deinit(gpa);
        var rejected = try emerald.check(gpa, &source);
        defer rejected.deinit();
        if (rejected.ok()) {
            std.debug.print("{s}.type_name: checker accepts a universal property on a type/namespace\n", .{owner});
            return error.UniversalPlacementMismatch;
        }
    }
}
