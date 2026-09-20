//! Name resolution.
//!
//! Section 19.2 puts this between parsing and evaluation, and these problems
//! belong here rather than in the interpreter because they are properties of the
//! text rather than of a particular run. A name declared inside `if false { }`
//! still shadows, and a program that never reaches a bad assignment is still
//! wrong.
//!
//! Section 6.1 supplies the scope rules. Every block is a scope, a local does not
//! leak out of the block that declared it, sibling scopes may reuse a name, and
//! shadowing a visible local within the same function is an error because the
//! writer usually meant assignment. Crossing a function boundary is allowed: a
//! parameter or local may reuse a module-level name.
//!
//! Section 7.1 supplies the visibility rules that functions add. Function
//! declarations are hoisted, so every top-level function is visible from the
//! start of the file. Variables are visible only from their declarations, and a
//! function body is walked where it is written, so it sees exactly the module
//! variables declared above it.
//!
//! Hoisting means a function can be called before a variable it reads has been
//! assigned. Section 7.1 forbids that ("hoisting never permits reading an
//! uninitialized captured variable"), and the checker enforces it at each call
//! site. It needs to know which module variables each function reads and which
//! functions each one calls, which is only knowable with scopes in hand, so this
//! pass records both as `Facts`.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Project = @import("Project.zig");
const Source = @import("Source.zig");
const Type = @import("Type.zig");

const Resolver = @This();

/// A set of names, used for both halves of `Facts`.
pub const NameSet = std.StringHashMapUnmanaged(void);

/// What one file calls a module-level declaration, mapped to the one name the
/// whole program calls it. See `Keys` below for how a key is built.
pub const KeyMap = std.StringHashMapUnmanaged([]const u8);

/// The separator between a file's path and a private declaration's name. It
/// cannot appear in an identifier, so a private key can never collide with a
/// qualified one.
pub const private_separator = "#";

/// The key an instance method is known by: its type's key, then this, then the
/// method's name. `::` cannot appear in a name, a path, or any other key, so a
/// method never collides with a namespace-qualified function.
pub const method_separator = "::";

pub fn methodKey(arena: std.mem.Allocator, type_key: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}" ++ method_separator ++ "{s}", .{ type_key, name });
}

/// A property's getter is known by the method key of its name, so reading
/// `value.area` and calling a method differ only in the call. Its setter adds
/// this, which no name can end in.
pub const setter_suffix = "=";

pub fn setterKey(arena: std.mem.Allocator, type_key: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}" ++ method_separator ++ "{s}" ++ setter_suffix, .{ type_key, name });
}

/// Section 10.4's type-level fields are set up together, once, the first time
/// the type is constructed or one of its type-level members is reached. What
/// their values read is recorded under this key, which is the method key of
/// an empty name and so can be no member's.
pub fn typeSetupKey(arena: std.mem.Allocator, type_key: []const u8) std.mem.Allocator.Error![]const u8 {
    return methodKey(arena, type_key, "");
}

/// A key as a reader would write it: `Vector2::origin` is `Vector2.origin`,
/// and a private declaration drops the file it is private to.
pub fn displayKey(arena: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error![]const u8 {
    const start = if (std.mem.indexOf(u8, key, private_separator)) |at| at + private_separator.len else 0;
    return std.mem.replaceOwned(u8, arena, key[start..], method_separator, ".");
}

/// Where an assignment statement is written, which is how the passes after
/// this one find what the resolver decided about it.
pub const Site = struct { file: u32, start: u32 };

/// Where a declaration is written: its file and its name's span, for go to
/// definition and find references (18.5).
pub const Target = struct { file: u32, span: Source.Span };

/// The key a nested function (7.1) is known by: its name, then where its name
/// is written. `@` appears in no name, so it collides with no other key.
fn nestedKey(arena: std.mem.Allocator, file: u32, function: Ast.FunctionDeclaration) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}@{d}:{d}", .{ function.name, file, function.name_span.start });
}

/// A local variable of an enclosing function that a nested function reads or
/// assigns (7.1).
pub const Capture = struct {
    name: []const u8,
    /// The function whose body declares it, or "" for a block at the top
    /// level of a file.
    owner: []const u8,
    /// Where it is declared, which a use of the function has to come after.
    declared: u32,
    /// Whether the function reads it, so it has to hold a value by then, and
    /// not only exist.
    read: bool,
};

/// Section 14.2's privacy: a leading underscore on a module-level declaration
/// makes it private to its own file. `_` alone is the discard, not a name.
pub fn isPrivate(name: []const u8) bool {
    return name.len > 1 and name[0] == '_';
}

/// What name resolution learned about functions, for the checker.
pub const Facts = struct {
    /// For each function, the module-level variables its own body reads. A
    /// compound assignment reads before it writes, so it counts; a plain
    /// assignment does not, because it needs no earlier value.
    module_reads: std.StringHashMapUnmanaged(NameSet) = .empty,
    /// For each function, the other program functions its own body calls.
    /// Calls to prelude functions are not recorded; they read no program state.
    calls: std.StringHashMapUnmanaged(NameSet) = .empty,
    /// Every name assigned inside a lambda body. Section 4.5 will not narrow
    /// one of these: a block holding the variable could be called between the
    /// test and the use, and set it back to `nothing`.
    assigned_in_lambda: NameSet = .empty,
    /// Every module-level variable, by key, assigned inside a function,
    /// method, constructor, or accessor. Section 4.5 will not narrow one of
    /// these either: any call between the test and the use could be the one
    /// that sets it back to `nothing`.
    assigned_in_function: NameSet = .empty,
    /// Every name a whole assignment gives a new value, anywhere, apart from
    /// its declaration. A block sees one of these at its declared type, since
    /// the block could run after the assignment undid a narrowing (4.5).
    reassigned: NameSet = .empty,
    /// For each file, what a bare module-level name means there: its own
    /// declarations, its namespace's, and whatever its `using` declarations
    /// brought in. Indexed by file.
    module_keys: []const KeyMap = &.{},
    /// Per-file aliases for namespace prefixes, used by type annotations as
    /// well as by member expressions.
    namespace_aliases: []const KeyMap = &.{},
    /// Every member expression that turned out to be a namespace-qualified
    /// reference rather than a property access, and the key it names. The
    /// checker and the interpreter read this rather than folding the chain
    /// again, so `Shapes.area` is decided in exactly one place.
    qualified: std.AutoHashMapUnmanaged(*const Ast.Expression, []const u8) = .empty,
    /// The file each module-level key is declared in, which is the unit section
    /// 14.1 initializes lazily.
    owner: std.StringHashMapUnmanaged(u32) = .empty,
    /// Every type-level function and field (10.4), mapped to its type's key.
    type_members: KeyMap = .empty,
    /// Every assignment whose destination starts at a type-level field, such
    /// as `Player.count += 1`, mapped to that field as written. The statement
    /// names `Player` with `count` as its first step; this says the two are
    /// one binding, which this file's keys find by that written name.
    type_assignments: std.AutoHashMapUnmanaged(Site, []const u8) = .empty,
    /// Every nested function (7.1), by where its name is written, mapped to
    /// its key; and its declaration, by that key.
    nested_keys: std.AutoHashMapUnmanaged(Site, []const u8) = .empty,
    nested_functions: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
    /// For each nested function, the enclosing locals its own body reads or
    /// assigns.
    local_captures: std.StringHashMapUnmanaged(std.ArrayList(Capture)) = .empty,
    /// Every place a nested function is called or used as a value, mapped to
    /// the locals of the function it is used in that the call can read, through
    /// the nested function and whatever it calls. Each is declared above the
    /// use, which the resolver checks; the checker checks each holds a value.
    nested_uses: std.AutoHashMapUnmanaged(*const Ast.Expression, []const []const u8) = .empty,
    /// Every class that extends another (10.7), mapped to its base class's
    /// key. Only a name that reaches a type is recorded; the checker reports
    /// the rest.
    bases: KeyMap = .empty,
    /// Every trait (11.1), and for every type that adopts traits, or trait
    /// that builds on them, their keys.
    traits: NameSet = .empty,
    adopted: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// Every declared module-level symbol (type, function, method, property, field,
    /// type member, enum value, module variable), mapped to where it is declared.
    declarations: std.StringHashMapUnmanaged(Target) = .empty,
    /// Every identifier expression (`Expression.Data.name`), mapped to the
    /// declaration it references.
    expression_targets: std.AutoHashMapUnmanaged(*const Ast.Expression, Target) = .empty,
    /// Every assignment destination name, mapped to the declaration it references.
    assignment_targets: std.AutoHashMapUnmanaged(Site, Target) = .empty,

    /// The key a bare name has in `file`, or null when the name is not a
    /// module-level declaration visible there.
    pub fn keyFor(self: Facts, file: u32, name: []const u8) ?[]const u8 {
        if (file >= self.module_keys.len) return null;
        return self.module_keys[file].get(name);
    }

    pub fn namespaceAliasFor(self: Facts, file: u32, name: []const u8) ?[]const u8 {
        if (file >= self.namespace_aliases.len) return null;
        return self.namespace_aliases[file].get(name);
    }
};

pub const Resolved = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    facts: Facts,

    pub fn ok(self: Resolved) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Resolved) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

/// Section 15.2's prelude. These are callable without qualification and are not
/// declared by any program, so they live in a scope of their own.
pub const prelude = [_][]const u8{ "print", "write", "input", "input_maybe", "random", "exit" };

/// The namespace of the declarations written in `prelude.em`, such as section
/// 11.5's `Ordered`. A directory's namespace always starts with a capital
/// letter, so no project's names can land in it, and no program can write it.
/// Its public names are visible bare in every file, under the file's own.
pub const prelude_namespace = "emerald";

/// Section 15.5's two type-level Float constants. These keys occupy the same
/// resolved-name channel as user type-level fields without pretending the
/// built-in `Float` type is a user declaration with setup state.
pub const float_infinity_key = "Float.infinity";
pub const float_nan_key = "Float.nan";
pub const math_pi_key = "Math.pi";
pub const math_e_key = "Math.e";
/// Section 14.1's `Program.arguments`: the program's own CLI arguments,
/// excluding the Emerald executable and entry-file paths.
pub const program_arguments_key = "Program.arguments";

pub fn mathFunction(key: []const u8) ?Type.MathFunction {
    const prefix = "Math.";
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    return Type.math_functions.get(key[prefix.len..]);
}

/// The key of the prelude declaration `name`.
pub fn preludeKey(comptime name: []const u8) []const u8 {
    return prelude_namespace ++ "." ++ name;
}

fn isPreludeKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, prelude_namespace ++ ".");
}

/// `self_value` is section 10.2's `self` inside a constructor: its fields are
/// set one at a time, but the value itself is never replaced.
/// `later_parameter` is a parameter seen from a default before it, which section
/// 7.3 says cannot read it: it is in scope only so that the name is reported
/// rather than quietly resolving to something outside the function.
pub const BindingKind = enum { variable, parameter, loop_variable, function, type, self_value, later_parameter };

const Binding = struct {
    mutable: bool,
    /// Where the name was declared, so a later diagnostic can point at it.
    span: Source.Span,
    /// Decides the reason a reassignment diagnostic gives: section 4.3 makes a
    /// `const` read-only, section 7.1 makes a parameter read-only, section 6.4
    /// makes a loop variable read-only, and a function is not a variable at all.
    kind: BindingKind = .variable,
    /// A nested function's key (7.1).
    function_key: ?[]const u8 = null,
};

const Scope = std.StringHashMapUnmanaged(Binding);

/// Stated rather than inferred: the walk functions are mutually recursive, and
/// an inferred set would be a dependency loop.
const Error = std.mem.Allocator.Error;

/// The prelude is scope 0 and the module scope is scope 1.
const prelude_scope = 0;
const module_scope = 1;

