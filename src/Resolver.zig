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
pub const prelude = [_][]const u8{ "print", "write", "input", "input_maybe" };

/// `self_value` is section 10.2's `self` inside a constructor: its fields are
/// set one at a time, but the value itself is never replaced.
pub const BindingKind = enum { variable, parameter, loop_variable, function, type, self_value };

const Binding = struct {
    mutable: bool,
    /// Where the name was declared, so a later diagnostic can point at it.
    span: Source.Span,
    /// Decides the reason a reassignment diagnostic gives: section 4.3 makes a
    /// `const` read-only, section 7.1 makes a parameter read-only, section 6.4
    /// makes a loop variable read-only, and a function is not a variable at all.
    kind: BindingKind = .variable,
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

    for (files, programs, 0..) |file, program, index| {
        resolver.file = @intCast(index);
        if (!file.entry) try resolver.checkModuleFile(program.statements);
        try resolver.walkStatements(program.statements);
    }

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
        // Constructing a value runs its constructor, which may read module
        // variables and call functions like any function body, so a call to
        // the type is recorded exactly as a call to a function is.
        try self.facts.module_reads.put(self.arena, key, .empty);
        try self.facts.calls.put(self.arena, key, .empty);
        try self.noteElsewhere(declaration.name);

        for (declaration.methods) |method| {
            try self.hoistMember(method.name, try methodKey(self.arena, key, method.name));
        }
        for (declaration.properties) |property| {
            try self.hoistMember(property.name, try methodKey(self.arena, key, property.name));
            if (property.setter != null) {
                const setter_name = try std.fmt.allocPrint(self.arena, "{s}" ++ setter_suffix, .{property.name});
                try self.hoistMember(setter_name, try setterKey(self.arena, key, property.name));
            }
        }
    }
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
    if (namespace.len == 0) return;
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
    if (map.get(bare)) |existing| {
        if (std.mem.eql(u8, existing, key)) return true;
        const own = try self.keyOf(self.file, bare);
        if (!std.mem.eql(u8, existing, own)) {
            try self.ambiguous[self.file].put(self.arena, bare, namespace);
        }
        return true;
    }

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
    for (statements) |statement| try self.walkStatement(statement);
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
                try self.report(
                    declaration.name_span,
                    "`{s}` is already declared",
                    .{declaration.name},
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

            try self.checkAmbiguous(assignment.name, assignment.name_span);
            const found = self.lookup(assignment.name) orelse {
                return self.reportUndefined(
                    assignment.name_span,
                    assignment.name,
                    "Declare it first with `var`, or check the spelling.",
                );
            };
            if (!try self.declaredAbove(found, assignment.name_span)) return;

            if (self.lambda_depth > 0) {
                try self.facts.assigned_in_lambda.put(self.arena, assignment.name, {});
            }

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

        .for_loop => |loop| try self.walkFor(loop),

        .break_statement, .continue_statement => {},

        .function_declaration => |function| try self.walkBody(
            try self.keyOf(self.file, function.name),
            function.parameters,
            function.body.statements,
            false,
        ),
        .struct_declaration => |declaration| {
            const type_key = try self.keyOf(self.file, declaration.name);
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
                if (self.lambda_depth > 0) {
                    try self.facts.assigned_in_lambda.put(self.arena, name.text, {});
                }
                if (!found.binding.mutable) try self.reportReadOnly(name.text, name.span, found.binding.kind);
            }
        },
    }
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
        .parameter => try self.report(
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
/// The parser only accepts a function or struct declaration at the top level,
/// so the scope stack here is always the prelude and the module scope and
/// nothing else; no enclosing block's locals can leak in.
fn walkBody(
    self: *Resolver,
    key: []const u8,
    parameter_list: []const Ast.Parameter,
    statements: []const Ast.Statement,
    /// Whether `self` is in scope: a constructor's or a method's body.
    has_self: bool,
) Error!void {
    std.debug.assert(self.scopes.items.len == module_scope + 1);

    try self.push();
    const outer_boundary = self.function_boundary;
    const outer_function = self.current_function;
    self.function_boundary = self.scopes.items.len - 1;
    self.current_function = key;
    defer {
        self.pop();
        self.function_boundary = outer_boundary;
        self.current_function = outer_function;
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
            .kind = .parameter,
        });
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
    // namespaces do not shadow it.
    if (self.lookup(names[0]) != null) return .none;

    var path: []const u8 = self.namespaceFor(names[0]);
    for (names[1 .. length - 1]) |segment| {
        path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, segment });
    }
    if (!self.namespaces.contains(path)) return .none;

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

/// A namespace path is a handful of segments at most; a longer chain is a
/// property access on a value, which this is not about.
const max_path_segments = 8;

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
        .int_literal, .float_literal, .bool_literal, .nothing_literal => {},

        .name => |name| {
            try self.checkAmbiguous(name, expression.span);
            const found = self.lookup(name) orelse {
                return self.reportUndefined(
                    expression.span,
                    name,
                    "Check the spelling, or declare it before this line.",
                );
            };
            if (!try self.declaredAbove(found, expression.span)) return;
            try self.noteRead(found);
        },

        .unary => |unary| try self.walkExpression(unary.operand),
        .binary => |binary| {
            try self.walkExpression(binary.left);
            try self.walkExpression(binary.right);
        },
        .logical => |logical| {
            try self.walkExpression(logical.left);
            try self.walkExpression(logical.right);
        },
        .comparison => |comparison| {
            for (comparison.operands) |operand| try self.walkExpression(operand);
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
        .member => |member| {
            // `Shapes.area` is one name, not a property of a value. Deciding
            // which it is happens once, here, and the answer is recorded for
            // the checker and the interpreter to read.
            switch (try self.qualify(expression)) {
                .key => |key| {
                    try self.facts.qualified.put(self.arena, expression, key);
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
        .tuple_literal => |positions| for (positions) |position| try self.walkExpression(position),
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