arena: std.mem.Allocator,
scopes: std.ArrayList(Scope) = .empty,
diagnostics: std.ArrayList(Diagnostic) = .empty,
facts: Facts = .{},
/// The lowest scope index that counts as "the same function" for section 6.1's
/// shadowing rule. At the top level that is the module scope; inside a
/// function body it is the function's own parameter scope, which is what lets
/// a parameter or local reuse a module-level name.
function_boundary: usize = module_scope,
/// The function whose body is being walked, or null at the top level.
current_function: ?[]const u8 = null,
/// The functions whose bodies enclose the statement being walked, outermost
/// first, each with the index of its parameter scope. A local in a scope below
/// the innermost one's belongs to an enclosing function.
function_scopes: std.ArrayList(FunctionScope) = .empty,
/// Every use of a nested function, judged once every body is walked.
nested_uses: std.ArrayList(NestedUse) = .empty,
/// For each block being walked that declares a nested function, the variables
/// it declares directly, so a nested function reading one declared below it
/// can be told exactly that.
block_locals: std.ArrayList(BlockLocals) = .empty,
/// How many lambda bodies enclose the statement being walked.
lambda_depth: u32 = 0,
/// Every module-level variable and where it is declared, so a name used above
/// its declaration can be reported as exactly that rather than as a
/// misspelling. Keyed the way the module scope is.
module_declarations: std.StringHashMapUnmanaged(Declared) = .empty,
/// Every namespace a directory built, and every prefix of one, so a partly
/// written path can be told apart from a mistyped name.
namespaces: NameSet = .empty,
/// For each public bare name, one namespace that declares it, so a name used
/// without qualification can be pointed at where it actually lives.
elsewhere: std.StringHashMapUnmanaged([]const u8) = .empty,
/// Per file, the namespace short names its `using` declarations introduced.
namespace_aliases: []KeyMap = &.{},
/// Per file, the names two `using` declarations both offered, each mapped to
/// one namespace that offers it so the correction can name a real one. Section
/// 14.2 reports these where one is used, not where they are imported, since a
/// name nobody writes is not a conflict anyone has.
ambiguous: []KeyMap = &.{},
/// Every instance method in the program, by its bare name. A call written
/// `value.area()` names no type, so which method it reaches is not known until
/// the checker has types; for section 7.1's capture check it is recorded as a
/// call to every method of that name, which can only over-report.
methods_named: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
/// The method key of every instance field, method, and property, so reaching
/// one through its type instead of a value can say exactly that.
instance_members: NameSet = .empty,
/// The member key of every section 12 enum value.
enum_values: NameSet = .empty,
/// For each enum's key, its values as a reader would list them, for help text.
enum_listings: KeyMap = .empty,
/// While a type-level field's value is walked, the keys of that field and
/// every one after it, which section 10.4's declaration order has not set up
/// yet.
unready_type_fields: NameSet = .empty,
/// The file `emerald run` selected, named by the diagnostics that explain why
/// a statement cannot run where it is written.
entry_path: []const u8 = "",
/// The files, in the order diagnostics index them.
files: []const Project.File = &.{},
/// Set when this one file is running alone but sits inside a project, so a
/// name it cannot find can say where the rest of the program went (14.1).
enclosing_project: ?[]const u8 = null,
/// Which file is being walked. Every diagnostic reported here is stamped with
/// it, and it is what a bare module-level name is resolved through.
file: u32 = 0,

const FunctionScope = struct {
    scope: usize,
    key: []const u8,
    /// What `current_function` was around it, which for a nested function is
    /// the method, constructor, or type code it is written in.
    enclosing: ?[]const u8,
};

const BlockLocals = struct {
    /// The index of the block's scope.
    scope: usize,
    names: []const Ast.Pattern.Name,
};

const NestedUse = struct {
    expression: *const Ast.Expression,
    key: []const u8,
    /// The function the use is written in, or "" at the top level.
    caller: []const u8,
    file: u32,
};

const Declared = struct {
    file: u32,
    /// The name, for pointing at.
    span: Source.Span,
    /// The end of the whole declaration, which is where the name starts to be
    /// visible. `var x = x` reads the right-hand `x` before that point.
    end: u32,
};

pub fn resolve(
    gpa: std.mem.Allocator,
    files: []const Project.File,
    programs: []const Ast.Program,
    enclosing_project: ?[]const u8,
) !Resolved {
    std.debug.assert(files.len == programs.len);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var resolver: Resolver = .{
        .arena = arena,
        .files = files,
        .enclosing_project = enclosing_project,
    };

    // The prelude sits outside the program's own scopes, so a program may
    // declare a name that matches one without it counting as shadowing a local.
    try resolver.push();
    for (prelude) |name| {
        try resolver.scopes.items[prelude_scope].put(arena, name, .{
            .mutable = false,
            .span = .{ .start = 0, .end = 0 },
            .kind = .function,
        });
    }

    try resolver.push();
    try resolver.collectNamespaces();
    try resolver.declareModuleLevel(programs);

    for (files) |file| {
        if (file.entry) resolver.entry_path = file.source.path;
    }

    const key_maps = try arena.alloc(KeyMap, files.len);
    for (key_maps) |*map| map.* = .empty;
    resolver.facts.module_keys = key_maps;
    resolver.namespace_aliases = try arena.alloc(KeyMap, files.len);
    for (resolver.namespace_aliases) |*map| map.* = .empty;
    resolver.facts.namespace_aliases = resolver.namespace_aliases;
    resolver.ambiguous = try arena.alloc(KeyMap, files.len);
    for (resolver.ambiguous) |*set| set.* = .empty;
    for (files, 0..) |_, index| {
        resolver.file = @intCast(index);
        try resolver.buildKeyMap(&key_maps[index]);
    }
    // Every `using` is resolved after every file's own names are in place, so
    // whether an imported name collides does not depend on file order.
    for (programs, 0..) |program, index| {
        resolver.file = @intCast(index);
        try resolver.applyUsing(program.using, &key_maps[index]);
    }

    for (programs, 0..) |program, index| {
        resolver.file = @intCast(index);
        try resolver.recordBases(program.statements);
    }

    for (files, programs, 0..) |file, program, index| {
        resolver.file = @intCast(index);
        if (!file.entry) try resolver.checkModuleFile(program.statements);
        try resolver.walkStatements(program.statements);
    }
    try resolver.judgeNestedUses();

    // Hoisting reports across every file before any file is walked, so the
    // order they were found in is not the order a reader reads them in.
    const owned = try resolver.diagnostics.toOwnedSlice(arena);
    std.mem.sort(Diagnostic, owned, {}, earlierInProgram);
    return .{ .arena_state = arena_state, .diagnostics = owned, .facts = resolver.facts };
}

fn earlierInProgram(_: void, a: Diagnostic, b: Diagnostic) bool {
    if (a.file != b.file) return a.file < b.file;
    return a.span.start < b.span.start;
}

/// The one name the whole program knows a module-level declaration by.
///
/// A public declaration is named by its namespace, which section 14.2 derives
/// from the directory: `area` in `shapes/` is `Shapes.area`, and at the project
/// root it is just `area`. A private one is named by the file it cannot leave,
/// which is why two files may each declare `_helper` without colliding.
fn keyOf(self: *Resolver, file: u32, name: []const u8) Error![]const u8 {
    if (isPrivate(name)) {
        return std.fmt.allocPrint(self.arena, "{s}" ++ private_separator ++ "{s}", .{
            self.files[file].source.path,
            name,
        });
    }
    const namespace = self.files[file].namespace;
    if (namespace.len == 0) return name;
    return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ namespace, name });
}

/// Every namespace, plus every prefix of one, so `Graphics` is known even when
/// only `graphics/ui/` holds any source.
fn collectNamespaces(self: *Resolver) Error!void {
    for (self.files) |file| {
        if (std.mem.eql(u8, file.namespace, prelude_namespace)) continue;
        var at: usize = 0;
        while (at <= file.namespace.len) {
            const boundary = std.mem.indexOfScalarPos(u8, file.namespace, at, '.') orelse file.namespace.len;
            if (boundary != 0) try self.namespaces.put(self.arena, file.namespace[0..boundary], {});
            if (boundary == file.namespace.len) break;
            at = boundary + 1;
        }
    }
}

/// Hoists every module-level declaration of every file into the one module
/// scope, keyed as `keyOf` describes.
fn declareModuleLevel(self: *Resolver, programs: []const Ast.Program) Error!void {
    for (programs, 0..) |program, index| {
        self.file = @intCast(index);
        try self.hoistFunctions(program.statements);
        try self.hoistTypes(program.statements);
    }
    // Module-level variables are hoisted into the scope too, not added as the
    // walk reaches them. Section 14.2 makes same-directory names directly
    // visible, and the files of a directory are walked in some order, so a name
    // that depended on that order would be visible or not by accident.
    // Section 7.1's "variables are visible only from their declarations" is a
    // rule about one file, and `declaredAbove` keeps it by comparing spans.
    const module = &self.scopes.items[module_scope];
    for (programs, 0..) |program, index| {
        self.file = @intCast(index);
        for (program.statements) |statement| {
            switch (statement.data) {
                .declaration => |declaration| {
                    // A `const` with no value is reported below, and treated as
                    // assignable so the one report covers it.
                    const missing_value = !declaration.mutable and declaration.initializer == null;
                    try self.hoistModuleName(
                        module,
                        declaration.name,
                        declaration.name_span,
                        declaration.mutable or missing_value,
                        statement.span.end,
                    );
                },
                // Section 8.2's `var (left, right) = pair` at the top level.
                // Each name it introduces is a module-level name like any other.
                .destructuring => |destructuring| for (destructuring.pattern.names) |name| {
                    if (std.mem.eql(u8, name.text, "_")) continue;
                    try self.hoistModuleName(
                        module,
                        name.text,
                        name.span,
                        destructuring.mutable,
                        statement.span.end,
                    );
                },
                else => {},
            }
        }
    }
}

/// User-defined types are hoisted like functions: their names describe the
/// program rather than an initialization step, and fields may refer to types
/// declared later.
fn hoistTypes(self: *Resolver, statements: []const Ast.Statement) Error!void {
    const module = &self.scopes.items[module_scope];
    for (statements) |statement| {
        const declaration = switch (statement.data) {
            .struct_declaration => |value| value,
            else => continue,
        };
        const key = try self.keyOf(self.file, declaration.name);
        if (module.contains(key)) {
            try self.reportDuplicate(declaration.name, declaration.name_span, key);
            continue;
        }
        try module.put(self.arena, key, .{
            .mutable = false,
            .span = declaration.name_span,
            .kind = .type,
        });
        try self.facts.owner.put(self.arena, key, self.file);
        try self.facts.declarations.put(self.arena, key, .{ .file = self.file, .span = declaration.name_span });
        if (declaration.constructor) |ctor| {
            const ctor_key = try methodKey(self.arena, key, "constructor");
            try self.facts.declarations.put(self.arena, ctor_key, .{ .file = self.file, .span = ctor.keyword_span });
        }
        if (declaration.trait) try self.facts.traits.put(self.arena, key, {});
        // Constructing a value runs its constructor, which may read module
        // variables and call functions like any function body, so a call to
        // the type is recorded exactly as a call to a function is.
        try self.facts.module_reads.put(self.arena, key, .empty);
        try self.facts.calls.put(self.arena, key, .empty);
        try self.noteElsewhere(declaration.name);

        const setup = try typeSetupKey(self.arena, key);
        try self.facts.owner.put(self.arena, setup, self.file);
        try self.facts.module_reads.put(self.arena, setup, .empty);
        try self.facts.calls.put(self.arena, setup, .empty);
        // Constructing a value sets up the type's fields first.
        try self.facts.calls.getPtr(key).?.put(self.arena, setup, {});

        // An enum's values are hoisted before its other members, so a member
        // sharing a value's name is the one reported (12).
        if (declaration.enumeration) {
            var listing: std.ArrayList(u8) = .empty;
            for (declaration.type_fields) |field| {
                if (field.enum_value == null) continue;
                const member_key = try methodKey(self.arena, key, field.name);
                if (module.contains(member_key)) continue;
                try module.put(self.arena, member_key, .{ .mutable = false, .span = field.name_span });
                try self.facts.owner.put(self.arena, member_key, self.file);
                try self.facts.type_members.put(self.arena, member_key, key);
                try self.facts.declarations.put(self.arena, member_key, .{ .file = self.file, .span = field.name_span });
                try self.enum_values.put(self.arena, member_key, {});
                if (listing.items.len > 0) try listing.appendSlice(self.arena, ", ");
                try listing.print(self.arena, "`{s}`", .{field.name});
            }
            try self.enum_listings.put(self.arena, key, listing.items);
        }
        for (declaration.fields) |field| {
            const field_key = try methodKey(self.arena, key, field.name);
            try self.instance_members.put(self.arena, field_key, {});
            try self.facts.declarations.put(self.arena, field_key, .{ .file = self.file, .span = field.name_span });
        }
        for (declaration.methods) |method| {
            const method_key = try methodKey(self.arena, key, method.name);
            try self.instance_members.put(self.arena, method_key, {});
            try self.hoistMember(method.name, method_key);
            try self.facts.declarations.put(self.arena, method_key, .{ .file = self.file, .span = method.name_span });
        }
        // Section 10.4's members live in the module scope under their method
        // keys, so `Vector2.origin` is reached exactly as `Shapes.area` is.
        // A name shared with an instance member is reported by the checker.
        for (declaration.type_functions) |function| {
            const member_key = try methodKey(self.arena, key, function.member);
            if (module.contains(member_key) or self.facts.owner.contains(member_key)) continue;
            try module.put(self.arena, member_key, .{ .mutable = false, .span = function.member_span, .kind = .function });
            try self.facts.owner.put(self.arena, member_key, self.file);
            try self.facts.module_reads.put(self.arena, member_key, .empty);
            try self.facts.calls.put(self.arena, member_key, .empty);
            try self.facts.type_members.put(self.arena, member_key, key);
            try self.facts.declarations.put(self.arena, member_key, .{ .file = self.file, .span = function.member_span });
            // Calling it reaches the type, which sets up its fields first.
            try self.facts.calls.getPtr(member_key).?.put(self.arena, setup, {});
        }
        for (declaration.type_fields) |field| {
            const member_key = try methodKey(self.arena, key, field.name);
            if (module.contains(member_key) or self.facts.owner.contains(member_key)) continue;
            try module.put(self.arena, member_key, .{ .mutable = field.mutable, .span = field.name_span });
            try self.facts.owner.put(self.arena, member_key, self.file);
            try self.facts.type_members.put(self.arena, member_key, key);
            try self.facts.declarations.put(self.arena, member_key, .{ .file = self.file, .span = field.name_span });
        }
        for (declaration.properties) |property| {
            const prop_key = try methodKey(self.arena, key, property.name);
            try self.instance_members.put(self.arena, prop_key, {});
            try self.hoistMember(property.name, prop_key);
            try self.facts.declarations.put(self.arena, prop_key, .{ .file = self.file, .span = property.name_span });
            if (property.setter != null) {
                const setter_name = try std.fmt.allocPrint(self.arena, "{s}" ++ setter_suffix, .{property.name});
                const setter_key = try setterKey(self.arena, key, property.name);
                try self.hoistMember(setter_name, setter_key);
                try self.facts.declarations.put(self.arena, setter_key, .{ .file = self.file, .span = property.name_span });
            }
        }
    }
}

/// Section 10.7: which class each class extends, once every file's names are
/// known. Constructing a subclass runs its base class's constructor, so the
/// call is recorded as one for section 7.1's capture check.
fn recordBases(self: *Resolver, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| {
        const declaration = switch (statement.data) {
            .struct_declaration => |value| value,
            else => continue,
        };
        const type_key = try self.keyOf(self.file, declaration.name);
        if (declaration.traits.len > 0 and !self.facts.adopted.contains(type_key)) {
            var keys: std.ArrayList([]const u8) = .empty;
            for (declaration.traits) |trait| {
                try keys.append(self.arena, try self.typeKeyOf(trait.name) orelse continue);
            }
            try self.facts.adopted.put(self.arena, type_key, keys.items);
        }
        const written = declaration.base orelse continue;
        const key = try self.typeKeyOf(written.name) orelse continue;
        // A repeated type name is reported where it is hoisted.
        if (self.facts.bases.contains(type_key)) continue;
        try self.facts.bases.put(self.arena, type_key, key);
        try self.facts.calls.getPtr(type_key).?.put(self.arena, key, {});
    }
}

/// The key of the type a written type name reaches in the file being walked,
/// following a namespace alias at its front, or null when it reaches none.
fn typeKeyOf(self: *Resolver, written: []const u8) Error!?[]const u8 {
    const module = &self.scopes.items[module_scope];
    const key = self.facts.keyFor(self.file, written) orelse blk: {
        const dot = std.mem.indexOfScalar(u8, written, '.') orelse return null;
        break :blk try std.fmt.allocPrint(self.arena, "{s}{s}", .{ self.namespaceFor(written[0..dot]), written[dot..] });
    };
    const binding = module.get(key) orelse return null;
    return if (binding.kind == .type) key else null;
}

/// Whether `name` is an instance member of the type `type_key` or of any class
/// it extends, and if so the key of the type that declares it.
fn instanceMemberOwner(self: *Resolver, type_key: []const u8, name: []const u8) Error!?[]const u8 {
    return self.memberOwnerWithin(type_key, name, 0);
}

fn memberOwnerWithin(self: *Resolver, type_key: []const u8, name: []const u8, depth: usize) Error!?[]const u8 {
    // A cycle of bases or traits is reported by the checker; stop going round it.
    if (depth > self.facts.bases.count() + self.facts.traits.count()) return null;
    if (self.instance_members.contains(try methodKey(self.arena, type_key, name))) return type_key;
    if (self.facts.adopted.get(type_key)) |traits| {
        for (traits) |trait| {
            if (try self.memberOwnerWithin(trait, name, depth + 1)) |owner| return owner;
        }
    }
    const base = self.facts.bases.get(type_key) orelse return null;
    return self.memberOwnerWithin(base, name, depth + 1);
}

/// A method or property accessor, whose body is walked like a function's.
/// A repeated name is reported by the checker, beside a field of the same
/// name; the first declaration keeps the key.
fn hoistMember(self: *Resolver, name: []const u8, key: []const u8) Error!void {
    if (self.facts.owner.contains(key)) return;
    try self.facts.owner.put(self.arena, key, self.file);
    try self.facts.module_reads.put(self.arena, key, .empty);
    try self.facts.calls.put(self.arena, key, .empty);
    const same_name = try self.methods_named.getOrPut(self.arena, name);
    if (!same_name.found_existing) same_name.value_ptr.* = .empty;
    try same_name.value_ptr.append(self.arena, key);
}

/// Records, for section 7.1's capture check, that the function being walked
/// may run every member named `name`: a method or getter by that name, or with
/// `setter_suffix`, a setter.
fn noteMemberCall(self: *Resolver, name: []const u8) Error!void {
    const caller = self.current_function orelse return;
    const keys = self.methods_named.get(name) orelse return;
    for (keys.items) |key| try self.facts.calls.getPtr(caller).?.put(self.arena, key, {});
}

fn hoistModuleName(
    self: *Resolver,
    module: *Scope,
    name: []const u8,
    span: Source.Span,
    mutable: bool,
    end: u32,
) Error!void {
    const key = try self.keyOf(self.file, name);
    if (module.contains(key)) return self.reportDuplicate(name, span, key);

    try module.put(self.arena, key, .{ .mutable = mutable, .span = span });
    try self.facts.owner.put(self.arena, key, self.file);
    try self.facts.declarations.put(self.arena, key, .{ .file = self.file, .span = span });
    try self.module_declarations.put(self.arena, key, .{
        .file = self.file,
        .span = span,
        .end = end,
    });
    try self.noteElsewhere(name);
}

/// Section 7.1: "variables are visible only from their declarations." That is a
/// rule about one file, so it is checked by span and only against a declaration
/// in the file being walked. Returns whether the use is allowed.
fn declaredAbove(self: *Resolver, found: Found, span: Source.Span) Error!bool {
    if (found.scope != module_scope or found.binding.kind != .variable) return true;
    const declared = self.module_declarations.get(found.key) orelse return true;
    if (declared.file != self.file) return true;
    if (span.start >= declared.end) return true;

    if (span.start < declared.span.start) {
        try self.report(
            span,
            "`{s}` is not declared until later in the file",
            .{nameOf(found.key)},
            "A variable can only be used below its declaration. Move the declaration above this line.",
        );
    } else {
        // Inside its own declaration, as in `var x = x`.
        try self.report(
            span,
            "`{s}` is not defined",
            .{nameOf(found.key)},
            "Check the spelling, or declare it before this line.",
        );
    }
    return false;
}

/// The name as it was written, taken back out of a key.
fn nameOf(key: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, key, private_separator)) |at| {
        return key[at + private_separator.len ..];
    }
    if (std.mem.lastIndexOfScalar(u8, key, '.')) |at| return key[at + 1 ..];
    return key;
}

fn noteElsewhere(self: *Resolver, name: []const u8) Error!void {
    if (isPrivate(name)) return;
    const namespace = self.files[self.file].namespace;
    if (namespace.len == 0 or std.mem.eql(u8, namespace, prelude_namespace)) return;
    try self.elsewhere.put(self.arena, name, namespace);
}

/// What a bare module-level name means in one file: its own private names, and
/// every public name of its own namespace. Section 14.2 makes same-directory
/// names directly visible, so a file that grows into two needs no qualification.
fn buildKeyMap(self: *Resolver, map: *KeyMap) Error!void {
    const namespace = self.files[self.file].namespace;
    var entries = self.scopes.items[module_scope].keyIterator();
    while (entries.next()) |entry| try self.offerKey(map, namespace, entry.*);
    var declared = self.module_declarations.keyIterator();
    while (declared.next()) |entry| try self.offerKey(map, namespace, entry.*);
}

/// Section 14.2's `using`, which is file-local, imports only direct public
/// names, and neither includes nor executes anything: it renames, and that is
/// all it does.
fn applyUsing(self: *Resolver, declarations: []const Ast.Using, map: *KeyMap) Error!void {
    for (declarations) |declaration| {
        const path = try self.joinPath(declaration.path);

        if (declaration.alias.len != 0) {
            if (self.namespaces.contains(path)) {
                try self.namespace_aliases[self.file].put(self.arena, declaration.alias, path);
                continue;
            }
            if (self.scopes.items[module_scope].contains(path) or self.module_declarations.contains(path)) {
                try map.put(self.arena, declaration.alias, path);
                continue;
            }
            try self.reportUnknownPath(declaration, path);
            continue;
        }

        if (!self.namespaces.contains(path)) {
            try self.reportUnknownPath(declaration, path);
            continue;
        }

        // Only the names directly in that namespace, so `using Graphics` does
        // not quietly bring in everything under `graphics/ui/` as well.
        var imported: usize = 0;
        var names = self.module_declarations.keyIterator();
        while (names.next()) |key| {
            if (try self.importName(map, path, key.*)) imported += 1;
        }
        var functions = self.scopes.items[module_scope].keyIterator();
        while (functions.next()) |key| {
            if (try self.importName(map, path, key.*)) imported += 1;
        }

        if (imported == 0) try self.report(
            declaration.path_span,
            "`{s}` has no public names to use",
            .{path},
            "Every declaration in it starts with `_`, which section 14.2 keeps private to its own file.",
        );
    }
}

/// Returns whether `key` is a direct public name of `namespace`, having put it
/// in the map or marked it ambiguous.
fn importName(self: *Resolver, map: *KeyMap, namespace: []const u8, key: []const u8) Error!bool {
    if (std.mem.indexOf(u8, key, private_separator) != null) return false;
    if (!std.mem.startsWith(u8, key, namespace)) return false;
    if (key.len <= namespace.len or key[namespace.len] != '.') return false;
    const bare = key[namespace.len + 1 ..];
    if (std.mem.indexOfScalar(u8, bare, '.') != null) return false;

    // A name this file already has of its own wins. Section 14.2 makes
    // same-directory names directly visible, and an import should not be able
    // to take a name out from under the file that declared it.
    if (map.get(bare)) |existing| if (!isPreludeKey(existing)) {
        if (std.mem.eql(u8, existing, key)) return true;
        const own = try self.keyOf(self.file, bare);
        if (!std.mem.eql(u8, existing, own)) {
            try self.ambiguous[self.file].put(self.arena, bare, namespace);
        }
        return true;
    };

    try map.put(self.arena, bare, key);
    return true;
}

fn reportUnknownPath(self: *Resolver, declaration: Ast.Using, path: []const u8) Error!void {
    try self.report(
        declaration.path_span,
        "there is no `{s}` to use",
        .{path},
        "A namespace comes from a directory: `shapes/` makes `Shapes`. Check the spelling, and that the directory holds a `.em` file.",
    );
}

fn joinPath(self: *Resolver, path: []const []const u8) Error![]const u8 {
    if (path.len == 1) return path[0];
    var written: std.ArrayList(u8) = .empty;
    for (path, 0..) |segment, index| {
        if (index != 0) try written.append(self.arena, '.');
        try written.appendSlice(self.arena, segment);
    }
    return written.toOwnedSlice(self.arena);
}

/// Section 14.1: outside the entry file a top level holds declarations and
/// nothing else, so loading a project never runs arbitrary code and no file's
/// position in the walk can change what a program does.
fn checkModuleFile(self: *Resolver, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| switch (statement.data) {
        .function_declaration, .struct_declaration => {},
        .destructuring => {},
        .declaration => |declaration| {
            if (declaration.initializer != null) continue;
            try self.report(
                declaration.name_span,
                "`{s}` needs its value here",
                .{declaration.name},
                try std.fmt.allocPrint(
                    self.arena,
                    "Only the entry file, `{s}`, runs statements, so there is nowhere else to assign it. Write its value after `=`.",
                    .{self.entry_path},
                ),
            );
        },
        else => try self.report(
            statement.span,
            "this would never run",
            .{},
            try std.fmt.allocPrint(
                self.arena,
                "Only the entry file runs its top level. Move this into `{s}`, or into a function declared in this file.",
                .{self.entry_path},
            ),
        ),
    };
}

fn offerKey(self: *Resolver, map: *KeyMap, namespace: []const u8, key: []const u8) Error!void {
    if (std.mem.indexOf(u8, key, private_separator)) |at| {
        // Private: visible only in the file whose path names it.
        if (!std.mem.eql(u8, key[0..at], self.files[self.file].source.path)) return;
        return map.put(self.arena, key[at + private_separator.len ..], key);
    }
    // Keys are offered in no particular order, so a prelude name only fills a
    // gap and a file's own name always replaces it.
    if (isPreludeKey(key)) {
        const bare = key[prelude_namespace.len + 1 ..];
        if (std.mem.indexOfScalar(u8, bare, '.') != null) return;
        const slot = try map.getOrPut(self.arena, bare);
        if (!slot.found_existing) slot.value_ptr.* = key;
        return;
    }
    if (namespace.len == 0) {
        if (std.mem.indexOfScalar(u8, key, '.') == null) try map.put(self.arena, key, key);
        return;
    }
    if (!std.mem.startsWith(u8, key, namespace)) return;
    if (key.len <= namespace.len or key[namespace.len] != '.') return;
    const bare = key[namespace.len + 1 ..];
    if (std.mem.indexOfScalar(u8, bare, '.') != null) return;
    try map.put(self.arena, bare, key);
}

/// Section 7.1: function declarations are hoisted within their scope. Every
/// top-level function enters the module scope before any statement is walked,
/// so a function may be called above its declaration, and may call itself.
///
/// Functions and variables share one namespace, as section 7.3's "a name
/// declares one function" implies, so a variable that reuses a function's name
/// is the ordinary "already declared" error however the two are ordered in the
/// file.
fn hoistFunctions(self: *Resolver, statements: []const Ast.Statement) Error!void {
    const module = &self.scopes.items[module_scope];
    for (statements) |statement| {
        const function = switch (statement.data) {
            .function_declaration => |f| f,
            else => continue,
        };
        const key = try self.keyOf(self.file, function.name);
        if (module.contains(key)) {
            try self.reportDuplicate(function.name, function.name_span, key);
            continue;
        }
        try module.put(self.arena, key, .{
            .mutable = false,
            .span = function.name_span,
            .kind = .function,
        });
        try self.facts.owner.put(self.arena, key, self.file);
        try self.facts.declarations.put(self.arena, key, .{ .file = self.file, .span = function.name_span });
        try self.facts.module_reads.put(self.arena, key, .empty);
        try self.facts.calls.put(self.arena, key, .empty);
        try self.noteElsewhere(function.name);
    }
}

/// Two declarations of one name. Within a file that reads the way it always
/// has; across two files in one directory it has to say where the other one is,
/// because section 14.2 makes same-directory names share a namespace and the
/// reader cannot see both at once.
fn reportDuplicate(self: *Resolver, name: []const u8, span: Source.Span, key: []const u8) Error!void {
    if (self.facts.owner.get(key)) |other| {
        if (other != self.file) return self.report(
            span,
            "`{s}` is already declared in `{s}`",
            .{ name, self.files[other].source.path },
            "Files in one directory share a namespace. Rename one, or make this one private by starting its name with `_`.",
        );
    }
    try self.report(
        span,
        "`{s}` is already declared",
        .{name},
        "Each name can have one declaration in a scope. Choose a different name, or remove the duplicate.",
    );
}

fn push(self: *Resolver) !void {
    try self.scopes.append(self.arena, .empty);
}

fn pop(self: *Resolver) void {
    _ = self.scopes.pop();
}

const Found = struct { binding: Binding, scope: usize, key: []const u8 };

/// What a bare module-level name is called program-wide in the file being
/// walked, or null when no module-level declaration by that name is visible
/// here. Local scopes are keyed by the bare name; only the module scope is
/// keyed this way, because only it is shared between files.
fn moduleKey(self: *Resolver, name: []const u8) ?[]const u8 {
    if (self.facts.module_keys.len == 0) return null;
    return self.facts.module_keys[self.file].get(name);
}

fn lookup(self: *Resolver, name: []const u8) ?Found {
    var index = self.scopes.items.len;
    while (index > module_scope) {
        index -= 1;
        if (self.scopes.items[index].get(name)) |binding| {
            return .{ .binding = binding, .scope = index, .key = name };
        }
    }
    if (self.moduleKey(name)) |key| {
        if (self.scopes.items[module_scope].get(key)) |binding| {
            return .{ .binding = binding, .scope = module_scope, .key = key };
        }
    }
    if (self.scopes.items[prelude_scope].get(name)) |binding| {
        return .{ .binding = binding, .scope = prelude_scope, .key = name };
    }
    return null;
}

/// Which of `self.files` declares `found`: the current file for a local
/// (deeper than `module_scope`) or an unowned module-level binding, the
/// binding's own recorded owner for a module-level one, and the last file —
/// where the embedded prelude source lives — for a prelude binding.
fn targetFileFor(self: *Resolver, found: Found) u32 {
    if (found.scope > module_scope) return self.file;
    if (found.scope == module_scope) return self.facts.owner.get(found.key) orelse self.file;
    return @intCast(self.files.len - 1);
}

/// Whether the name is already visible within the current function, which is
/// what section 6.1 forbids redeclaring. Names beyond `function_boundary` — the
/// module scope seen from inside a function, and the prelude everywhere — may
/// be reused.
fn visibleLocal(self: *Resolver, name: []const u8) ?Binding {
    var index = self.scopes.items.len;
    while (index > self.function_boundary) {
        index -= 1;
        if (index == module_scope) {
            const key = self.moduleKey(name) orelse continue;
            if (self.scopes.items[index].get(key)) |binding| return binding;
            continue;
        }
        if (self.scopes.items[index].get(name)) |binding| return binding;
    }
    return null;
}

fn reportWithHelpFmt(
    self: *Resolver,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    comptime help_format: []const u8,
    help_args: anytype,
) Error!void {
    try self.report(span, message_format, message_args, try std.fmt.allocPrint(self.arena, help_format, help_args));
}

fn report(
    self: *Resolver,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) !void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = help,
        .file = self.file,
    });
}

/// A name that resolves to nothing. When a top-level variable of that name is
/// declared further down, the reader has most likely run into section 7.1's
/// "variables are visible only from their declarations", so that is what the
/// diagnostic says.
fn reportUndefined(self: *Resolver, span: Source.Span, name: []const u8, help: []const u8) Error!void {
    // A namespace is a real thing with a real name; it is just not a value.
    if (self.namespaces.contains(self.namespaceFor(name))) {
        return self.report(
            span,
            "`{s}` is a namespace, not a value",
            .{name},
            try std.fmt.allocPrint(
                self.arena,
                "Write the name you want from it, such as `{s}.area`, or put `using {s}` at the top of this file to reach its names directly.",
                .{ name, name },
            ),
        );
    }

    // Inside a type's own code, a bare name that is one of its members, which
    // is always reached through `self` or through the type (10.4).
    if (try self.memberOfEnclosingType(name)) |member| {
        const type_name = nameOf(member.type_key);
        if (member.type_level) {
            return self.reportWithHelpFmt(
                span,
                "`{s}` belongs to `{s}`, so it is reached through the type",
                .{ name, type_name },
                "Write `{s}.` in front, as in `{s}.{s}`.",
                .{ type_name, type_name, name },
            );
        }
        if (member.has_self) {
            return self.reportWithHelpFmt(
                span,
                "`{s}` is a member of `{s}`, so it is reached through `self`",
                .{ name, type_name },
                "Write `self.` in front, as in `self.{s}`.",
                .{name},
            );
        }
        return self.reportWithHelpFmt(
            span,
            "`{s}` belongs to each `{s}` value, and a type-level member has no `self`",
            .{ name, type_name },
            "Take the value as a parameter and write `value.{s}`.",
            .{name},
        );
    }
    // Section 7.1: a nested function sees only what is declared above it.
    if (self.function_scopes.getLastOrNull()) |innermost| {
        if (self.facts.nested_functions.get(innermost.key)) |function| {
            for (self.block_locals.items) |block| {
                if (block.scope >= innermost.scope) continue;
                for (block.names) |declared| {
                    if (!std.mem.eql(u8, declared.text, name) or declared.span.start < span.start) continue;
                    return self.reportWithHelpFmt(
                        span,
                        "`{s}` is declared below `{s}`",
                        .{ name, function.name },
                        "A nested function can use only the variables declared above it, as a block can. Move the declaration of `{s}` above `func {s}`.",
                        .{ name, function.name },
                    );
                }
            }
        }
    }
    if (std.mem.eql(u8, name, "this") and self.enclosingType() != null and self.enclosingType().?.has_self) {
        return self.report(
            span,
            "Emerald calls the current value `self`",
            .{},
            "Write `self` instead of `this`.",
        );
    }

    // Declared, but in another directory, so it needs its namespace.
    if (self.elsewhere.get(name)) |namespace| {
        return self.report(
            span,
            "`{s}` is not visible here",
            .{name},
            try std.fmt.allocPrint(
                self.arena,
                "It is declared in `{s}`. Write `{s}.{s}`, or add `using {s}` at the top of this file.",
                .{ namespace, namespace, name, namespace },
            ),
        );
    }

    // Running alone inside a project. Section 14.1 says a file outside a
    // project runs alone, and this is where that stops being invisible.
    if (self.enclosing_project) |enclosing| {
        const root = if (std.mem.eql(u8, enclosing, "."))
            ""
        else
            try std.fmt.allocPrint(self.arena, "{s}/", .{enclosing});
        return self.report(
            span,
            "`{s}` is not defined",
            .{name},
            try std.fmt.allocPrint(
                self.arena,
                "This file is running on its own, because its directory has no `main.em`. To run it as part of the project above it, use `emerald run {s}main.em`.",
                .{root},
            ),
        );
    }

    try self.report(span, "`{s}` is not defined", .{name}, help);
}

const EnclosingType = struct { type_key: []const u8, has_self: bool };

/// The type whose own code is being walked, worked out from the key the body
/// is recorded under: `Type::name` for a method, accessor, or type-level
/// function, `Type::` for type-level field values, and the type's own key for
/// its constructor and field defaults. Null in an ordinary function or at the
/// top level.
fn enclosingType(self: *Resolver) ?EnclosingType {
    // A nested function (7.1) is part of the code it is written in, as a
    // block is.
    const outermost: ?FunctionScope = if (self.function_scopes.items.len > 0) self.function_scopes.items[0] else null;
    const written_in = if (outermost) |function|
        (if (self.facts.nested_functions.contains(function.key)) function.enclosing else function.key)
    else
        self.current_function;
    const key = written_in orelse return null;
    if (std.mem.lastIndexOf(u8, key, method_separator)) |at| {
        const member = key[at + method_separator.len ..];
        const type_level = member.len == 0 or self.facts.type_members.contains(key);
        return .{ .type_key = key[0..at], .has_self = !type_level };
    }
    const binding = self.scopes.items[module_scope].get(key) orelse return null;
    if (binding.kind != .type) return null;
    return .{ .type_key = key, .has_self = true };
}

const MemberOfType = struct { type_key: []const u8, type_level: bool, has_self: bool };

/// Whether `name` is a member of the type whose code is being walked.
fn memberOfEnclosingType(self: *Resolver, name: []const u8) Error!?MemberOfType {
    const enclosing = self.enclosingType() orelse return null;
    const key = try methodKey(self.arena, enclosing.type_key, name);
    if (self.facts.type_members.contains(key)) {
        return .{ .type_key = enclosing.type_key, .type_level = true, .has_self = enclosing.has_self };
    }
    if (try self.instanceMemberOwner(enclosing.type_key, name) != null) {
        return .{ .type_key = enclosing.type_key, .type_level = false, .has_self = enclosing.has_self };
    }
    return null;
}

/// The namespace a short name stands for here, following a `using` alias.
fn namespaceFor(self: *Resolver, name: []const u8) []const u8 {
    if (self.namespace_aliases.len == 0) return name;
    return self.namespace_aliases[self.file].get(name) orelse name;
}

/// Records that the current function reads `name`, if `name` resolved to a
/// module-level variable. Reads of the function's own parameters and locals,
/// and anything at the top level, are not captures.
fn noteRead(self: *Resolver, found: Found) Error!void {
    const function = self.current_function orelse return;
    if (found.scope != module_scope or found.binding.kind != .variable) return;
    try self.facts.module_reads.getPtr(function).?.put(self.arena, found.key, {});
}

fn walkStatements(self: *Resolver, statements: []const Ast.Statement) Error!void {
    const hoisted = self.scopes.items.len > module_scope + 1 and try self.hoistNestedFunctions(statements);
    defer if (hoisted) {
        _ = self.block_locals.pop();
    };
    for (statements) |statement| try self.walkStatement(statement);
}

/// Section 7.1: "Nested named functions ... are hoisted within their
/// containing scope", so every one a block declares can be called anywhere in
/// the block, including by the others.
/// Returns whether the block declares any, in which case its variables are
/// pushed onto `block_locals` for the caller to pop.
fn hoistNestedFunctions(self: *Resolver, statements: []const Ast.Statement) Error!bool {
    var any = false;
    var names: std.ArrayList(Ast.Pattern.Name) = .empty;
    for (statements) |statement| switch (statement.data) {
        .function_declaration => any = true,
        .declaration => |declaration| try names.append(self.arena, .{ .text = declaration.name, .span = declaration.name_span }),
        .destructuring => |destructuring| try names.appendSlice(self.arena, destructuring.pattern.names),
        else => {},
    };
    if (!any) return false;
    try self.block_locals.append(self.arena, .{
        .scope = self.scopes.items.len - 1,
        .names = try names.toOwnedSlice(self.arena),
    });
    for (statements) |statement| {
        const function = switch (statement.data) {
            .function_declaration => |f| f,
            else => continue,
        };
        if (self.visibleLocal(function.name) != null) {
            try self.report(
                function.name_span,
                "`{s}` is already declared",
                .{function.name},
                "Each name can have one declaration in a function. Choose a different name.",
            );
            continue;
        }
        const key = try nestedKey(self.arena, self.file, function);
        try self.facts.nested_keys.put(self.arena, .{ .file = self.file, .start = function.name_span.start }, key);
        try self.facts.nested_functions.put(self.arena, key, function);
        try self.facts.owner.put(self.arena, key, self.file);
        try self.facts.module_reads.put(self.arena, key, .empty);
        try self.facts.calls.put(self.arena, key, .empty);
        try self.facts.local_captures.put(self.arena, key, .empty);
        const current = &self.scopes.items[self.scopes.items.len - 1];
        try current.put(self.arena, function.name, .{
            .mutable = false,
            .span = function.name_span,
            .kind = .function,
            .function_key = key,
        });
    }
    return true;
}

/// Records that the function being walked reaches a local of a function
/// around it, which a use of the function has to come after (7.1).
fn noteCapture(self: *Resolver, found: Found, read: bool) Error!void {
    if (found.scope <= module_scope or found.binding.kind != .variable) return;
    const innermost = self.function_scopes.getLastOrNull() orelse return;
    if (found.scope >= innermost.scope) return;
    // Owned by the innermost function whose scopes include it.
    var owner: []const u8 = "";
    for (self.function_scopes.items) |function| {
        if (function.scope <= found.scope) owner = function.key;
    }
    try self.facts.local_captures.getPtr(innermost.key).?.append(self.arena, .{
        .name = found.key,
        .owner = owner,
        .declared = found.binding.span.start,
        .read = read,
    });
}

/// Section 7.1: "Hoisting never permits reading an uninitialized captured
/// variable." Each use of a nested function is judged against every local of
/// its own function that the use can reach, through the functions it calls.
fn judgeNestedUses(self: *Resolver) Error!void {
    for (self.nested_uses.items) |use| {
        var visited: NameSet = .empty;
        var pending: std.ArrayList([]const u8) = .empty;
        try visited.put(self.arena, use.key, {});
        try pending.append(self.arena, use.key);
        var needed: std.ArrayList([]const u8) = .empty;
        var reported = false;
        while (pending.pop()) |current| {
            if (self.facts.local_captures.get(current)) |captures| for (captures.items) |capture| {
                if (!std.mem.eql(u8, capture.owner, use.caller)) continue;
                if (capture.declared > use.expression.span.start) {
                    if (!reported) {
                        self.file = use.file;
                        try self.report(
                            use.expression.span,
                            "`{s}` uses `{s}`, which is not declared until later",
                            .{ use.expression.data.name, capture.name },
                            try std.fmt.allocPrint(
                                self.arena,
                                "Move the declaration of `{s}` above this line, or move this below it.",
                                .{capture.name},
                            ),
                        );
                    }
                    reported = true;
                    continue;
                }
                if (capture.read) try needed.append(self.arena, capture.name);
            };
            if (self.facts.calls.get(current)) |callees| {
                var it = callees.keyIterator();
                while (it.next()) |callee| {
                    // Only a nested function can reach this frame's locals.
                    // Calling the function the use is in, or any other one,
                    // starts a frame of its own.
                    if (!self.facts.nested_functions.contains(callee.*)) continue;
                    if (std.mem.eql(u8, callee.*, use.caller)) continue;
                    if (visited.contains(callee.*)) continue;
                    try visited.put(self.arena, callee.*, {});
                    try pending.append(self.arena, callee.*);
                }
            }
        }
        if (!reported and needed.items.len > 0) {
            try self.facts.nested_uses.put(self.arena, use.expression, try needed.toOwnedSlice(self.arena));
        }
    }
}

/// Section 6.3: the subject, then each arm's alternatives and body in order.
/// Each block arm is a scope of its own.
fn walkCase(self: *Resolver, case: *const Ast.Case) Error!void {
    if (case.subject) |subject| try self.walkExpression(subject);
    for (case.arms) |arm| {
        for (arm.alternatives) |alternative| try self.walkExpression(alternative);
        try self.walkCaseBody(arm.body);
    }
    if (case.otherwise) |otherwise| try self.walkCaseBody(otherwise);
}

fn walkCaseBody(self: *Resolver, body: Ast.Case.Body) Error!void {
    switch (body) {
        .block => |block| try self.walkBlock(block),
        .value => |value| try self.walkExpression(value),
    }
}

fn walkBlock(self: *Resolver, block: Ast.Block) Error!void {
    try self.push();
    defer self.pop();
    try self.walkStatements(block.statements);
}

fn walkStatement(self: *Resolver, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| try self.walkExpression(expression),

        .declaration => |declaration| {
            // The initializer is resolved first, so `var x = x` reports the
            // right-hand `x` as undefined rather than quietly seeing itself.
            if (declaration.initializer) |initializer| try self.walkExpression(initializer);

            // Section 4.1 lets a variable start unassigned, but a `const` can
            // never be assigned afterward, so it would stay that way. Later
            // assignments are then let through, since they are how this
            // `const` was meant to get its value, and the one report covers it.
            const missing_value = !declaration.mutable and declaration.initializer == null;
            if (missing_value) {
                try self.report(
                    declaration.name_span,
                    "`{s}` is a `const`, so it needs a value where it is declared",
                    .{declaration.name},
                    "Write its value after `=`, or declare it with `var` if it is assigned later.",
                );
            }

            if (self.scopes.items.len > module_scope + 1 and self.visibleLocal(declaration.name) != null) {
                // A nested function below is hoisted above this, but the one
                // written second is the duplicate a reader finds.
                const existing = self.visibleLocal(declaration.name).?;
                const later = existing.kind == .function and existing.span.start > declaration.name_span.start;
                try self.report(
                    if (later) existing.span else declaration.name_span,
                    "`{s}` is already declared",
                    .{declaration.name},
                    if (later)
                        "A function and a variable in one function cannot share a name. Choose a different name for one of them."
                    else
                        "Assign to the existing name instead of declaring it again, or choose a different name.",
                );
                return;
            }

            // Already in place, with its duplicates reported, if this is the
            // module level; see `declareModuleLevel`.
            if (self.scopes.items.len == module_scope + 1) return;

            const current = &self.scopes.items[self.scopes.items.len - 1];
            try current.put(self.arena, declaration.name, .{
                .mutable = declaration.mutable or missing_value,
                .span = declaration.name_span,
            });
        },

        .assignment => |assignment| {
            // `total += price` may run `add` (11.5).
            if (assignment.operation) |operation| if (operation.contract()) |contract| {
                try self.noteMemberCall(contract.method);
            };
            if (try self.typeFieldTarget(assignment)) |target| {
                return self.walkTypeFieldAssignment(assignment, target);
            }
            for (assignment.steps, 0..) |step, position| switch (step) {
                .index => |index| try self.walkExpression(index),
                // Reaching a field may run a getter, and assigning the last
                // one may run a setter.
                .field => |field| {
                    try self.noteMemberCall(field.name);
                    if (position + 1 == assignment.steps.len) {
                        try self.noteMemberCall(try std.fmt.allocPrint(self.arena, "{s}" ++ setter_suffix, .{field.name}));
                    }
                },
            };
            try self.walkExpression(assignment.value);
            // `super.size = 3` sets a base class's property (10.7).
            if (std.mem.eql(u8, assignment.name, "super")) return;

            // Section 15.5's built-in Float constants have no declaration
            // binding for the ordinary assignment path to find.
            if (self.lookup(assignment.name) == null and assignment.steps.len == 1 and
                std.mem.eql(u8, assignment.name, "Float") and assignment.steps[0] == .field)
            {
                const member = assignment.steps[0].field;
                const span: Source.Span = .{ .start = assignment.name_span.start, .end = member.span.end };
                if (std.mem.eql(u8, member.name, "infinity") or std.mem.eql(u8, member.name, "nan")) {
                    return self.report(
                        span,
                        "`Float.{s}` is a constant, so it cannot be assigned",
                        .{member.name},
                        "Keep the Float you need in a `var` instead.",
                    );
                }
                return self.reportWithHelpFmt(
                    span,
                    "`Float` has no type-level member named `{s}`",
                    .{member.name},
                    "Its type-level constants are `Float.infinity` and `Float.nan`.",
                    .{},
                );
            }

            try self.checkAmbiguous(assignment.name, assignment.name_span);
            const found = self.lookup(assignment.name) orelse {
                return self.reportUndefined(
                    assignment.name_span,
                    assignment.name,
                    "Declare it first with `var`, or check the spelling.",
                );
            };
            if (!try self.declaredAbove(found, assignment.name_span)) return;

            try self.facts.assignment_targets.put(self.arena, .{ .file = self.file, .start = assignment.name_span.start }, .{ .file = targetFileFor(self, found), .span = found.binding.span });

            if (self.lambda_depth > 0) {
                try self.facts.assigned_in_lambda.put(self.arena, assignment.name, {});
            }
            if (assignment.steps.len == 0) try self.facts.reassigned.put(self.arena, assignment.name, {});
            try self.noteAssignedInFunction(found);
            try self.noteCapture(found, assignment.operation != null or assignment.steps.len > 0);

            // A compound assignment reads the current value first, so it needs
            // the variable to be assigned already; a plain one does not. An
            // assignment into a place reads whatever it changes.
            if (assignment.operation != null or assignment.steps.len > 0) {
                try self.noteRead(found);
            }

            // Changing what a name holds is a question about its type, which
            // the checker answers, since section 4.3's `const` covers both.
            if (assignment.steps.len > 0) return;

            if (!found.binding.mutable) {
                try self.reportReadOnly(assignment.name, assignment.name_span, found.binding.kind);
            }
        },

        .conditional => |conditional| {
            try self.walkExpression(conditional.condition);
            try self.walkBlock(conditional.then_block);
            if (conditional.otherwise) |otherwise| switch (otherwise) {
                .block => |block| try self.walkBlock(block),
                .chained => |chained| try self.walkStatement(chained.*),
            };
        },

        .while_loop => |loop| {
            try self.walkExpression(loop.condition);
            try self.walkBlock(loop.body);
        },

        .case_statement => |case| try self.walkCase(case),

        .for_loop => |loop| try self.walkFor(loop),

        .break_statement, .continue_statement => {},

        .function_declaration => |function| {
            if (self.scopes.items.len == module_scope + 1) {
                return self.walkBody(try self.keyOf(self.file, function.name), function.parameters, function.body.statements, false);
            }
            // Not hoisted when its name was already taken, which is reported.
            const key = self.facts.nested_keys.get(.{ .file = self.file, .start = function.name_span.start }) orelse return;
            try self.walkBody(key, function.parameters, function.body.statements, false);
        },
        .struct_declaration => |declaration| {
            const type_key = try self.keyOf(self.file, declaration.name);
            try self.walkFieldDefaults(type_key, declaration.fields);
            if (declaration.constructor) |constructor| {
                try self.walkBody(type_key, constructor.parameters, constructor.body.statements, true);
            }
            for (declaration.methods) |method| {
                try self.walkBody(
                    try methodKey(self.arena, type_key, method.name),
                    method.parameters,
                    method.body.statements,
                    true,
                );
            }
            for (declaration.type_functions) |function| {
                try self.walkBody(
                    try methodKey(self.arena, type_key, function.member),
                    function.declaration.parameters,
                    function.declaration.body.statements,
                    false,
                );
            }
            try self.walkTypeFields(type_key, declaration.type_fields);
            for (declaration.properties) |property| {
                try self.walkBody(
                    try methodKey(self.arena, type_key, property.name),
                    &.{},
                    property.getter.body.statements,
                    true,
                );
                if (property.setter) |setter| {
                    try self.walkBody(
                        try setterKey(self.arena, type_key, property.name),
                        setter.parameters,
                        setter.body.statements,
                        true,
                    );
                }
            }
        },

        .return_statement => |return_statement| {
            if (return_statement.value) |value| try self.walkExpression(value);
        },

        .raise_statement => |raised| if (raised.value) |value| try self.walkExpression(value),

        .assert_statement => |assertion| {
            try self.walkExpression(assertion.condition);
            if (assertion.message) |message| try self.walkExpression(message);
        },

        .try_statement => |protected| {
            try self.walkBlock(protected.body);
            for (protected.catches) |caught| {
                try self.push();
                const scope = &self.scopes.items[self.scopes.items.len - 1];
                try scope.put(self.arena, caught.name, .{ .mutable = false, .span = caught.name_span });
                try self.walkStatements(caught.body.statements);
                self.pop();
            }
            if (protected.finally_block) |cleanup| try self.walkBlock(cleanup);
        },

        .destructuring => |destructuring| {
            try self.walkExpression(destructuring.initializer);
            for (destructuring.pattern.names) |name| {
                try self.declarePatternName(name, destructuring.mutable);
            }
        },

        .destructuring_assignment => |assignment| {
            // The whole right side first, so `(left, right) = (right, left)`
            // reads both names before either is written, exactly as it runs.
            try self.walkExpression(assignment.value);
            for (assignment.pattern.names) |name| {
                if (std.mem.eql(u8, name.text, "_")) continue;
                try self.checkAmbiguous(name.text, name.span);
                const found = self.lookup(name.text) orelse {
                    try self.reportUndefined(
                        name.span,
                        name.text,
                        "Declare it first with `var`, or check the spelling.",
                    );
                    continue;
                };
                if (!try self.declaredAbove(found, name.span)) continue;
                try self.facts.assignment_targets.put(self.arena, .{ .file = self.file, .start = name.span.start }, .{ .file = targetFileFor(self, found), .span = found.binding.span });
                if (self.lambda_depth > 0) {
                    try self.facts.assigned_in_lambda.put(self.arena, name.text, {});
                }
                try self.facts.reassigned.put(self.arena, name.text, {});
                try self.noteAssignedInFunction(found);
                try self.noteCapture(found, false);
                if (!found.binding.mutable) try self.reportReadOnly(name.text, name.span, found.binding.kind);
            }
        },
    }
}

/// The type an assignment's destination starts at, when its name is a type
/// and its first step names a member of it: `Player.count = 0`. Null for every
/// other assignment.
fn typeFieldTarget(self: *Resolver, assignment: Ast.Assignment) Error!?[]const u8 {
    if (assignment.steps.len == 0 or assignment.steps[0] != .field) return null;
    const found = self.lookup(assignment.name) orelse return null;
    if (found.scope != module_scope or found.binding.kind != .type) return null;
    return found.key;
}

/// Section 10.4's `Player.count += 1`, and `Registry.names[0] = "a"` below
/// it. Assigning to the field sets up the type first, like reading it.
fn walkTypeFieldAssignment(self: *Resolver, assignment: Ast.Assignment, type_key: []const u8) Error!void {
    const first = assignment.steps[0].field;
    for (assignment.steps[1..], 1..) |step, position| switch (step) {
        .index => |index| try self.walkExpression(index),
        .field => |field| {
            try self.noteMemberCall(field.name);
            if (position + 1 == assignment.steps.len) {
                try self.noteMemberCall(try std.fmt.allocPrint(self.arena, "{s}" ++ setter_suffix, .{field.name}));
            }
        },
    };
    try self.walkExpression(assignment.value);

    const span: Source.Span = .{ .start = assignment.name_span.start, .end = first.span.end };
    switch (try self.qualifyTypeMember(span, type_key, assignment.name, first.name)) {
        .key => |key| {
            try self.noteTypeMember(key);
            const binding = self.scopes.items[module_scope].get(key).?;
            const written = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ assignment.name, first.name });
            if (binding.kind == .function) return self.reportReadOnly(written, span, .function);
            try self.facts.type_assignments.put(self.arena, .{ .file = self.file, .start = assignment.name_span.start }, written);
            // The passes after this one treat the destination as the one
            // binding `Player.count`, found through this file's keys like any
            // module-level name. No bare name contains a dot, so this can
            // shadow nothing.
            try @constCast(&self.facts.module_keys[self.file]).put(self.arena, written, key);
            if (assignment.operation != null or assignment.steps.len > 1) {
                try self.noteRead(.{ .binding = binding, .scope = module_scope, .key = key });
            }
            if (assignment.steps.len == 1 and self.enum_values.contains(key)) {
                try self.reportWithHelpFmt(
                    span,
                    "`{s}` is one of `{s}`'s values, so it cannot be assigned",
                    .{ written, assignment.name },
                    "An enum's values never change. Keep the one you need in a `var` of type `{s}` instead.",
                    .{assignment.name},
                );
            } else if (assignment.steps.len == 1 and !binding.mutable) {
                try self.reportReadOnly(written, span, .variable);
            }
        },
        .reported, .none => {},
    }
}

/// Records a module-level variable assigned inside a body that can be called
/// from anywhere; see `Facts.assigned_in_function`.
fn noteAssignedInFunction(self: *Resolver, found: Found) Error!void {
    if (self.current_function == null) return;
    if (found.scope != module_scope or found.binding.kind != .variable) return;
    try self.facts.assigned_in_function.put(self.arena, found.key, {});
}

/// One name a pattern introduces. Section 8.2 makes `_` discard its position,
/// so it binds nothing and may appear more than once.
fn declarePatternName(self: *Resolver, name: Ast.Pattern.Name, mutable: bool) Error!void {
    if (std.mem.eql(u8, name.text, "_")) return;

    // Already in place, with its duplicates reported, if this is the module
    // level; see `declareModuleLevel`.
    if (self.scopes.items.len == module_scope + 1) return;

    if (self.visibleLocal(name.text) != null) {
        return self.report(
            name.span,
            "`{s}` is already declared",
            .{name.text},
            "Assign to the existing name instead of declaring it again, or choose a different name.",
        );
    }

    const current = &self.scopes.items[self.scopes.items.len - 1];
    try current.put(self.arena, name.text, .{ .mutable = mutable, .span = name.span });
}

/// The reason a name cannot be assigned to, which section 4.3, 6.4, and 7.1
/// each give differently.
fn reportReadOnly(
    self: *Resolver,
    name: []const u8,
    span: Source.Span,
    binding_kind: BindingKind,
) Error!void {
    switch (binding_kind) {
        .variable => try self.report(
            span,
            "`{s}` cannot be reassigned",
            .{name},
            "It was declared with `const`. Use `var` if the value needs to change.",
        ),
        .parameter, .later_parameter => try self.report(
            span,
            "`{s}` cannot be reassigned",
            .{name},
            "Parameters are read-only. Assign it to a local variable first if you need a version that can change.",
        ),
        .loop_variable => try self.report(
            span,
            "`{s}` cannot be reassigned",
            .{name},
            "A loop variable takes each value in turn. Copy it into a `var` if you need one that changes.",
        ),
        .function => try self.report(
            span,
            "`{s}` is a function and cannot be assigned to",
            .{name},
            "Declare a variable with a different name to hold the value.",
        ),
        .type => try self.report(
            span,
            "`{s}` is a type and cannot be assigned to",
            .{name},
            "Declare a variable with a different name to hold a value.",
        ),
        .self_value => try self.report(
            span,
            "`self` cannot be replaced",
            .{},
            "Set its fields one at a time instead, as in `self.x = x`.",
        ),
    }
}

/// The loop variable lives in the body's scope, which section 6.4 makes fresh
/// for every iteration. The iterable is resolved outside it, before the
/// variable exists, since it is evaluated once before the loop begins.
fn walkFor(self: *Resolver, loop: Ast.For) Error!void {
    try self.walkExpression(loop.iterable);

    try self.push();
    defer self.pop();

    if (loop.pattern) |pattern| {
        for (pattern.names) |name| {
            if (std.mem.eql(u8, name.text, "_")) continue;
            if (self.visibleLocal(name.text) != null) {
                try self.report(
                    name.span,
                    "`{s}` is already declared",
                    .{name.text},
                    "Give the loop variable a name of its own.",
                );
                continue;
            }
            try self.scopes.items[self.scopes.items.len - 1].put(self.arena, name.text, .{
                .mutable = false,
                .span = name.span,
                .kind = .loop_variable,
            });
        }
        try self.walkStatements(loop.body.statements);
        return;
    }

    // `_` visits each value without naming it.
    if (!std.mem.eql(u8, loop.name, "_")) {
        if (self.visibleLocal(loop.name) != null) {
            try self.report(
                loop.name_span,
                "`{s}` is already declared",
                .{loop.name},
                "Give the loop variable a name of its own.",
            );
        } else {
            try self.scopes.items[self.scopes.items.len - 1].put(self.arena, loop.name, .{
                .mutable = false,
                .span = loop.name_span,
                .kind = .loop_variable,
            });
        }
    }

    try self.walkStatements(loop.body.statements);
}

/// Section 10.2's field defaults, which run as part of construction and so are
/// recorded under the type's key, like its constructor. `self` is in scope; the
/// checker decides which fields a default may read through it.
fn walkFieldDefaults(self: *Resolver, type_key: []const u8, fields: []const Ast.StructDeclaration.Field) Error!void {
    std.debug.assert(self.scopes.items.len == module_scope + 1);
    try self.push();
    const outer_boundary = self.function_boundary;
    const outer_function = self.current_function;
    self.function_boundary = self.scopes.items.len - 1;
    self.current_function = type_key;
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.current_function = outer_function;
    }
    try self.scopes.items[self.scopes.items.len - 1].put(self.arena, "self", .{
        .mutable = false,
        .span = .{ .start = 0, .end = 0 },
        .kind = .self_value,
    });
    for (fields) |field| {
        if (field.default) |default| try self.walkExpression(default);
    }
}

/// Section 10.4's type-level field values, in declaration order, recorded
/// under the type's setup key. Each may read only the fields before it.
fn walkTypeFields(self: *Resolver, type_key: []const u8, fields: []const Ast.StructDeclaration.TypeField) Error!void {
    std.debug.assert(self.scopes.items.len == module_scope + 1);
    try self.push();
    const outer_boundary = self.function_boundary;
    const outer_function = self.current_function;
    self.function_boundary = self.scopes.items.len - 1;
    self.current_function = try typeSetupKey(self.arena, type_key);
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.current_function = outer_function;
        self.unready_type_fields = .empty;
    }
    for (fields) |field| {
        try self.unready_type_fields.put(self.arena, try methodKey(self.arena, type_key, field.name), {});
    }
    for (fields) |field| {
        try self.walkExpression(field.initializer);
        _ = self.unready_type_fields.remove(try methodKey(self.arena, type_key, field.name));
    }
}

/// Records that the function being walked reaches a type-level member, which
/// first sets up the type's fields.
fn noteTypeMember(self: *Resolver, key: []const u8) Error!void {
    const caller = self.current_function orelse return;
    const type_key = self.facts.type_members.get(key) orelse return;
    const setup = try typeSetupKey(self.arena, type_key);
    if (std.mem.eql(u8, caller, setup)) return;
    try self.facts.calls.getPtr(caller).?.put(self.arena, setup, {});
}

/// `Vector2.origin` or `Player.count`: a member reached through its type.
/// `written` is the type as the reader wrote it.
fn qualifyTypeMember(
    self: *Resolver,
    span: Source.Span,
    type_key: []const u8,
    written: []const u8,
    member: []const u8,
) Error!Qualified {
    const key = try methodKey(self.arena, type_key, member);
    if (self.facts.type_members.contains(key)) {
        if (self.unready_type_fields.contains(key)) {
            try self.report(
                span,
                "`{s}.{s}` is not set up yet when this runs",
                .{ written, member },
                try std.fmt.allocPrint(
                    self.arena,
                    "A type-level field's value can read only the type-level fields declared above it. Declare `{s}.{s}` above this field.",
                    .{ written, member },
                ),
            );
            return .reported;
        }
        return .{ .key = key };
    }
    // Section 11.2's `Named.introduction(self)`, which runs a trait's own
    // default; the checker judges the call.
    if (self.facts.traits.contains(type_key) and self.instance_members.contains(key) and !isPrivate(member)) {
        return .{ .key = key };
    }
    if (try self.instanceMemberOwner(type_key, member) != null) {
        // Section 10.5: from outside the type, that it is private is the
        // mistake, since reaching it through a value would fail too.
        if (isPrivate(member)) {
            const inside = if (self.enclosingType()) |enclosing| std.mem.eql(u8, enclosing.type_key, type_key) else false;
            if (!inside) {
                try self.reportWithHelpFmt(
                    span,
                    "`{s}` is private to `{s}`",
                    .{ member, nameOf(type_key) },
                    "Only code written inside `{s}`'s braces can reach a name that starts with `_`.",
                    .{nameOf(type_key)},
                );
                return .reported;
            }
        }
        try self.reportWithHelpFmt(
            span,
            "`{s}` belongs to each `{s}` value, not to the type",
            .{ member, written },
            "Reach it through a value of `{s}` instead. Only a member declared with the type's name in front, such as `var {s}.count = 0`, belongs to the type.",
            .{ written, written },
        );
        return .reported;
    }
    if (self.enum_listings.get(type_key)) |listing| {
        try self.reportWithHelpFmt(
            span,
            "`{s}` has no value or type-level member named `{s}`",
            .{ written, member },
            "Check the spelling. The values of `{s}` are {s}.",
            .{ written, listing },
        );
        return .reported;
    }
    // Section 10.7: type-level members are not inherited.
    var base = self.facts.bases.get(type_key);
    var steps: usize = 0;
    while (base) |base_key| : (base = self.facts.bases.get(base_key)) {
        // A cycle of bases is reported by the checker; stop going round it.
        steps += 1;
        if (steps > self.facts.bases.count()) break;
        if (!self.facts.type_members.contains(try methodKey(self.arena, base_key, member))) continue;
        try self.reportWithHelpFmt(
            span,
            "`{s}` belongs to the type `{s}`, and a class does not inherit type-level members",
            .{ member, nameOf(base_key) },
            "Reach it through the type that declares it, as in `{s}.{s}`.",
            .{ nameOf(base_key), member },
        );
        return .reported;
    }
    try self.reportWithHelpFmt(
        span,
        "`{s}` has no type-level member named `{s}`",
        .{ written, member },
        "Check the spelling. A type-level member is declared inside the type with its name in front, as in `var {s}.{s} = ...` or `func {s}.{s}()`.",
        .{ written, member, written, member },
    );
    return .reported;
}

/// Whether calling a module-level binding runs a body the checker has to follow
/// for section 7.1's capture rule: a function's, or a type's constructor.
fn isCallable(kind: BindingKind) bool {
    return kind == .function or kind == .type;
}

/// Walks a function or constructor body where it is written. The module scope
/// stays visible underneath, holding exactly the variables declared above it
/// plus every function (all hoisted), which is section 7.1's visibility. `key`
/// is the declaration the body's reads and calls are recorded under; a
/// constructor's are recorded under its type, since calling the type runs it.
///
/// A struct declaration is only accepted at the top level. A nested function
/// (7.1) sees the locals declared above it, as a block does.
fn walkBody(
    self: *Resolver,
    key: []const u8,
    parameter_list: []const Ast.Parameter,
    statements: []const Ast.Statement,
    /// Whether `self` is in scope: a constructor's or a method's body.
    has_self: bool,
) Error!void {
    const nested = self.scopes.items.len > module_scope + 1;
    try self.push();
    const outer_boundary = self.function_boundary;
    const outer_function = self.current_function;
    const outer_lambda_depth = self.lambda_depth;
    self.function_boundary = self.scopes.items.len - 1;
    self.current_function = key;
    // A nested function assigning a variable around it can do so between a
    // test and a use, exactly as a block can (4.5).
    self.lambda_depth = if (nested) outer_lambda_depth + 1 else 0;
    try self.function_scopes.append(self.arena, .{
        .scope = self.scopes.items.len - 1,
        .key = key,
        .enclosing = outer_function,
    });
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.current_function = outer_function;
        self.lambda_depth = outer_lambda_depth;
        _ = self.function_scopes.pop();
    }

    const parameters = &self.scopes.items[self.scopes.items.len - 1];
    if (has_self) {
        // `self` is a keyword, so no parameter can already be called this.
        try parameters.put(self.arena, "self", .{
            .mutable = false,
            .span = .{ .start = 0, .end = 0 },
            .kind = .self_value,
        });
    }
    for (parameter_list) |parameter| {
        if (parameters.contains(parameter.name)) {
            try self.report(
                parameter.name_span,
                "`{s}` is already a parameter",
                .{parameter.name},
                "Give each parameter a different name.",
            );
            continue;
        }
        try parameters.put(self.arena, parameter.name, .{
            .mutable = false, // Section 7.1: parameters are read-only.
            .span = parameter.name_span,
            .kind = .later_parameter,
        });
    }
    // Section 7.3: "A default may read earlier parameters but not itself or
    // later parameters." Each becomes readable once its own default is walked.
    for (parameter_list) |parameter| {
        if (parameter.default) |default| try self.walkExpression(default);
        if (parameters.getPtr(parameter.name)) |binding| binding.kind = .parameter;
    }

    // The body's top level shares the parameters' scope, so a local that
    // reuses a parameter's name is shadowing within the same function.
    try self.walkStatements(statements);
}

/// What a member expression turned out to be.
const Qualified = union(enum) {
    /// A namespace-qualified reference to this module-level declaration.
    key: []const u8,
    /// A qualified reference to something that is not there; already reported.
    reported,
    /// Not qualified at all: an ordinary property access on a value.
    none,
};

/// Whether this whole member chain names one module-level declaration.
///
/// The chain is only followed while it is made of plain names, so
/// `Shapes.area(3).to_string()` stops at `Shapes.area` and the rest stays
/// ordinary. A chain whose leading name is a value is never a namespace, which
/// is what keeps `text.upper()` out of here.
fn qualify(self: *Resolver, expression: *const Ast.Expression) Error!Qualified {
    var names: [max_path_segments][]const u8 = undefined;
    const length = chainOf(expression, &names) orelse return .none;
    if (length < 2) return .none;

    // A local or a module binding of that name is a value; section 14.2's
    // namespaces do not shadow it. A type is the one module-level name with
    // members of its own (10.4).
    if (self.lookup(names[0])) |found| {
        if (length == 2 and found.scope == module_scope and found.binding.kind == .type) {
            return self.qualifyTypeMember(expression.span, found.key, names[0], names[1]);
        }
        return .none;
    }

    if (length == 2 and std.mem.eql(u8, names[0], "Float")) {
        if (std.mem.eql(u8, names[1], "infinity")) return .{ .key = float_infinity_key };
        if (std.mem.eql(u8, names[1], "nan")) return .{ .key = float_nan_key };
        try self.reportWithHelpFmt(
            expression.span,
            "`Float` has no type-level member named `{s}`",
            .{names[1]},
            "Its type-level constants are `Float.infinity` and `Float.nan`.",
            .{},
        );
        return .reported;
    }

    // A project namespace named `Program` remains an ordinary namespace, the
    // same way `Math` does below.
    if (length == 2 and std.mem.eql(u8, names[0], "Program") and !self.namespaces.contains(self.namespaceFor("Program"))) {
        if (std.mem.eql(u8, names[1], "arguments")) return .{ .key = program_arguments_key };
        try self.reportWithHelpFmt(
            expression.span,
            "`Program` has no type-level member named `{s}`",
            .{names[1]},
            "Its one member is `Program.arguments`.",
            .{},
        );
        return .reported;
    }

    // A project namespace named `Math` remains an ordinary namespace. The
    // built-in namespace is only used when no project declaration owns it.
    if (length == 2 and std.mem.eql(u8, names[0], "Math") and !self.namespaces.contains(self.namespaceFor("Math"))) {
        if (std.mem.eql(u8, names[1], "pi")) return .{ .key = math_pi_key };
        if (std.mem.eql(u8, names[1], "e")) return .{ .key = math_e_key };
        const key = try std.fmt.allocPrint(self.arena, "Math.{s}", .{names[1]});
        if (mathFunction(key) != null) return .{ .key = key };
        try self.reportWithHelpFmt(
            expression.span,
            "`Math` has no member named `{s}`",
            .{names[1]},
            "Use its constants `Math.pi` and `Math.e`, or one of its documented numerical functions.",
            .{},
        );
        return .reported;
    }

    var path: []const u8 = self.namespaceFor(names[0]);
    for (names[1 .. length - 1]) |segment| {
        path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, segment });
    }
    if (!self.namespaces.contains(path)) {
        // `Shapes.Circle.unit`: a type reached through its namespace, then
        // one of its type-level members.
        if (length >= 3) {
            const dot = std.mem.lastIndexOfScalar(u8, path, '.').?;
            if (self.namespaces.contains(path[0..dot])) {
                if (self.scopes.items[module_scope].get(path)) |binding| {
                    if (binding.kind == .type) {
                        const written = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ names[0], path[dot + 1 ..] });
                        return self.qualifyTypeMember(expression.span, path, written, names[length - 1]);
                    }
                }
            }
        }
        return .none;
    }

    const last = names[length - 1];
    const key = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, last });
    if (self.scopes.items[module_scope].contains(key) or self.module_declarations.contains(key)) {
        return .{ .key = key };
    }

    if (isPrivate(last)) {
        try self.report(
            expression.span,
            "`{s}` is private to the file that declares it",
            .{last},
            "A module-level name starting with `_` cannot be reached from another file. Remove the underscore to make it public.",
        );
        return .reported;
    }

    try self.report(
        expression.span,
        "`{s}` is not declared in `{s}`",
        .{ last, path },
        "Check the spelling. Only names without a leading underscore are visible outside the file that declares them.",
    );
    return .reported;
}

/// One segment per directory the project loader accepts, plus a declaration
/// and its type-level member. A longer chain is a property access on a value,
/// which this is not about.
const max_path_segments = Project.max_depth + 2;

/// Fills `names` with a chain of plain names, outermost last, and returns how
/// many. Null when the chain does not bottom out in a name.
fn chainOf(expression: *const Ast.Expression, names: *[max_path_segments][]const u8) ?usize {
    var length: usize = 0;
    var at = expression;
    while (true) {
        switch (at.data) {
            .name => |name| {
                if (length == max_path_segments) return null;
                names[length] = name;
                length += 1;
                std.mem.reverse([]const u8, names[0..length]);
                return length;
            },
            .member => |member| {
                if (length == max_path_segments) return null;
                names[length] = member.name;
                length += 1;
                at = member.base;
            },
            else => return null,
        }
    }
}

/// Section 14.2: two `using` declarations may offer the same short name, and
/// that is reported where the name is used rather than where they are written.
fn checkAmbiguous(self: *Resolver, name: []const u8, span: Source.Span) Error!void {
    if (self.ambiguous.len == 0) return;
    const candidate = self.ambiguous[self.file].get(name) orelse return;
    try self.report(
        span,
        "`{s}` could mean more than one thing here",
        .{name},
        try std.fmt.allocPrint(
            self.arena,
            "More than one `using` offers it. Write the namespace it should come from, such as `{s}.{s}`, or give one an alias: `using Short = {s}`.",
            .{ candidate, name, candidate },
        ),
    );
}

fn walkExpression(self: *Resolver, expression: *const Ast.Expression) Error!void {
    switch (expression.data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .enum_value => {},

        .name => |name| {
            // Section 10.7's `super` is the object itself, seen as its base
            // class, and the parser has already said where it may appear.
            if (std.mem.eql(u8, name, "super")) return;
            try self.checkAmbiguous(name, expression.span);
            const found = self.lookup(name) orelse {
                return self.reportUndefined(
                    expression.span,
                    name,
                    "Check the spelling, or declare it before this line.",
                );
            };
            if (!try self.declaredAbove(found, expression.span)) return;
            try self.facts.expression_targets.put(self.arena, expression, .{ .file = targetFileFor(self, found), .span = found.binding.span });
            if (found.binding.kind == .later_parameter) {
                return self.report(
                    expression.span,
                    "`{s}` comes later in the parameter list, so this default cannot read it",
                    .{name},
                    "A default can read only the parameters before it. Reorder the parameters, or compute the value in the body.",
                );
            }
            try self.noteRead(found);
            try self.noteCapture(found, true);
            if (found.binding.function_key) |key| {
                if (self.current_function) |caller| {
                    try self.facts.calls.getPtr(caller).?.put(self.arena, key, {});
                }
                try self.nested_uses.append(self.arena, .{
                    .expression = expression,
                    .key = key,
                    .caller = self.current_function orelse "",
                    .file = self.file,
                });
            }
        },

        .unary => |unary| try self.walkExpression(unary.operand),
        .binary => |binary| {
            try self.walkExpression(binary.left);
            try self.walkExpression(binary.right);
            // On a user type, an operator runs a method (11.5).
            if (binary.operator.contract()) |contract| try self.noteMemberCall(contract.method);
        },
        .logical => |logical| {
            try self.walkExpression(logical.left);
            try self.walkExpression(logical.right);
        },
        .comparison => |comparison| {
            for (comparison.operands) |operand| try self.walkExpression(operand);
            for (comparison.operators) |operator| {
                if (operator.isEquality()) continue;
                try self.noteMemberCall(Ast.OperatorContract.ordered.method);
                break;
            }
        },
        .call => |call| {
            try self.walkExpression(call.callee);
            if (self.current_function) |caller| {
                if (call.callee.data == .name) {
                    const callee = call.callee.data.name;
                    if (self.lookup(callee)) |found| {
                        if (found.scope == module_scope and isCallable(found.binding.kind)) {
                            try self.facts.calls.getPtr(caller).?.put(self.arena, found.key, {});
                        }
                    }
                }
                if (call.callee.data == .member and !self.facts.qualified.contains(call.callee)) {
                    try self.noteMemberCall(call.callee.data.member.name);
                }
            }
            for (call.arguments) |argument| try self.walkExpression(argument);
        },
        .range => |range| {
            try self.walkExpression(range.start);
            try self.walkExpression(range.end);
        },
        .list_literal => |elements| for (elements) |element| try self.walkExpression(element),
        .index => |index| {
            try self.walkExpression(index.base);
            try self.walkExpression(index.index);
        },
        .slice => |slice| {
            try self.walkExpression(slice.base);
            if (slice.start) |start| try self.walkExpression(start);
            if (slice.end) |end| try self.walkExpression(end);
        },
        .member => |member| {
            // `Shapes.area` is one name, not a property of a value. Deciding
            // which it is happens once, here, and the answer is recorded for
            // the checker and the interpreter to read.
            switch (try self.qualify(expression)) {
                .key => |key| {
                    try self.facts.qualified.put(self.arena, expression, key);
                    try self.noteTypeMember(key);
                    if (self.current_function) |caller| {
                        if (self.facts.calls.contains(key)) try self.facts.calls.getPtr(caller).?.put(self.arena, key, {});
                    }
                    if (self.scopes.items[module_scope].get(key)) |binding| {
                        try self.noteRead(.{ .binding = binding, .scope = module_scope, .key = key });
                        if (self.current_function) |caller| {
                            if (isCallable(binding.kind)) {
                                try self.facts.calls.getPtr(caller).?.put(self.arena, key, {});
                            }
                        }
                    }
                },
                .reported => {},
                .none => {
                    // A property read runs its getter.
                    try self.noteMemberCall(member.name);
                    try self.walkExpression(member.base);
                },
            }
        },
        .string_literal => {},
        .interpolation => |parts| for (parts) |part| switch (part) {
            .text => {},
            .expression => |part_expression| try self.walkExpression(part_expression),
        },
        .lambda => |lambda| try self.walkLambda(lambda),
        .case_expression => |case| try self.walkCase(case),
        .tuple_literal => |positions| for (positions) |position| try self.walkExpression(position),
        .type_test => |test_| try self.walkExpression(test_.value),
        .dictionary_literal => |entries| for (entries) |entry| {
            try self.walkExpression(entry.key);
            try self.walkExpression(entry.value);
        },
    }
}

/// Section 7.4's lambda body, which unlike a named function's body is walked
/// where it is written, with every enclosing scope still visible: that
/// visibility is exactly what capture is.
///
/// A lambda is a function boundary for section 6.1's shadowing rule, so
/// `names.each { name => ... }` is allowed alongside an outer `name`. Crossing
/// a function boundary has always been allowed, and a parameter that names what
/// the block receives is the whole point of writing one.
fn walkLambda(self: *Resolver, lambda: Ast.Expression.Lambda) Error!void {
    try self.push();
    const outer_boundary = self.function_boundary;
    self.function_boundary = self.scopes.items.len - 1;
    self.lambda_depth += 1;
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.lambda_depth -= 1;
    }

    const parameters = &self.scopes.items[self.scopes.items.len - 1];
    for (lambda.parameters) |parameter| {
        // Section 8.6's `{ (name, age) => ... }`: the names of the unpacked
        // tuple are the block's own, exactly as a plain parameter is.
        if (parameter.pattern) |pattern| {
            for (pattern.names) |name| {
                if (std.mem.eql(u8, name.text, "_")) continue;
                if (parameters.contains(name.text)) {
                    try self.report(
                        name.span,
                        "`{s}` is already a parameter of this lambda",
                        .{name.text},
                        "Give each parameter a different name.",
                    );
                    continue;
                }
                try parameters.put(self.arena, name.text, .{
                    .mutable = false,
                    .span = name.span,
                    .kind = .parameter,
                });
            }
            continue;
        }

        // Section 7.4: `_` discards the argument and may appear more than once,
        // so it binds nothing and cannot collide.
        if (std.mem.eql(u8, parameter.name, "_")) continue;
        if (parameters.contains(parameter.name)) {
            try self.report(
                parameter.name_span,
                "`{s}` is already a parameter of this lambda",
                .{parameter.name},
                "Give each parameter a different name.",
            );
            continue;
        }
        try parameters.put(self.arena, parameter.name, .{
            .mutable = false, // Section 7.1: parameters are read-only.
            .span = parameter.name_span,
            .kind = .parameter,
        });
    }

    switch (lambda.body) {
        .expression => |body| try self.walkExpression(body),
        // The body's top level shares the parameters' scope, as a named
        // function's does.
        .block => |body| try self.walkStatements(body.statements),
    }
}
