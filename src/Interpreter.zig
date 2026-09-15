//! Evaluates a syntax tree.
//!
//! The arithmetic rules are section 5.3's, and they are written out here rather
//! than inherited from the host, because result types and failure modes are
//! exactly what a backend tends to get subtly wrong:
//!
//!   `+` `-` `*`  two `Int`s give an `Int` with overflow checked, otherwise `Float`
//!   `/`          always `Float`
//!   `//`         rounds toward negative infinity; two `Int`s give an `Int`
//!   `%`          paired with `//` by `a == (a // b) * b + (a % b)`
//!   `**`         two `Int`s give an `Int`, and a negative `Int` exponent raises
//!
//! Division by zero is an error for both numeric types, and integer overflow
//! raises rather than wrapping.
//!
//! # The host stack
//!
//! This is a tree-walking interpreter, so every Emerald call and every level of
//! nesting inside one is recursion on the host stack. Section 7.2 requires at
//! least 1,000 active calls, and requires excessive recursion to be detected
//! "before exhausting its host stack". The default stack does not meet the
//! first requirement: a probe with a modestly nested body crashed on 8 MiB
//! between 600 and 800 calls in a Debug build. So `emerald.zig` runs the whole
//! pipeline on a thread whose stack is reserved large enough for 1,000 calls
//! even at the deepest nesting section 3.4 guarantees, and `guardStack` meets
//! the second requirement for any body at all by raising before the
//! reservation runs out.

const std = @import("std");
const Ast = @import("Ast.zig");
const Checker = @import("Checker.zig");
const Diagnostic = @import("Diagnostic.zig");
const Heap = @import("Heap.zig");
const Project = @import("Project.zig");
const Range = @import("Range.zig").Range;
const Resolver = @import("Resolver.zig");
const Source = @import("Source.zig");
const Type = @import("Type.zig");
const Value = @import("Value.zig");
const strings = @import("strings.zig");
const unicode = @import("unicode.zig");
const call_arguments = @import("arguments.zig");

const Interpreter = @This();

/// What running a program produced. An unhandled Emerald error stops an ordinary
/// run; test mode collects one failure per test and continues discovery order.
pub const Outcome = struct {
    arena_state: std.heap.ArenaAllocator,
    failure: ?Diagnostic,
    test_failures: []const Diagnostic = &.{},
    test_count: usize = 0,
    /// A requested process status. Unlike an error, it is not diagnostic.
    exit_code: ?u8 = null,

    pub fn ok(self: Outcome) bool {
        return self.failure == null and self.test_failures.len == 0;
    }

    pub fn deinit(self: *Outcome) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

const Binding = Heap.Binding;
const Scope = std.StringHashMapUnmanaged(Binding);
const Environment = Heap.Environment;

/// Section 7.2's portable minimum, exactly. The limit above it is a resource
/// boundary rather than language semantics, and the spec gives programs no way
/// to change it.
const max_call_depth = 1000;

/// How much of the host stack this run may use, measured from `base`, the
/// address of a local near the bottom of the thread running the pipeline.
pub const StackLimit = struct {
    base: usize,
    budget: usize,

    /// Room left beneath the budget for whatever runs between two checks, and
    /// for raising the error itself.
    const margin: usize = 1024 * 1024;

    /// Call at the base of the thread, with the size of its stack.
    pub fn here(available: usize) StackLimit {
        var marker: u8 = 0;
        return .{ .base = @intFromPtr(&marker), .budget = available - margin };
    }
};

pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Section 14.1: a module file "initializes once when one of its members is
/// first accessed", and "a cycle reaching an unfinished binding is an
/// initialization-cycle error".
const ModuleState = enum { pending, running, done, failed };

/// Section 10.4's type-level fields "follow the same lazy rule" as a file's
/// bindings, one type at a time.
const TypeSetup = struct {
    fields: []const Ast.StructDeclaration.TypeField,
    display_name: []const u8,
    /// What a stack trace calls the setup, so an error inside one says what
    /// was running and what reached the type.
    frame_name: []const u8,
    state: ModuleState = .pending,
    failed_value: ?Value = null,
    failed_diagnostic: ?Diagnostic = null,
};

/// `Returned`, `Broke`, and `Continued` are control flow rather than failures:
/// each unwinds through `execute` to the construct that handles it, the way
/// `Raised` unwinds to the top. The checker guarantees every one has a handler.
const Error = error{ Raised, Returned, Broke, Continued, Exited } || RunError;

/// Lives as long as the run: hoisted functions, module bindings, and the
/// failure that ends the program.
arena: std.mem.Allocator,
/// Everything that ends with a block or a call: its scope, and the arguments
/// being passed. Freed as each one finishes, so a loop that calls a function a
/// million times does not keep a million dead frames.
gpa: std.mem.Allocator,
/// The program's files. Only the entry file's top level runs; the rest are
/// initialized on first use, which is what section 14.1 asks for.
files: []const Project.File = &.{},
programs: []const Ast.Program = &.{},
/// How far each file's module-level bindings have got. The entry file is
/// `.done` from the start, because its top level is the program.
module_states: []ModuleState = &.{},
module_failed_values: []?Value = &.{},
module_failed_diagnostics: []?Diagnostic = &.{},
test_mode: bool = false,
test_binding_states: std.StringHashMapUnmanaged(ModuleState) = .empty,
test_binding_failures: std.StringHashMapUnmanaged(struct { value: Value, diagnostic: Diagnostic }) = .empty,
/// Which file the statement being executed was written in. It decides what a
/// bare module-level name means and which file a diagnostic points into.
file: u32 = 0,
facts: Resolver.Facts = .{},
out: *std.Io.Writer,
/// Where `input` reads lines from.
in: *std.Io.Reader,
failure: ?Diagnostic = null,
/// The typed Emerald value traveling with `error.Raised`.
raised_value: ?Value = null,
/// The error currently handled by the innermost catch, for bare `raise`.
caught_value: ?Value = null,
caught_failure: ?Diagnostic = null,
exit_code: ?u8 = null,
/// One string for each string literal, made the first time the literal runs
/// and shared by every run after it, so a loop that prints a literal does not
/// allocate.
literal_texts: std.AutoHashMapUnmanaged(*const Ast.Expression, *Heap.Text) = .empty,
random_engine: ?std.Random.DefaultPrng = null,

/// Top-level bindings, from `arena`. A function sees these, and it sees them
/// as they are when it runs; the checker has already proved that everything a
/// call reads is assigned by then.
module: Scope = .empty,
/// Block scopes at the top level, or the current call's own scopes, innermost
/// last. A call replaces this stack for its duration, so a function never sees
/// the block-local names of whoever called it, and a closure's call restores
/// the stack the closure captured.
///
/// Each scope is a counted object rather than a stack frame, because section
/// 7.4's capture is by reference: a closure written inside a block holds that
/// block's environment, and the block ending does not end the variables.
scopes: std.ArrayList(*Environment) = .empty,
/// Environments nothing captured, kept for reuse. A loop body opens a scope
/// every iteration, and taking one from here instead of allocating makes a loop
/// that declares a local cost no allocation at all once it is running.
spare_scopes: std.ArrayList(*Environment) = .empty,

functions: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
/// Struct types, keyed program-wide and carrying their short source name for
/// display.
structs: std.StringHashMapUnmanaged(*const Value.StructType) = .empty,
/// Section 10.4: every struct with type-level fields, by its key, and how far
/// setting them up has got.
type_setups: std.StringHashMapUnmanaged(TypeSetup) = .empty,
/// The structs that declare their own constructor (10.2), by the same keys.
constructors: std.StringHashMapUnmanaged(Constructor) = .empty,
/// Every struct's declaration and what calling its generated constructor
/// matches arguments against, by the same keys.
struct_infos: std.StringHashMapUnmanaged(StructInfo) = .empty,
/// What the checker proved about each function, including return types it
/// inferred, which are needed to widen results the way it allowed.
signatures: *const Type.Signatures,
/// Instance methods that change `self`, and which method each call reaches.
changing_methods: *const Resolver.NameSet,
method_calls: *const Checker.MethodCalls,
/// Every `super.name` that reaches a base class's property (10.7).
super_members: *const Checker.MethodCalls,
/// Section 4.4's type tests and `type_name` reads, with the static types they
/// need.
type_tests: *const Checker.TypeTests,
type_names: *const Checker.LiteralTypes,
/// Section 11.2's `Trait.method(value)` calls, by expression.
trait_calls: *const Checker.MethodCalls,
/// Every trait, by key, with the keys of the traits it builds on.
trait_infos: std.StringHashMapUnmanaged(TraitInfo) = .empty,
/// Every method that overrides another, mapped to the declaration it
/// ultimately replaces, whose parameter defaults it uses (7.3).
overrides: std.StringHashMapUnmanaged([]const u8) = .empty,
/// The type the checker gave each list literal, so `[1, 2]` where a `[Float]`
/// is expected is built from `1.0` and `2.0`.
literal_types: *const Checker.LiteralTypes,
/// Every list buffer. See `Heap` for the counting rules this file follows:
/// every new holder of a list retains it, and every holder that ends releases
/// it.
heap: Heap,
call_stack: std.ArrayList(Diagnostic.Frame) = .empty,
/// Fields of objects whose struct a changing method or setter has taken out
/// while it runs, innermost last (4.3, 10.1).
taken_fields: std.ArrayList(TakenField) = .empty,
/// Set by a `return` for `callFunction` to collect. `return` unwinds through
/// `execute` as `error.Returned`, and this carries its value, the way
/// `failure` carries `error.Raised`'s.
return_value: ?Value = null,

stack: StackLimit,

pub fn run(
    gpa: std.mem.Allocator,
    files: []const Project.File,
    programs: []const Ast.Program,
    signatures: *const Type.Signatures,
    literal_types: *const Checker.LiteralTypes,
    checked_structs: *const Checker.Structs,
    changing_methods: *const Resolver.NameSet,
    method_calls: *const Checker.MethodCalls,
    super_members: *const Checker.MethodCalls,
    type_tests: *const Checker.TypeTests,
    type_names: *const Checker.LiteralTypes,
    trait_calls: *const Checker.MethodCalls,
    facts: Resolver.Facts,
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    stack: StackLimit,
    test_mode: bool,
) RunError!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();

    const states = try gpa.alloc(ModuleState, files.len);
    defer gpa.free(states);
    const module_failed_values = try gpa.alloc(?Value, files.len);
    defer gpa.free(module_failed_values);
    const module_failed_diagnostics = try gpa.alloc(?Diagnostic, files.len);
    defer gpa.free(module_failed_diagnostics);
    @memset(module_failed_values, null);
    @memset(module_failed_diagnostics, null);
    var entry: u32 = 0;
    for (files, states, 0..) |file, *state, index| {
        state.* = if (file.entry and !test_mode) .done else .pending;
        if (file.entry) entry = @intCast(index);
    }

    var interpreter: Interpreter = .{
        .arena = arena_state.allocator(),
        .gpa = gpa,
        .files = files,
        .programs = programs,
        .module_states = states,
        .module_failed_values = module_failed_values,
        .module_failed_diagnostics = module_failed_diagnostics,
        .file = entry,
        .facts = facts,
        .out = out,
        .in = in,
        .signatures = signatures,
        .changing_methods = changing_methods,
        .method_calls = method_calls,
        .super_members = super_members,
        .type_tests = type_tests,
        .type_names = type_names,
        .trait_calls = trait_calls,
        .literal_types = literal_types,
        .heap = .init(gpa),
        .stack = stack,
        .test_mode = test_mode,
    };
    // Whatever the counts did not reclaim, including lists still held by
    // module bindings and anything an error skipped releasing.
    defer interpreter.heap.deinit();
    defer interpreter.literal_texts.deinit(gpa);

    // Hoisted, matching the resolver and checker. Every file's functions are
    // in place before anything runs, so a call into another file never depends
    // on that file having been reached yet.
    for (programs, 0..) |program, index| {
        interpreter.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data == .struct_declaration) {
                const declaration = statement.data.struct_declaration;
                const checked = checked_structs.get(interpreter.keyOf(declaration.name)).?;
                const checked_fields = checked.user.?.fields;
                const fields = try interpreter.arena.alloc(Value.StructType.Field, checked_fields.len);
                for (checked_fields, fields) |field, *runtime| {
                    runtime.* = .{ .name = field.name, .kind = kindOf(field.type) };
                }
                const type_key = interpreter.keyOf(declaration.name);
                const properties = try interpreter.arena.alloc(Value.StructType.Property, declaration.properties.len);
                for (declaration.properties, properties) |property, *runtime| {
                    const getter = try Resolver.methodKey(interpreter.arena, type_key, property.name);
                    try interpreter.functions.put(interpreter.arena, getter, property.getter);
                    var setter: ?[]const u8 = null;
                    if (property.setter) |declared| {
                        setter = try Resolver.setterKey(interpreter.arena, type_key, property.name);
                        try interpreter.functions.put(interpreter.arena, setter.?, declared);
                    }
                    runtime.* = .{ .name = property.name, .getter = getter, .setter = setter };
                }
                const adopted = try interpreter.arena.alloc([]const u8, checked.user.?.traits.len);
                for (checked.user.?.traits, adopted) |trait, *trait_key| trait_key.* = trait.name;
                // Section 11.1: a trait is never built, so it has no
                // descriptor; its defaults are functions like any method.
                if (declaration.trait) {
                    for (declaration.methods) |method| {
                        const method_key = try Resolver.methodKey(interpreter.arena, type_key, method.name);
                        const hoisted = try interpreter.functions.getOrPut(interpreter.arena, method_key);
                        if (!hoisted.found_existing) hoisted.value_ptr.* = method;
                    }
                    try interpreter.trait_infos.put(interpreter.arena, type_key, .{
                        .declaration = declaration,
                        .traits = adopted,
                        .display_name = declaration.name,
                    });
                    continue;
                }
                const descriptor = try interpreter.arena.create(Value.StructType);
                var depth: u32 = 0;
                var ancestor = checked.user.?.base;
                while (ancestor) |user| : (ancestor = user.base) depth += 1;
                var values: std.ArrayList([]const u8) = .empty;
                for (declaration.type_fields) |field| {
                    if (field.enum_value != null) try values.append(interpreter.arena, field.name);
                }
                descriptor.* = .{
                    .values = values.items,
                    .name = type_key,
                    .display_name = checked.user.?.display_name,
                    .class = checked.user.?.class,
                    .fields = fields,
                    .properties = properties,
                    .depth = depth,
                };
                for (properties) |*property| {
                    property.depth = depth;
                    property.owner = descriptor.display_name;
                }
                try interpreter.structs.put(
                    interpreter.arena,
                    interpreter.keyOf(declaration.name),
                    descriptor,
                );
                // A method is called like a function whose body also sees
                // `self`, so it is kept with the functions, under its own key.
                for (declaration.methods) |method| {
                    const method_key = try Resolver.methodKey(interpreter.arena, interpreter.keyOf(declaration.name), method.name);
                    const hoisted = try interpreter.functions.getOrPut(interpreter.arena, method_key);
                    if (!hoisted.found_existing) hoisted.value_ptr.* = method;
                }
                // A type-level function is an ordinary function under its
                // member key (10.4).
                for (declaration.type_functions) |function| {
                    const member_key = try Resolver.methodKey(interpreter.arena, type_key, function.member);
                    const hoisted = try interpreter.functions.getOrPut(interpreter.arena, member_key);
                    if (!hoisted.found_existing) hoisted.value_ptr.* = function.declaration;
                }
                if (declaration.type_fields.len > 0) {
                    try interpreter.type_setups.put(interpreter.arena, type_key, .{
                        .fields = declaration.type_fields,
                        .display_name = descriptor.display_name,
                        .frame_name = try std.fmt.allocPrint(
                            interpreter.arena,
                            "the type-level fields of `{s}`",
                            .{descriptor.display_name},
                        ),
                    });
                }
                {
                    const field_names = try interpreter.arena.alloc([]const u8, declaration.fields.len);
                    const has_default = try interpreter.arena.alloc(bool, declaration.fields.len);
                    var any_default = false;
                    for (declaration.fields, field_names, has_default) |field, *name, *defaulted| {
                        name.* = field.name;
                        defaulted.* = field.default != null;
                        any_default = any_default or defaulted.*;
                    }
                    try interpreter.struct_infos.put(interpreter.arena, type_key, .{
                        .declaration = declaration,
                        .field_names = field_names,
                        .has_default = has_default,
                        .any_default = any_default,
                        .base = if (checked.user.?.base) |base| base.name else null,
                        .traits = adopted,
                        .offset = checked.user.?.inherited,
                        .defaults_frame = try std.fmt.allocPrint(
                            interpreter.arena,
                            "the field defaults of `{s}`",
                            .{descriptor.display_name},
                        ),
                    });
                }
                if (declaration.constructor) |constructor| {
                    try interpreter.constructors.put(interpreter.arena, interpreter.keyOf(declaration.name), .{
                        .declaration = constructor,
                        .frame_name = try std.fmt.allocPrint(
                            interpreter.arena,
                            "the constructor of `{s}`",
                            .{descriptor.display_name},
                        ),
                    });
                }
                continue;
            }
            if (statement.data != .function_declaration) continue;
            const function = statement.data.function_declaration;
            try interpreter.functions.put(interpreter.arena, interpreter.keyOf(function.name), function);
        }
    }
    interpreter.file = entry;
    // Section 10.7: a class that extends another has its base classes' properties
    // and methods too, which are known once every class is hoisted.
    {
        var bases: std.StringHashMapUnmanaged(void) = .empty;
        var infos = interpreter.struct_infos.valueIterator();
        while (infos.next()) |info| if (info.base) |base| try bases.put(interpreter.arena, base, {});
        var finished: std.StringHashMapUnmanaged(void) = .empty;
        var keys = interpreter.struct_infos.keyIterator();
        while (keys.next()) |key| try interpreter.inherit(key.*, &bases, &finished);
    }
    {
        var nested = interpreter.facts.nested_functions.iterator();
        while (nested.next()) |entry_| try interpreter.functions.put(interpreter.arena, entry_.key_ptr.*, entry_.value_ptr.*);
    }

    // Each block and call frees its own scope as it ends, including while an
    // error unwinds through it, so only the lists themselves are left.
    defer interpreter.scopes.deinit(gpa);
    defer interpreter.call_stack.deinit(gpa);
    defer interpreter.taken_fields.deinit(gpa);
    // A recycled environment is out of the heap's live list, so it is this
    // list's to free.
    defer {
        for (interpreter.spare_scopes.items) |environment| {
            environment.bindings.deinit(gpa);
            gpa.destroy(environment);
        }
        interpreter.spare_scopes.deinit(gpa);
    }

    if (test_mode) {
        var failures: std.ArrayList(Diagnostic) = .empty;
        var count: usize = 0;
        for (programs, 0..) |program, file_index| {
            for (program.statements) |statement| {
                if (statement.data != .function_declaration) continue;
                const function = statement.data.function_declaration;
                if (function.test_span == null) continue;
                count += 1;
                interpreter.file = @intCast(file_index);
                const key = interpreter.keyOf(function.name);
                const result = interpreter.invoke(function.name_span, interpreter.namedCallable(key), &.{}) catch |err| switch (err) {
                    error.Raised => {
                        var diagnostic = interpreter.failure.?;
                        diagnostic.message = try std.fmt.allocPrint(interpreter.arena, "test `{s}` failed: {s}", .{ function.name, diagnostic.message });
                        try failures.append(interpreter.arena, diagnostic);
                        if (interpreter.raised_value) |value| interpreter.heap.release(value);
                        interpreter.raised_value = null;
                        interpreter.failure = null;
                        continue;
                    },
                    error.Exited => return .{ .arena_state = arena_state, .failure = null, .test_failures = failures.items, .test_count = count, .exit_code = interpreter.exit_code },
                    error.Returned, error.Broke, error.Continued => unreachable,
                    else => |other| return other,
                };
                interpreter.heap.release(result);
            }
        }
        return .{ .arena_state = arena_state, .failure = null, .test_failures = failures.items, .test_count = count };
    }

    interpreter.executeAll(programs[entry].statements) catch |err| switch (err) {
        error.Raised => {},
        // The checker rejects `return` outside a function, and section 14.1's
        // top-level `return` is deferred. It rejects `break` and `continue`
        // outside a loop.
        error.Exited => {},
        error.Returned, error.Broke, error.Continued => unreachable,
        else => |other| return other,
    };

    const failure = interpreter.failure;
    return .{ .arena_state = arena_state, .failure = failure, .exit_code = interpreter.exit_code };
}

/// Completes a class's descriptor with what it inherits, its base classes'
/// first: every property, each at the nearest version to this class, and for
/// a class in a hierarchy, the table of which version each method name runs.
fn inherit(
    self: *Interpreter,
    key: []const u8,
    bases: *const std.StringHashMapUnmanaged(void),
    finished: *std.StringHashMapUnmanaged(void),
) RunError!void {
    if (finished.contains(key)) return;
    try finished.put(self.arena, key, {});
    const info = self.struct_infos.get(key).?;
    const descriptor: *Value.StructType = @constCast(self.structs.get(key).?);
    if (info.base == null and !bases.contains(key) and info.traits.len == 0) return;

    const methods = try self.arena.create(Value.StructType.Methods);
    methods.* = .empty;
    var properties: std.ArrayList(Value.StructType.Property) = .empty;
    var traits: std.ArrayList([]const u8) = .empty;
    if (info.base) |base| {
        try self.inherit(base, bases, finished);
        const inherited = self.structs.get(base).?;
        descriptor.base = inherited;
        try traits.appendSlice(self.arena, inherited.traits);
        try properties.appendSlice(self.arena, inherited.properties);
        var entries = inherited.methods.?.iterator();
        while (entries.next()) |entry| try methods.put(self.arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    own: for (descriptor.properties) |property| {
        for (properties.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, property.name)) continue;
            existing.* = property;
            continue :own;
        }
        try properties.append(self.arena, property);
    }
    const own_traits_start = traits.items.len;
    for (info.traits) |trait| try self.collectTraitKeys(trait, &traits);
    for (info.declaration.methods) |method| {
        const method_key = try Resolver.methodKey(self.arena, key, method.name);
        if (method.override_span != null) {
            const replaced: ?[]const u8 = blk: {
                if (info.base) |base| {
                    if (self.structs.get(base).?.methods.?.get(method.name)) |found| break :blk found.key;
                    if (try self.abstractKey(base, method.name)) |abstract| break :blk abstract;
                }
                break :blk try self.traitMethodKey(traits.items, method.name);
            };
            if (replaced) |original| try self.overrides.put(self.arena, method_key, self.overrides.get(original) orelse original);
        }
        if (method.abstract_span != null) continue;
        try methods.put(self.arena, method.name, .{
            .key = try Resolver.methodKey(self.arena, key, method.name),
            .depth = descriptor.depth,
            .owner = descriptor.display_name,
        });
    }
    // Section 11.2: a trait's defaults fill in only what no class method,
    // inherited or not, and no field or property already supplies.
    for (traits.items[own_traits_start..]) |trait| {
        const trait_info = self.trait_infos.get(trait).?;
        for (trait_info.declaration.methods) |method| {
            if (method.abstract_span != null or Resolver.isPrivate(method.name) or methods.contains(method.name)) continue;
            try methods.put(self.arena, method.name, .{
                .key = try Resolver.methodKey(self.arena, trait, method.name),
                .depth = descriptor.depth,
                .owner = trait_info.display_name,
            });
        }
        property: for (trait_info.declaration.properties) |property| {
            if (property.getter.abstract_span != null or Resolver.isPrivate(property.name)) continue;
            for (descriptor.fields) |field| if (std.mem.eql(u8, field.name, property.name)) continue :property;
            for (properties.items) |existing| if (std.mem.eql(u8, existing.name, property.name)) continue :property;
            try properties.append(self.arena, .{
                .name = property.name,
                .getter = try Resolver.methodKey(self.arena, trait, property.name),
                .setter = if (property.setter != null) try Resolver.setterKey(self.arena, trait, property.name) else null,
                .depth = descriptor.depth,
                .owner = trait_info.display_name,
            });
        }
    }
    descriptor.properties = properties.items;
    descriptor.methods = methods;
    descriptor.traits = traits.items;
}

fn collectTraitKeys(self: *Interpreter, trait: []const u8, found: *std.ArrayList([]const u8)) RunError!void {
    for (found.items) |existing| if (std.mem.eql(u8, existing, trait)) return;
    try found.append(self.arena, trait);
    for (self.trait_infos.get(trait).?.traits) |next| try self.collectTraitKeys(next, found);
}

/// The key of the method `name` that one of `traits` declares, with or
/// without a body.
fn traitMethodKey(self: *Interpreter, traits: []const []const u8, name: []const u8) RunError!?[]const u8 {
    for (traits) |trait| {
        for (self.trait_infos.get(trait).?.declaration.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return try Resolver.methodKey(self.arena, trait, name);
        }
    }
    return null;
}

/// The key of the abstract method `name` that a class or one of its base
/// classes declares, which has no entry in a method table since it cannot run.
fn abstractKey(self: *Interpreter, key: []const u8, name: []const u8) RunError!?[]const u8 {
    var at: ?[]const u8 = key;
    while (at) |current| : (at = self.struct_infos.get(current).?.base) {
        for (self.struct_infos.get(current).?.declaration.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return try Resolver.methodKey(self.arena, current, name);
        }
    }
    return null;
}

/// Raises before the host stack runs out, whatever the shape of the program.
/// Called on every statement and expression, which between them are every
/// point where the evaluator recurses.
fn guardStack(self: *Interpreter, span: Source.Span) Error!void {
    const address = @frameAddress();
    const base = self.stack.base;
    const used = if (base > address) base - address else address - base;
    if (used <= self.stack.budget) return;

    const innermost = if (self.call_stack.items.len > 0)
        self.call_stack.items[self.call_stack.items.len - 1].function
    else
        return self.raise(
            span,
            "this is nested too deeply to run",
            "Break the expression or block into smaller named pieces.",
        );
    return self.raiseTooMuchRecursion(span, innermost, false);
}

// Statements.

fn executeAll(self: *Interpreter, statements: []const Ast.Statement) Error!void {
    if (self.scopes.items.len > 0) try self.hoistNestedFunctions(statements);
    for (statements) |statement| try self.execute(statement);
}

/// Section 7.1's nested functions, each a closure over the scopes in force as
/// the block begins, so it can be called anywhere in the block and sees what
/// the block declares, as a lambda would.
fn hoistNestedFunctions(self: *Interpreter, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| {
        if (statement.data != .function_declaration) continue;
        const function = statement.data.function_declaration;
        const key = self.facts.nested_keys.get(.{ .file = self.file, .start = function.name_span.start }).?;
        const captured = try self.gpa.dupe(*Environment, self.scopes.items);
        const closure = try self.heap.createClosure(.{ .named = key }, captured, self.file);
        const current = &self.scopes.items[self.scopes.items.len - 1].bindings;
        current.put(self.gpa, function.name, .{ .kind = .closure, .value = .{ .data = .{ .closure = closure } } }) catch |err| {
            self.heap.release(.{ .data = .{ .closure = closure } });
            return err;
        };
    }
}

/// Whether a pattern's names are being introduced or already exist.
const Unpack = enum { declare, assign, bind_loop };

/// Section 8.2's unpacking, which is one operation wherever it appears: a
/// declaration, an assignment, a `for` binding, or a block's parameter list.
/// The checker has already proved the arity matches.
fn unpackInto(self: *Interpreter, pattern: Ast.Pattern, value: Value, how: Unpack) Error!void {
    const items = value.data.tuple.items;
    for (pattern.positions, items) |position, item| {
        const name = switch (position) {
            .name => |name| name,
            .nested => |nested| {
                try self.unpackInto(nested.*, item, how);
                continue;
            },
        };
        // Section 8.2: `_` discards its position, so nothing holds it.
        if (std.mem.eql(u8, name.text, "_")) continue;

        switch (how) {
            .assign => {
                const slot = self.find(name.text).?;
                if (slot.changing) |method| return self.raiseChanging(name.span, name.text, method);
                const widened = widen(Heap.retain(item), slot.kind);
                if (slot.value) |old| self.heap.release(old);
                slot.value = widened;
            },
            .declare, .bind_loop => {
                const in_block = self.scopes.items.len > 0;
                const key = if (in_block) name.text else self.keyOf(name.text);
                const current = if (in_block)
                    &self.scopes.items[self.scopes.items.len - 1].bindings
                else
                    &self.module;
                const held = Heap.retain(item);
                current.put(if (in_block) self.gpa else self.arena, key, .{
                    .kind = held.kind(),
                    .value = held,
                }) catch |err| {
                    self.heap.release(held);
                    return err;
                };
            },
        }
    }
}

/// Section 6.1 gives every block its own scope, and a local declared inside does
/// not leak out.
fn executeBlock(self: *Interpreter, block: Ast.Block) Error!void {
    _ = try self.pushScope();
    defer self.popScope();
    try self.executeAll(block.statements);
}

fn pushScope(self: *Interpreter) Error!*Environment {
    const environment = if (self.spare_scopes.pop()) |recycled| blk: {
        self.heap.reuseEnvironment(recycled);
        break :blk recycled;
    } else try self.heap.createEnvironment();

    self.scopes.append(self.gpa, environment) catch |err| {
        self.heap.releaseEnvironment(environment);
        return err;
    };
    return environment;
}

/// Ends the innermost scope. A closure created inside it holds it, and then the
/// variables stay alive and keep changing with the closure; otherwise the table
/// is kept, emptied, for the next block.
fn popScope(self: *Interpreter) void {
    const environment = self.scopes.pop().?;
    if (environment.references > 1) {
        environment.references -= 1;
        return;
    }
    self.heap.recycleEnvironment(environment);
    self.spare_scopes.append(self.gpa, environment) catch {
        environment.bindings.deinit(self.gpa);
        self.gpa.destroy(environment);
    };
}

fn execute(self: *Interpreter, statement: Ast.Statement) Error!void {
    try self.guardStack(statement.span);

    switch (statement.data) {
        .expression => |expression| self.heap.release(try self.evaluate(expression)),

        .declaration => |declaration| {
            const initial: ?Value = if (declaration.initializer) |initializer|
                try self.evaluate(initializer)
            else
                null;

            // An annotation fixes the kind; otherwise it comes from the value,
            // which section 4.1 infers the type from.
            const kind: Value.Kind = if (declaration.annotation) |annotation|
                declaredKind(annotation)
            else if (initial) |value|
                value.kind()
            else
                .nothing;

            const in_block = self.scopes.items.len > 0;
            const current = if (in_block) &self.scopes.items[self.scopes.items.len - 1].bindings else &self.module;
            const name = if (in_block) declaration.name else self.keyOf(declaration.name);
            try current.put(if (in_block) self.gpa else self.arena, name, .{
                .kind = kind,
                .value = if (initial) |value| widen(value, kind) else null,
            });
        },

        .destructuring => |destructuring| {
            const value = try self.evaluate(destructuring.initializer);
            defer self.heap.release(value);
            try self.unpackInto(destructuring.pattern, value, .declare);
        },

        .destructuring_assignment => |assignment| {
            // Section 8.2: the complete right side is evaluated before any
            // destination changes, which is what makes a swap a swap.
            const value = try self.evaluate(assignment.value);
            defer self.heap.release(value);
            try self.unpackInto(assignment.pattern, value, .assign);
        },

        .assignment => |written| {
            // Section 10.4's `Player.count += 1`: `Player` and its first step
            // are one binding, found as `Player.count` (see the resolver).
            var assignment = written;
            if (self.facts.type_assignments.get(.{ .file = self.file, .start = written.name_span.start })) |name| {
                const first = written.steps[0].field;
                assignment.name = name;
                assignment.name_span = .{ .start = written.name_span.start, .end = first.span.end };
                assignment.steps = written.steps[1..];
            }
            if (assignment.steps.len > 0) return self.assignElement(assignment);
            // Reaching the destination first sets up its file or type before
            // the right side runs, just as reading it would.
            const found = try self.placeBinding(assignment.name, assignment.name_span);
            // Evaluating the right side can set up another file or type, whose
            // new bindings can grow the module table and move `found`. Nothing
            // is ever removed from that table, so an unchanged count means
            // nothing moved, and the common case pays for one lookup.
            const module_size = self.module.count();
            const value = if (assignment.operation) |operation| blk: {
                // Section 5.3 lowers a compound assignment through the same
                // operation as its binary form. The current value is read once.
                // Held while the right side runs, which could reassign the
                // same name through a function and release the old value.
                const current = Heap.retain(found.value orelse return self.raiseUnassigned(
                    assignment.name_span,
                    assignment.name,
                ));
                defer self.heap.release(current);
                const right = try self.evaluate(assignment.value);
                defer self.heap.release(right);
                break :blk try self.applyBinary(statement.span, operation, current, right);
            } else try self.evaluate(assignment.value);

            const slot = if (self.module.count() == module_size) found else self.placeBinding(assignment.name, assignment.name_span) catch |err| {
                self.heap.release(value);
                return err;
            };
            if (slot.value) |old| self.heap.release(old);
            slot.value = widen(value, slot.kind);
        },

        .conditional => |conditional| try self.executeConditional(conditional),
        .case_statement => |case| try self.executeCase(case),
        .while_loop => |loop| try self.executeWhile(loop),
        .for_loop => |loop| try self.executeFor(loop),
        .break_statement => return error.Broke,
        .continue_statement => return error.Continued,

        // Hoisted into `self.functions` before anything runs.
        .function_declaration => {},
        // A type declaration describes construction; executing it has no
        // runtime effect.
        .struct_declaration => {},

        .return_statement => |return_statement| {
            self.return_value = if (return_statement.value) |value|
                try self.evaluate(value)
            else
                Value.nothing;
            return error.Returned;
        },
        .raise_statement => |raised| {
            if (raised.value) |expression| {
                const value = try self.evaluate(expression);
                self.raised_value = value;
                const object = value.data.struct_value;
                const position = fieldPosition(object, "message").?;
                const message = object.fields[position].data.string.bytes;
                return self.raiseTyped(raised.keyword_span, value.typeName(), message, "Handle this error with `try` and `catch`, or correct the condition that raised it.");
            }
            self.raised_value = if (self.caught_value) |value| Heap.retain(value) else unreachable;
            self.failure = self.caught_failure;
            return error.Raised;
        },
        .assert_statement => |assertion| {
            return self.executeAssert(assertion);
        },
        .try_statement => |protected| try self.executeTry(protected),
    }
}

fn executeAssert(self: *Interpreter, assertion: Ast.Assert) Error!void {
    var actual_help: ?[]const u8 = null;
    const holds = if (assertion.condition.data == .comparison and assertion.condition.data.comparison.operators.len == 1 and assertion.condition.data.comparison.operators[0].isEquality()) blk: {
        const comparison = assertion.condition.data.comparison;
        const left = try self.evaluate(comparison.operands[0]);
        defer self.heap.release(left);
        const right = try self.evaluate(comparison.operands[1]);
        defer self.heap.release(right);
        const equal = try Value.equals(self.gpa, left, right);
        const result = equal == (comparison.operators[0] == .equal);
        if (!result) {
            const left_text = try self.displayAlloc(left);
            const right_text = try self.displayAlloc(right);
            actual_help = try std.fmt.allocPrint(self.arena, "Left was {s}; right was {s}.", .{ left_text, right_text });
        }
        break :blk result;
    } else try self.condition(assertion.condition);
    if (holds) return;

    const user_help = if (assertion.message) |message| blk: {
        const value = try self.evaluate(message);
        defer self.heap.release(value);
        break :blk value.data.string.bytes;
    } else null;
    const help = if (user_help) |written|
        if (actual_help) |actual| try std.fmt.allocPrint(self.arena, "{s} {s}", .{ written, actual }) else written
    else
        actual_help orelse "The condition was false.";
    const expression = self.files[self.file].source.text[assertion.condition.span.start..assertion.condition.span.end];
    const message = try std.fmt.allocPrint(self.arena, "assertion failed: `{s}`", .{expression});
    self.raised_value = try self.makeError(Resolver.preludeKey("AssertionError"), user_help orelse message);
    return self.raiseTyped(assertion.condition.span, "AssertionError", message, help);
}

fn displayAlloc(self: *Interpreter, value: Value) RunError![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(self.arena);
    value.write(&allocating.writer, true) catch return error.WriteFailed;
    return allocating.toOwnedSlice();
}

fn executeTry(self: *Interpreter, protected: Ast.Try) Error!void {
    var pending: ?Error = null;
    self.executeBlock(protected.body) catch |err| {
        pending = err;
    };

    const body_raised = if (pending) |err| err == error.Raised else false;
    if (body_raised) {
        const raised = self.raised_value.?;
        const original = self.failure.?;
        self.raised_value = null;
        self.failure = null;
        var handled = false;
        for (protected.catches) |caught| {
            const key = if (caught.annotation) |annotation| try self.typeKeyOf(annotation.name) else Resolver.preludeKey("Error");
            if (!raised.data.struct_value.descriptor.isOrExtends(key)) continue;
            handled = true;
            const previous_value = self.caught_value;
            const previous_failure = self.caught_failure;
            self.caught_value = raised;
            self.caught_failure = original;
            const environment = try self.pushScope();
            environment.bindings.put(self.gpa, caught.name, .{ .kind = .struct_value, .value = Heap.retain(raised) }) catch |err| {
                self.popScope();
                return err;
            };
            pending = null;
            self.executeAll(caught.body.statements) catch |err| {
                pending = err;
            };
            self.popScope();
            self.caught_value = previous_value;
            self.caught_failure = previous_failure;
            break;
        }
        if (!handled) {
            self.raised_value = raised;
            self.failure = original;
        } else self.heap.release(raised);
    }

    if (protected.finally_block) |cleanup| {
        const propagating_raised = if (pending) |previous| previous == error.Raised else false;
        const propagating_value = if (propagating_raised) self.raised_value else null;
        const propagating_failure = if (propagating_raised) self.failure else null;
        if (propagating_raised) {
            // Keep the original failure aside so cleanup can raise and handle
            // its own errors without overwriting or leaking the first value.
            self.raised_value = null;
            self.failure = null;
        }
        var cleanup_error: ?Error = null;
        self.executeBlock(cleanup) catch |err| {
            cleanup_error = err;
        };
        if (cleanup_error) |err| {
            if (propagating_value) |value| self.heap.release(value);
            if (pending) |previous| if (previous == error.Returned) {
                if (self.return_value) |value| self.heap.release(value);
                self.return_value = null;
            };
            if (propagating_raised and err == error.Raised) {
                if (propagating_failure) |earlier| {
                    const saved = try self.arena.create(Diagnostic);
                    saved.* = earlier;
                    self.failure.?.related = saved;
                }
            }
            return err;
        }
        if (propagating_raised) {
            self.raised_value = propagating_value;
            self.failure = propagating_failure;
        }
    }
    if (pending) |err| return err;
}

/// One step of a runtime path, evaluated from `Ast.Step`: an index carries the
/// value it was evaluated to and the span to blame if it is out of range or
/// missing, and a field carries only the name, since the checker has already
/// proved it exists.
const PlaceStep = union(enum) {
    index: struct { value: Value, span: Source.Span },
    field: []const u8,
};

/// `scores[i] = value`, `grid[i][j] += 1`, or `point.x = 1`.
///
/// Every step's index expression is evaluated first and then the value, left
/// to right as section 5.2 requires. Only then is the path walked, because
/// evaluating the value can change it: a function it calls can append to the
/// same list. Each container on the way down is made unique first, which is
/// copy-on-write: one another binding also holds is copied before anything in
/// it changes.
fn assignElement(self: *Interpreter, assignment: Ast.Assignment) Error!void {
    if (self.super_members.get(assignment.value)) |setter| return self.assignThroughSuper(assignment, setter);
    const steps = try self.gpa.alloc(PlaceStep, assignment.steps.len);
    defer {
        for (steps) |step| switch (step) {
            .index => |index| self.heap.release(index.value),
            .field => {},
        };
        self.gpa.free(steps);
    }
    var built: usize = 0;
    errdefer {
        // Only what was built so far is owned; the rest is undefined.
        for (steps[built..]) |*step| step.* = .{ .field = "" };
    }
    while (built < steps.len) : (built += 1) {
        steps[built] = switch (assignment.steps[built]) {
            .index => |expression| .{ .index = .{ .value = try self.evaluate(expression), .span = expression.span } },
            .field => |field| .{ .field = field.name },
        };
    }

    const value = if (assignment.operation) |operation| blk: {
        // Section 5.2: the current value is read once, before the right side,
        // and held while the right side runs, as for a plain name. Section
        // 14.1: a non-entry file initializes on first use, which this is,
        // exactly as a plain assignment already reaches before finding its
        // slot.
        const binding = try self.placeBinding(assignment.name, assignment.name_span);
        const current = try self.elementValue(assignment.target_span, &binding.value.?, steps);
        defer self.heap.release(current);
        const right = try self.evaluate(assignment.value);
        defer self.heap.release(right);
        break :blk try self.applyBinary(assignment.target_span, operation, current, right);
    } else try self.evaluate(assignment.value);

    // Found only now, after everything above has run: reading a getter or
    // evaluating the right side can initialize another file, which can move
    // module bindings. The root is taken out of its binding while it changes,
    // since a property's setter runs code that could otherwise reach it.
    const binding = self.placeBinding(assignment.name, assignment.name_span) catch |err| {
        self.heap.release(value);
        return err;
    };
    if (objectOnPath(binding.value.?, steps)) |in_object| {
        return self.storeInObject(assignment.target_span, in_object, value);
    }
    var root = binding.value.?;
    binding.value = null;
    // Only a setter runs code while the binding is taken, and it can only be
    // reached through a last field step; an index step names the binding.
    binding.changing = switch (assignment.steps[assignment.steps.len - 1]) {
        .field => |field| .{ .name = field.name, .setter = true },
        .index => .{ .name = assignment.name },
    };
    const stored = self.storeElement(assignment.target_span, &root, steps, value);
    const restored = self.find(assignment.name).?;
    restored.changing = null;
    restored.value = root;
    return stored;
}

/// Section 10.7's `super.size = value`, which runs the base class's setter on
/// the object, reading its getter first for a compound assignment.
fn assignThroughSuper(self: *Interpreter, assignment: Ast.Assignment, setter: []const u8) Error!void {
    const object = try self.evaluateName(assignment.value, "self", "self");
    defer self.heap.release(object);
    const value = if (assignment.operation) |operation| blk: {
        var reader = self.namedCallable(setter[0 .. setter.len - Resolver.setter_suffix.len]);
        reader.self_value = Heap.retain(object);
        const current = try self.invoke(assignment.target_span, reader, &.{});
        defer self.heap.release(current);
        const right = try self.evaluate(assignment.value);
        defer self.heap.release(right);
        break :blk try self.applyBinary(assignment.target_span, operation, current, right);
    } else try self.evaluate(assignment.value);
    var callable = self.namedCallable(setter);
    callable.self_value = Heap.retain(object);
    const arguments = [_]Value{value};
    self.heap.release(try self.invoke(assignment.target_span, callable, &arguments));
}

/// Section 10.1: the deepest class instance a path passes through, and the
/// steps that continue from it. What those steps reach lives in that object,
/// which is shared, so changing it changes the object where it is: nothing
/// before it on the path is copied, and no binding is taken while it changes.
const InObject = struct { object: Value, rest: []const PlaceStep };

/// Section 4.3's exclusivity, for a struct held in an object's field: a
/// changing method or setter reached through the object takes the field's
/// value out while it runs, as it takes a variable's, so that code reaching the
/// field another way meanwhile is an error rather than a change the call then
/// overwrites.
const TakenField = struct {
    object: *const Heap.StructValue,
    position: usize,
    change: Heap.Binding.Change,
};

/// Raises when the object field is taken by a running call.
fn requireFieldFree(self: *Interpreter, span: Source.Span, instance: *const Heap.StructValue, position: usize) Error!void {
    if (self.taken_fields.items.len == 0 or !instance.descriptor.class) return;
    for (self.taken_fields.items) |taken| {
        if (taken.object == instance and taken.position == position) {
            return self.raiseChanging(span, instance.descriptor.fields[position].name, taken.change);
        }
    }
}

/// Runs `callable`, a changing method or setter whose `self` is reached from
/// `object` through `rest`, with the object's field at `rest[0]` taken out
/// meanwhile, and stores what `self` holds at the end back. `callable` takes
/// over `arguments`.
fn changeInObject(
    self: *Interpreter,
    span: Source.Span,
    object: *Heap.StructValue,
    rest: []const PlaceStep,
    callable_in: Callable,
    arguments: []const Value,
    change: Heap.Binding.Change,
) Error!Value {
    var callable = callable_in;
    const position = fieldPosition(object, rest[0].field).?;
    self.requireFieldFree(span, object, position) catch |err| {
        for (arguments) |argument| self.heap.release(argument);
        return err;
    };
    var root = object.fields[position];
    object.fields[position] = Value.nothing;
    defer object.fields[position] = root;
    try self.taken_fields.append(self.gpa, .{ .object = object, .position = position, .change = change });
    defer _ = self.taken_fields.pop();

    if (rest.len == 1) {
        callable.self_value = root;
        root = Value.nothing;
    } else {
        callable.self_value = self.elementValue(span, &root, rest[1..]) catch |err| {
            for (arguments) |argument| self.heap.release(argument);
            return err;
        };
    }
    var changed: Value = Value.nothing;
    callable.self_out = &changed;
    const result = self.invoke(span, callable, arguments);
    if (rest.len == 1) {
        root = changed;
    } else {
        self.storeElement(span, &root, rest[1..], changed) catch |store_error| {
            if (result) |produced| self.heap.release(produced) else |_| {}
            return store_error;
        };
    }
    return try result;
}

fn objectOnPath(root: Value, steps: []const PlaceStep) ?InObject {
    var found: ?InObject = null;
    var at = root;
    for (steps, 0..) |step, position| {
        switch (at.data) {
            .struct_value => |instance| {
                if (instance.descriptor.class) found = .{ .object = at, .rest = steps[position..] };
                const name = switch (step) {
                    .field => |name| name,
                    .index => break,
                };
                at = instance.fields[fieldPosition(instance, name) orelse break];
            },
            .list => |list| {
                const index = switch (step) {
                    .index => |index| index,
                    .field => break,
                };
                const position_in_list = index.value.data.int;
                if (position_in_list < 0 or position_in_list >= list.items.items.len) break;
                at = list.items.items[@intCast(position_in_list)];
            },
            // A dictionary entry is looked up where it is changed.
            else => break,
        }
    }
    return found;
}

/// Stores `value` through the steps that continue from an object, taking over
/// one holder of it. A setter at the end runs on what the steps reach: an
/// object shares itself, and a struct inside one is taken out of the object's
/// field while the setter runs and stored back.
fn storeInObject(self: *Interpreter, span: Source.Span, in_object: InObject, value: Value) Error!void {
    var object = Heap.retain(in_object.object);
    defer self.heap.release(object);
    const rest = in_object.rest;
    const prefix = rest[0 .. rest.len - 1];
    const name = switch (rest[rest.len - 1]) {
        .field => |name| name,
        .index => return self.storeElement(span, &object, rest, value),
    };
    const owner = self.elementValue(span, &object, prefix) catch |err| {
        self.heap.release(value);
        return err;
    };
    const instance = owner.data.struct_value;
    if (fieldPosition(instance, name) != null) {
        self.heap.release(owner);
        return self.storeElement(span, &object, rest, value);
    }
    const property = self.propertyOf(span, instance, name) catch |err| {
        self.heap.release(owner);
        self.heap.release(value);
        return err;
    };
    var callable = self.namedCallable(property.setter.?);
    const arguments = [_]Value{value};
    if (instance.descriptor.class) {
        callable.self_value = owner;
        return self.heap.release(try self.invoke(span, callable, &arguments));
    }
    self.heap.release(owner);
    return self.heap.release(try self.changeInObject(span, object.data.struct_value, prefix, callable, &arguments, .{ .name = name, .setter = true }));
}

/// The position of `name` among a struct instance's fields, or null when it
/// is a computed property instead. The checker has proved it is one or the
/// other.
fn fieldPosition(instance: *const Heap.StructValue, name: []const u8) ?usize {
    for (instance.descriptor.fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, name)) return index;
    }
    return null;
}

/// Section 10.3's getter, run on a value that only lends itself to the call.
fn readProperty(self: *Interpreter, span: Source.Span, receiver: Value, name: []const u8) Error!Value {
    const property = try self.propertyOf(span, receiver.data.struct_value, name);
    var callable = self.namedCallable(property.getter);
    callable.self_value = Heap.retain(receiver);
    return self.invoke(span, callable, &.{});
}

/// What a compound assignment reads before it writes, held by the caller. A
/// dictionary entry that is not there has no value to add to, which is the one
/// place a bracket on a dictionary can fail. A computed property can only be
/// the last step (10.3), and its getter runs here.
fn elementValue(self: *Interpreter, span: Source.Span, root: *Value, steps: []const PlaceStep) Error!Value {
    var at = root.*;
    for (steps) |step| switch (step) {
        .field => |name| {
            const instance = at.data.struct_value;
            const position = fieldPosition(instance, name) orelse return self.readProperty(span, at, name);
            try self.requireFieldFree(span, instance, position);
            at = instance.fields[position];
        },
        .index => |index| {
            if (at.data == .map) {
                const map = at.data.map;
                const key = widen(Heap.retain(index.value), map.key_kind);
                defer self.heap.release(key);
                const hash = try self.hashKey(index.span, key);
                const entry = try Heap.lookupIn(self.gpa, map, hash, key) orelse
                    return self.raiseMissingKey(index.span, key);
                at = entry.value;
                continue;
            }
            const list = at.data.list;
            const position = try self.checkIndex(list, index.value.data.int, index.span);
            at = list.items.items[position];
        },
    };
    return Heap.retain(at);
}

/// Stores `value`, taking over one holder of it. Every container on the way is
/// made safe to change first, which is where section 8.1's value semantics is
/// enforced for structs and dictionaries as it already was for lists.
fn storeElement(self: *Interpreter, span: Source.Span, root: *Value, steps: []const PlaceStep, value: Value) Error!void {
    var slot = root;
    for (steps, 0..) |step, step_index| {
        const last = step_index + 1 == steps.len;

        switch (step) {
            .field => |name| {
                const position = fieldPosition(slot.data.struct_value, name) orelse
                    return self.storeProperty(span, slot, name, value);
                self.requireFieldFree(span, slot.data.struct_value, position) catch |err| {
                    self.heap.release(value);
                    return err;
                };
                const instance = try self.heap.uniqueStruct(slot);
                if (last) {
                    self.heap.release(instance.fields[position]);
                    instance.fields[position] = widen(value, instance.descriptor.fields[position].kind);
                    return;
                }
                slot = &instance.fields[position];
            },
            .index => |index| {
                if (slot.data == .map) {
                    const map = try self.heap.uniqueMap(slot);
                    // Section 4.4: a whole number written where a `Float` key
                    // belongs is stored as one, exactly as a value is.
                    // Without this the entry would print as `2` in a
                    // dictionary whose keys are `Float`.
                    const key = widen(Heap.retain(index.value), map.key_kind);
                    defer self.heap.release(key);
                    const hash = try self.hashKey(index.span, key);
                    if (last) {
                        // Section 8.3: this inserts or replaces, and never fails.
                        return self.heap.put(map, hash, Heap.retain(key), widen(value, map.value_kind));
                    }
                    const found = switch (try self.heap.locate(map, hash, key)) {
                        .entry => |found| found,
                        .vacancy => return self.raiseMissingKey(index.span, key),
                    };
                    slot = &map.entries.items[found].value;
                    continue;
                }

                const list = try self.heap.unique(slot);
                const position = try self.checkIndex(list, index.value.data.int, index.span);
                if (last) {
                    self.heap.release(list.items.items[position]);
                    list.items.items[position] = widen(value, list.element);
                    return;
                }
                slot = &list.items.items[position];
            },
        }
    }
}

/// Section 10.3's setter. Like a changing method, it gets the receiver taken
/// out of its slot and gives back what `self` holds when it ends.
fn storeProperty(self: *Interpreter, span: Source.Span, slot: *Value, name: []const u8, value: Value) Error!void {
    const property = self.propertyOf(span, slot.data.struct_value, name) catch |err| {
        self.heap.release(value);
        return err;
    };
    const receiver = slot.*;
    slot.* = Value.nothing;
    var changed: Value = Value.nothing;
    var callable = self.namedCallable(property.setter.?);
    callable.self_value = receiver;
    callable.self_out = &changed;
    const arguments = [_]Value{value};
    const result = self.invoke(span, callable, &arguments);
    slot.* = changed;
    self.heap.release(try result);
}

/// The slot a path of indices and fields reaches, for a method that changes
/// what it finds there. Every container on the way is made safe to change
/// first.
fn containerSlot(self: *Interpreter, span: Source.Span, root: *Value, steps: []const PlaceStep) Error!*Value {
    var slot = root;
    for (steps) |step| switch (step) {
        .field => |name| {
            const position = fieldPosition(slot.data.struct_value, name).?;
            try self.requireFieldFree(span, slot.data.struct_value, position);
            const instance = try self.heap.uniqueStruct(slot);
            slot = &instance.fields[position];
        },
        .index => |index| {
            if (slot.data == .map) {
                const map = try self.heap.uniqueMap(slot);
                const key = widen(Heap.retain(index.value), map.key_kind);
                defer self.heap.release(key);
                const hash = try self.hashKey(index.span, key);
                const found = switch (try self.heap.locate(map, hash, key)) {
                    .entry => |at| at,
                    .vacancy => return self.raiseMissingKey(index.span, key),
                };
                slot = &map.entries.items[found].value;
                continue;
            }
            const list = try self.heap.unique(slot);
            const position = try self.checkIndex(list, index.value.data.int, index.span);
            slot = &list.items.items[position];
        },
    };
    return slot;
}

fn raiseMissingKey(self: *Interpreter, span: Source.Span, key: Value) Error {
    var written: std.Io.Writer.Allocating = .init(self.arena);
    key.write(&written.writer, true) catch return error.OutOfMemory;
    return self.raiseFmt(
        span,
        "there is no entry for {s}",
        .{written.written()},
        "Put a value there first, as in `scores[key] = 0`, or check with `contains_key?(key)`.",
    );
}

/// Section 5.4: an index outside the list is an error that names the index and
/// the valid range.
fn checkIndex(self: *Interpreter, list: *const Heap.List, index: i64, span: Source.Span) Error!usize {
    const count = list.items.items.len;
    if (index >= 0 and index < count) return @intCast(index);
    if (count == 0) return self.raiseFmt(
        span,
        "index {d} is outside this list, which is empty",
        .{index},
        "Check `empty?()` before indexing, or add an element first.",
    );
    const help = try std.fmt.allocPrint(self.arena, "Valid indices are 0 through {d}.", .{count - 1});
    return self.raiseFmt(
        span,
        "index {d} is outside this list, which has {d} element{s}",
        .{ index, count, if (count == 1) "" else "s" },
        help,
    );
}

/// Section 6.4. Each pass through the body is a block of its own, so its locals
/// are fresh every time.
fn executeWhile(self: *Interpreter, loop: Ast.While) Error!void {
    while (try self.condition(loop.condition)) {
        self.executeBlock(loop.body) catch |err| switch (err) {
            error.Broke => return,
            error.Continued => continue,
            else => return err,
        };
    }
}

/// Section 6.4's counting loops: `a..b`, `a..<b`, `a.up_to(b)`, and
/// `a.down_to(b)`, with an optional `.step(n)` and `.reverse()`. Everything
/// is evaluated once, before the first iteration.
///
/// The loop stops by comparing with the last value it will visit rather than
/// by stepping past it, because stepping past either end of the `Int` range
/// would overflow. `Counting` keeps that last value exact.
fn executeFor(self: *Interpreter, loop: Ast.For) Error!void {
    if (!Checker.isCounting(loop.iterable)) return self.executeForList(loop);

    const counting = try self.evaluateCounting(loop.iterable) orelse return;
    var current = counting.first;
    while (try self.executeIteration(loop, .initInt(current))) {
        if (current == counting.last) return;
        // Cannot overflow: `last` is reachable from `current` in whole steps.
        current = if (counting.descending) current - counting.step else current + counting.step;
    }
}

/// A nonempty run of whole numbers: from `first` to `last`, both visited, `step`
/// apart, counting down when `descending`. `last` is always a value the count
/// actually reaches, which is what lets `reverse` swap the ends exactly.
const Counting = struct {
    first: i64,
    last: i64,
    step: i64 = 1,
    descending: bool,

    /// The last value reached from `first` in whole steps without passing
    /// `bound`, which the caller guarantees lies in the counting direction.
    fn reaching(first: i64, bound: i64, step: i64, descending: bool) Counting {
        const difference = @as(i128, bound) - first;
        const distance: i128 = if (difference < 0) -difference else difference;
        const whole = distance - @rem(distance, step);
        const last: i64 = @intCast(if (descending) @as(i128, first) - whole else @as(i128, first) + whole);
        return .{ .first = first, .last = last, .step = step, .descending = descending };
    }
};

/// Null for a count that visits nothing.
fn evaluateCounting(self: *Interpreter, expression: *const Ast.Expression) Error!?Counting {
    if (expression.data == .range) {
        const range = expression.data.range;
        const start = (try self.evaluate(range.start)).data.int;
        const end = (try self.evaluate(range.end)).data.int;
        if (range.inclusive) {
            return if (start > end) null else .{ .first = start, .last = end, .descending = false };
        }
        return if (start >= end) null else .{ .first = start, .last = end - 1, .descending = false };
    }

    const call = expression.data.call;
    const member = call.callee.data.member;
    const name = member.name;

    if (std.mem.eql(u8, name, "up_to") or std.mem.eql(u8, name, "down_to")) {
        const start = (try self.evaluate(member.base)).data.int;
        const end = (try self.evaluate(call.arguments[0])).data.int;
        // A target on the wrong side counts nothing, as `0..count - 1` does
        // for an empty list.
        const descending = std.mem.eql(u8, name, "down_to");
        if (if (descending) start < end else start > end) return null;
        return .{ .first = start, .last = end, .descending = descending };
    }

    const base = try self.evaluateCounting(member.base);

    if (std.mem.eql(u8, name, "reverse")) {
        const counting = base orelse return null;
        return .{
            .first = counting.last,
            .last = counting.first,
            .step = counting.step,
            .descending = !counting.descending,
        };
    }

    // `step`, evaluated even when the count is empty, so a bad step is always
    // reported.
    const distance = (try self.evaluate(call.arguments[0])).data.int;
    if (distance < 1) return self.raiseFmt(
        call.arguments[0].span,
        "a step must be at least 1, but this is {d}",
        .{distance},
        "The range says which way to count; the step says only how far, as in `10.down_to(0).step(2)`.",
    );
    const counting = base orelse return null;
    return Counting.reaching(counting.first, counting.last, distance, counting.descending);
}

/// Section 8.4: the loop visits the list as it was when the loop began. Holding
/// the buffer for the whole loop is what guarantees it: a change the body makes
/// through the list's own binding finds the buffer shared and copies it first.
fn executeForList(self: *Interpreter, loop: Ast.For) Error!void {
    const iterable = try self.evaluate(loop.iterable);
    defer self.heap.release(iterable);

    // Section 9.1: a string yields its characters, each a string of its own.
    if (iterable.data == .string) {
        var clusters: unicode.Graphemes = .init(iterable.data.string.bytes);
        while (clusters.next()) |cluster| {
            if (!try self.executeIteration(loop, try self.heap.copyText(cluster))) return;
        }
        return;
    }

    // Section 8.4: a dictionary or set is visited in insertion order, and the
    // loop sees the collection as it was when it began. The entries are copied
    // first, so changing the collection inside the body cannot move the ground
    // underneath the walk.
    if (iterable.data == .map) {
        const map = iterable.data.map;
        const entries = try self.gpa.dupe(Heap.Map.Entry, map.entries.items);
        defer self.gpa.free(entries);
        for (entries) |entry| {
            _ = Heap.retain(entry.key);
            _ = Heap.retain(entry.value);
        }
        // `pending` moves past an entry before anything consumes it, so a
        // `break` or an error releases exactly the ones still untouched.
        var pending: usize = 0;
        defer for (entries[pending..]) |entry| {
            self.heap.release(entry.key);
            self.heap.release(entry.value);
        };
        while (pending < entries.len) {
            const entry = entries[pending];
            pending += 1;
            // A set's value is `nothing`, which holds nothing to release.
            const item = if (map.is_set) entry.key else try self.entryTuple(map, entry);
            if (!try self.executeIteration(loop, item)) return;
        }
        return;
    }

    for (iterable.data.list.items.items) |item| {
        if (!try self.executeIteration(loop, Heap.retain(item))) return;
    }
}

/// Section 8.6's `(key, value)`, which is the one item a dictionary's block and
/// `for` loop receive. Takes over one holder of each half.
fn entryTuple(self: *Interpreter, map: *const Heap.Map, entry: Heap.Map.Entry) Error!Value {
    const items = try self.gpa.alloc(Value, 2);
    const kinds = self.gpa.alloc(Value.Kind, 2) catch |err| {
        self.gpa.free(items);
        return err;
    };
    items[0] = entry.key;
    items[1] = entry.value;
    kinds[0] = map.key_kind;
    kinds[1] = map.value_kind;
    errdefer {
        self.heap.release(entry.key);
        self.heap.release(entry.value);
    }
    return .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
}

/// One pass through a `for` body with the loop variable bound to `value`, in a
/// scope of its own, which is what makes the binding fresh every iteration.
/// `value` is owned: the binding takes it, and `_` releases it. False when a
/// `break` ended the loop.
fn executeIteration(self: *Interpreter, loop: Ast.For, value: Value) Error!bool {
    const scope = try self.pushScope();
    defer self.popScope();

    if (loop.pattern) |pattern| {
        defer self.heap.release(value);
        try self.unpackInto(pattern, value, .bind_loop);
    } else if (std.mem.eql(u8, loop.name, "_")) {
        self.heap.release(value);
    } else {
        scope.bindings.put(self.gpa, loop.name, .{ .kind = value.kind(), .value = value }) catch |err| {
            self.heap.release(value);
            return err;
        };
    }

    self.executeAll(loop.body.statements) catch |err| switch (err) {
        error.Broke => return false,
        error.Continued => {},
        else => return err,
    };
    return true;
}

/// Section 6.3: the arm a `case` runs, or null when none matches and it has
/// no `else`. The subject is evaluated once, and each alternative in order
/// until one matches.
fn chooseArm(self: *Interpreter, case: *const Ast.Case) Error!?Ast.Case.Body {
    const subject: ?Value = if (case.subject) |written| try self.evaluate(written) else null;
    defer if (subject) |value| self.heap.release(value);
    for (case.arms) |arm| {
        for (arm.alternatives) |alternative| {
            const matched = if (subject) |value| blk: {
                const candidate = try self.evaluate(alternative);
                defer self.heap.release(candidate);
                break :blk try Value.equals(self.gpa, value, candidate);
            } else try self.condition(alternative);
            if (matched) return arm.body;
        }
    }
    return case.otherwise;
}

fn executeCase(self: *Interpreter, case: *const Ast.Case) Error!void {
    const arm = try self.chooseArm(case) orelse return;
    try self.executeBlock(arm.block);
}

fn executeConditional(self: *Interpreter, conditional: Ast.If) Error!void {
    if (try self.condition(conditional.condition)) {
        return self.executeBlock(conditional.then_block);
    }
    if (conditional.otherwise) |otherwise| switch (otherwise) {
        .block => |block| return self.executeBlock(block),
        .chained => |chained| return self.execute(chained.*),
    };
}

/// Section 4.4: conditions require `Bool`. Values do not become truthy or falsey
/// implicitly, so a number here is an error rather than a silent coercion.
fn condition(self: *Interpreter, expression: *const Ast.Expression) Error!bool {
    const value = try self.evaluate(expression);
    return switch (value.data) {
        .bool => |result| result,
        else => self.raiseFmt(
            expression.span,
            "a condition must be a Bool, but this is {s}",
            .{value.typeName()},
            "Compare it to something, as in `count > 0`. Emerald has no truthy or falsey values.",
        ),
    };
}

/// Applies section 4.4's widening, which is the only implicit conversion in the
/// language. Anything else is already a type error the checker reported.
fn widen(value: Value, kind: Value.Kind) Value {
    if (kind != .float) return value;
    return switch (value.data) {
        .int => |number| .initFloat(@floatFromInt(number)),
        else => value,
    };
}

fn declaredKind(annotation: Ast.TypeExpression) Value.Kind {
    if (annotation.key != null or annotation.set) return .map;
    if (annotation.element != null) return .list;
    if (annotation.positions != null) return .tuple;
    if (annotation.signature != null) return .closure;
    return if (Type.fromName(annotation.name)) |builtin| kindOf(builtin) else .struct_value;
}

/// The runtime kind for a checked type. `.invalid` never reaches a program that
/// passed checking.
fn kindOf(checked: Type) Value.Kind {
    return switch (checked.kind) {
        .nothing, .invalid => .nothing,
        .bool => .bool,
        .int => .int,
        .float => .float,
        .string => .string,
        .range => .range,
        .list => .list,
        .tuple => .tuple,
        .dictionary, .set => .map,
        .function => .closure,
        .struct_value => .struct_value,
    };
}

/// The one name the whole program knows a module-level declaration by, as the
/// resolver worked it out for the file being executed. A local is its own key.
fn keyOf(self: *Interpreter, name: []const u8) []const u8 {
    return self.facts.keyFor(self.file, name) orelse name;
}

/// Resolves the same namespace alias at the front of a written type that the
/// checker resolved, such as `using E = Errors` followed by `catch e: E.Bad`.
fn typeKeyOf(self: *Interpreter, name: []const u8) RunError![]const u8 {
    if (self.facts.keyFor(self.file, name)) |key| return key;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    const namespace = self.facts.namespaceAliasFor(self.file, name[0..dot]) orelse return name;
    return std.fmt.allocPrint(self.arena, "{s}{s}", .{ namespace, name[dot..] });
}

fn find(self: *Interpreter, name: []const u8) ?*Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].bindings.getPtr(name)) |slot| return slot;
    }
    return self.module.getPtr(self.keyOf(name));
}

/// Section 14.1: a file that is not the entry initializes once, the first time
/// anything reaches one of its members. Called wherever a module-level key is
/// about to be read, assigned, or called.
fn reach(self: *Interpreter, key: []const u8, span: Source.Span) Error!void {
    // A type-level member belongs to its type, whose setup is separate from
    // its file's: the fields' values reach whatever they read themselves.
    if (self.facts.type_members.get(key)) |type_key| return self.setUpType(type_key, key, span);
    try self.reachFile(key, span);
    if (self.type_setups.contains(key)) try self.setUpType(key, null, span);
}

/// Section 10.4: "Type-level fields follow the same lazy rule, initializing
/// once in declaration order when the type is first constructed or a
/// type-level member is accessed." `member` is the member reached, or null
/// when the type is being constructed.
fn setUpType(self: *Interpreter, type_key: []const u8, member: ?[]const u8, span: Source.Span) Error!void {
    // Never added to while running, so this pointer stays put.
    const setup = self.type_setups.getPtr(type_key) orelse return;
    switch (setup.state) {
        .done => return,
        .pending => {},
        .running => {
            // Constructing the type, or calling one of its functions, while
            // its fields are set up is not a cycle; reading a field it has
            // not got to yet is.
            const reached = member orelse return;
            if (self.functions.contains(reached)) return;
            if (self.module.get(reached)) |slot| {
                // Taken by a changing method is not unset: the read raises
                // that instead.
                if (slot.value != null or slot.changing != null) return;
            }
            return self.raiseFmt(
                span,
                "`{s}` is still being set up, so `{s}` cannot be read yet",
                .{ setup.display_name, try Resolver.displayKey(self.arena, reached) },
                try std.fmt.allocPrint(
                    self.arena,
                    "Type-level fields are set up in the order they are declared. Declare `{s}` above the field whose value reaches it, or compute that value in a function instead.",
                    .{try Resolver.displayKey(self.arena, reached)},
                ),
            );
        },
        .failed => {
            if (setup.failed_value) |value| {
                self.raised_value = Heap.retain(value);
                self.failure = setup.failed_diagnostic;
                return error.Raised;
            }
            return self.raiseFmt(span, "`{s}` could not be set up", .{setup.display_name}, "An earlier error stopped it. Fix that first.");
        },
    }

    setup.state = .running;
    errdefer |setup_error| {
        setup.state = .failed;
        if (setup_error == error.Raised) {
            setup.failed_value = if (self.raised_value) |value| Heap.retain(value) else null;
            setup.failed_diagnostic = self.failure;
        }
    }
    try self.call_stack.append(self.gpa, .{
        .function = setup.frame_name,
        .call_span = span,
        .file = self.file,
        .named = false,
    });
    defer _ = self.call_stack.pop();
    const owner = self.facts.owner.get(type_key).?;
    const outer_file = self.file;
    const outer_scopes = self.scopes;
    self.file = owner;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
        self.file = outer_file;
    }

    for (setup.fields) |field| {
        const value = try self.evaluate(field.initializer);
        const kind: Value.Kind = if (field.annotation) |annotation| declaredKind(annotation) else value.kind();
        const key = try Resolver.methodKey(self.arena, type_key, field.name);
        self.module.put(self.arena, key, .{ .kind = kind, .value = widen(value, kind) }) catch {
            self.heap.release(value);
            return error.OutOfMemory;
        };
    }
    setup.state = .done;
}

fn reachFile(self: *Interpreter, key: []const u8, span: Source.Span) Error!void {
    const owner = self.facts.owner.get(key) orelse return;
    if (self.test_mode and self.files[owner].entry) {
        if (self.functions.contains(key) or self.structs.contains(key)) return;
        return self.initializeTestBinding(owner, key, span);
    }
    switch (self.module_states[owner]) {
        .done => return,
        .pending => return self.initializeModule(owner) catch |err| {
            self.module_states[owner] = .failed;
            if (err == error.Raised) {
                self.module_failed_values[owner] = if (self.raised_value) |value| Heap.retain(value) else null;
                self.module_failed_diagnostics[owner] = self.failure;
            }
            return err;
        },
        .running => {
            // Section 14.1's cycle is a cycle "reaching an unfinished
            // binding". Functions and struct types are hoisted, so reaching
            // either is never that, and a binding the file has already got to
            // is finished.
            if (self.functions.contains(key) or self.structs.contains(key)) return;
            if (self.module.get(key)) |slot| {
                // Taken by a changing method is not unset: the read raises
                // that instead.
                if (slot.value != null or slot.changing != null) return;
            }
            return self.raiseFmt(
                span,
                "`{s}` is still being set up, so `{s}` cannot be read yet",
                .{ self.files[owner].source.path, key },
                "Two values are waiting on each other. Break the cycle by moving one into a function, which runs when it is called rather than when the file is set up.",
            );
        },
        // A caught setup error leaves the module reachable again. Re-raise the
        // same value and source diagnostic on every later access.
        .failed => {
            if (self.module_failed_values[owner]) |value| {
                self.raised_value = Heap.retain(value);
                self.failure = self.module_failed_diagnostics[owner];
                return error.Raised;
            }
            return self.raiseFmt(span, "`{s}` could not be set up", .{self.files[owner].source.path}, "An earlier error stopped it. Fix that first.");
        },
    }
}

/// Test mode gives each entry-file binding its own lazy state. Application
/// statements never run, and reaching one binding does not trigger unrelated
/// initializers with side effects.
fn initializeTestBinding(self: *Interpreter, file: u32, key: []const u8, span: Source.Span) Error!void {
    switch (self.test_binding_states.get(key) orelse .pending) {
        .done => return,
        .running => return self.raiseFmt(span, "`{s}` is still being initialized", .{key}, "Two entry-file values are waiting on each other. Move one computation into a function to break the cycle."),
        .failed => {
            const failed = self.test_binding_failures.get(key).?;
            self.raised_value = Heap.retain(failed.value);
            self.failure = failed.diagnostic;
            return error.Raised;
        },
        .pending => {},
    }

    const outer_file = self.file;
    const outer_scopes = self.scopes;
    self.file = file;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
        self.file = outer_file;
    }
    for (self.programs[file].statements) |statement| {
        if (!self.statementDeclaresKey(statement, key)) continue;
        // One destructuring declaration has one initializer. All of its names
        // begin, finish, or fail together, just as they do in ordinary mode.
        try self.markTestBindingStates(statement, file, .running);
        self.execute(statement) catch |err| {
            if (err == error.Raised) try self.markTestBindingsFailed(statement, file, self.raised_value.?, self.failure.?);
            return err;
        };
        try self.markTestBindingStates(statement, file, .done);
        return;
    }
}

fn statementDeclaresKey(self: *Interpreter, statement: Ast.Statement, key: []const u8) bool {
    return switch (statement.data) {
        .declaration => |declaration| std.mem.eql(u8, self.facts.keyFor(self.file, declaration.name) orelse declaration.name, key),
        .destructuring => |destructuring| blk: {
            for (destructuring.pattern.names) |name| if (std.mem.eql(u8, self.facts.keyFor(self.file, name.text) orelse name.text, key)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn markTestBindingStates(self: *Interpreter, statement: Ast.Statement, file: u32, state: ModuleState) RunError!void {
    switch (statement.data) {
        .declaration => |declaration| try self.test_binding_states.put(self.arena, self.facts.keyFor(file, declaration.name) orelse declaration.name, state),
        .destructuring => |destructuring| for (destructuring.pattern.names) |name| try self.test_binding_states.put(self.arena, self.facts.keyFor(file, name.text) orelse name.text, state),
        else => unreachable,
    }
}

fn markTestBindingsFailed(self: *Interpreter, statement: Ast.Statement, file: u32, value: Value, diagnostic: Diagnostic) RunError!void {
    switch (statement.data) {
        .declaration => |declaration| try self.markTestBindingFailed(self.facts.keyFor(file, declaration.name) orelse declaration.name, value, diagnostic),
        .destructuring => |destructuring| for (destructuring.pattern.names) |name| try self.markTestBindingFailed(self.facts.keyFor(file, name.text) orelse name.text, value, diagnostic),
        else => unreachable,
    }
}

fn markTestBindingFailed(self: *Interpreter, key: []const u8, value: Value, diagnostic: Diagnostic) RunError!void {
    try self.test_binding_states.put(self.arena, key, .failed);
    try self.test_binding_failures.put(self.arena, key, .{ .value = Heap.retain(value), .diagnostic = diagnostic });
}

/// Section 14.1: the file's module-level bindings, in declaration order, run
/// once. Only `reach` calls this, and only for a file that has not started.
fn initializeModule(self: *Interpreter, file: u32) Error!void {
    self.module_states[file] = .running;

    // Its declarations run against the module scope alone, in the file they
    // were written in, whatever was executing when they were reached.
    const outer_file = self.file;
    const outer_scopes = self.scopes;
    self.file = file;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
        self.file = outer_file;
    }

    // Declaration order, which is the order section 14.1 gives them.
    for (self.programs[file].statements) |statement| {
        switch (statement.data) {
            .declaration, .destructuring => try self.execute(statement),
            else => {},
        }
    }

    self.module_states[file] = .done;
}

// Expressions.

fn evaluate(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    try self.guardStack(expression.span);

    return switch (expression.data) {
        .int_literal => |value| .initInt(value),
        .float_literal => |value| .initFloat(value),
        .bool_literal => |value| .initBool(value),
        .nothing_literal => Value.nothing,
        // Reading a name makes a new holder of what it holds.
        // Section 10.7's `super` is the object itself; only which version of
        // a member it reaches differs, and that is decided where it is used.
        .name => |name| if (std.mem.eql(u8, name, "super"))
            self.evaluateName(expression, "self", "self")
        else
            self.evaluateName(expression, self.keyOf(name), name),
        .unary => |unary| self.evaluateUnary(expression, unary),
        .binary => |binary| self.evaluateBinary(expression, binary),
        .logical => |logical| self.evaluateLogical(logical),
        .comparison => |comparison| self.evaluateComparison(expression, comparison),
        .call => |call| self.evaluateCall(expression, call),
        .range => |range| blk: {
            const start = (try self.evaluate(range.start)).data.int;
            const end = (try self.evaluate(range.end)).data.int;
            break :blk .{ .data = .{ .range = Range.fromBounds(start, end, range.inclusive) } };
        },
        .list_literal => |elements| self.evaluateList(expression, elements),
        .dictionary_literal => |entries| self.evaluateDictionary(expression, entries),
        .tuple_literal => |positions| self.evaluateTuple(expression, positions),
        .index => |index| self.evaluateIndex(expression, index),
        // A namespace-qualified name is a reference, not a property access.
        .member => |member| self.evaluateMember(expression, member),
        .string_literal => |bytes| self.evaluateStringLiteral(expression, bytes),
        .interpolation => |parts| self.evaluateInterpolation(parts),
        .type_test, .lambda, .enum_value, .case_expression => self.evaluateByNode(expression),
    };
}

/// Keeps qualified built-ins and ordinary property dispatch out of
/// `evaluate`'s recursion-sensitive stack frame.
fn evaluateMember(self: *Interpreter, expression: *const Ast.Expression, member: Ast.Expression.Member) Error!Value {
    if (self.facts.qualified.get(expression)) |key| {
        if (std.mem.eql(u8, key, Resolver.float_infinity_key)) return .initFloat(std.math.inf(f64));
        if (std.mem.eql(u8, key, Resolver.float_nan_key)) return .initFloat(std.math.nan(f64));
        return self.evaluateName(expression, key, key);
    }
    return self.evaluateProperty(expression, member);
}

/// The expressions whose helpers need only the node, sharing one call site:
/// each call site in `evaluate` adds to its frame, which every level of a
/// deeply nested expression pays for (see the test of 1,000 calls at 250
/// levels).
fn evaluateByNode(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    return switch (expression.data) {
        .type_test => self.evaluateTypeTest(expression),
        .lambda => self.evaluateLambda(expression),
        .enum_value => self.evaluateEnumValue(expression),
        .case_expression => |case| blk: {
            const arm = try self.chooseArm(case) orelse unreachable;
            // An `Int` arm of a `case` that gives `Float` gives a `Float` (4.4).
            const value = try self.evaluate(arm.value);
            break :blk widen(value, kindOf(self.literal_types.get(expression).?));
        },
        else => unreachable,
    };
}

/// Section 12's enum value, built once as its enum's type-level fields are set
/// up.
fn evaluateEnumValue(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    const value = expression.data.enum_value;
    const instance = try self.heap.createStruct(self.structs.get(self.keyOf(value.type_name)).?, &.{});
    instance.variant = value.index;
    return .{ .data = .{ .struct_value = instance } };
}

/// Section 7.4: a lambda captures the scopes it can see, not copies of what
/// they hold, so a closure and the block around it keep sharing every variable.
/// The module is not captured because it is visible from everywhere anyway.
fn evaluateLambda(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    const captured = try self.gpa.dupe(*Environment, self.scopes.items);
    // A block can be passed to another file and called there, so it remembers
    // where it was written: that is what its bare module-level names mean.
    return .{ .data = .{
        .closure = try self.heap.createClosure(.{ .lambda = expression }, captured, self.file),
    } };
}

/// A name read for its value, whether it was written bare or qualified.
/// `key` is what the program calls it; `written` is what the reader typed, so a
/// diagnostic echoes that back.
fn evaluateName(
    self: *Interpreter,
    expression: *const Ast.Expression,
    key: []const u8,
    written: []const u8,
) Error!Value {
    try self.reach(key, expression.span);
    if (self.find(written)) |slot| {
        if (slot.value) |value| return Heap.retain(value);
        if (slot.changing) |method| return self.raiseChanging(expression.span, written, method);
        return self.raiseUnassigned(expression.span, written);
    }
    if (self.module.getPtr(key)) |slot| {
        if (slot.value) |value| return Heap.retain(value);
        return self.raiseUnassigned(expression.span, written);
    }
    // Section 7.5: a bare function name is its callable value.
    if (self.functions.contains(key)) return self.evaluateFunctionValue(key);
    // The checker proves every name read here is bound and assigned, so this is
    // a safety net rather than a language rule.
    return self.raiseUnassigned(expression.span, written);
}

/// Section 7.5's captured named function, which captures nothing: a named
/// function's body can only see the module, which is always visible.
fn evaluateFunctionValue(self: *Interpreter, name: []const u8) Error!Value {
    const captured = try self.gpa.alloc(*Environment, 0);
    return .{ .data = .{ .closure = try self.heap.createClosure(.{ .named = name }, captured, self.file) } };
}

/// Section 7.5's captured method: a closure holding its own copy of the
/// receiver, exactly as if the receiver had been copied into a local first.
fn evaluateMethodValue(self: *Interpreter, member: Ast.Expression.Member, key: []const u8) Error!Value {
    const receiver = try self.evaluate(member.base);
    // Section 10.7: the version the object's own class runs, decided now.
    // Taking it runs nothing, so whether that class's part is built yet is
    // checked when the method is called.
    const version = if (isSuper(member.base)) key else if (versionOf(receiver, key)) |method| method.key else key;
    const captured = self.gpa.alloc(*Environment, 0) catch |err| {
        self.heap.release(receiver);
        return err;
    };
    const closure = self.heap.createClosure(.{ .method = version }, captured, self.file) catch |err| {
        self.heap.release(receiver);
        return err;
    };
    closure.receiver = receiver;
    return .{ .data = .{ .closure = closure } };
}

/// Section 4.4's `value is Type`. The value is evaluated once, whatever the
/// checker already knows about the answer.
fn evaluateTypeTest(self: *Interpreter, expression: *const Ast.Expression) Error!Value {
    const value = try self.evaluate(expression.data.type_test.value);
    defer self.heap.release(value);
    const tested = self.type_tests.get(expression).?;
    return .initBool(valueIs(value, tested.value, tested.target));
}

/// Whether a value whose static type is `static` has the type `target`. A
/// value's static type is exact apart from objects, whose class may extend
/// the one it has, and tuples holding them, which widen position by position.
fn valueIs(value: Value, static: Type, target: Type) bool {
    if (value.data == .nothing) return target.kind == .nothing;
    const present = static.payload();
    return switch (target.kind) {
        .nothing => false,
        .struct_value => value.data == .struct_value and value.data.struct_value.descriptor.isOrExtends(target.user.?.name),
        .tuple => blk: {
            if (value.data != .tuple or present.kind != .tuple) break :blk false;
            const items = value.data.tuple.items;
            if (items.len != target.elements.len) break :blk false;
            for (items, present.elements, target.elements) |item, item_static, item_target| {
                if (!valueIs(item, item_static, item_target)) break :blk false;
            }
            break :blk true;
        },
        else => present.same(target),
    };
}

/// Section 4.4's `type_name`: the source spelling of the value's own type.
fn evaluateTypeName(self: *Interpreter, member: Ast.Expression.Member, static: Type) Error!Value {
    const value = try self.evaluate(member.base);
    defer self.heap.release(value);
    var written: std.Io.Writer.Allocating = .init(self.gpa);
    defer written.deinit();
    writeTypeName(&written.writer, value, static) catch return error.OutOfMemory;
    return self.heap.copyText(written.written());
}

fn writeTypeName(writer: *std.Io.Writer, value: Value, static: Type) std.Io.Writer.Error!void {
    if (value.data == .nothing) return writer.writeAll("Nothing");
    const present = static.payload();
    switch (value.data) {
        .struct_value => |object| return writer.writeAll(object.descriptor.display_name),
        .tuple => |tuple| if (present.kind == .tuple) {
            try writer.writeAll("(");
            for (tuple.items, present.elements, 0..) |item, item_static, position| {
                if (position != 0) try writer.writeAll(", ");
                try writeTypeName(writer, item, item_static);
            }
            return writer.writeAll(")");
        },
        else => {},
    }
    try writer.print("{f}", .{present});
}

// Every case of `evaluate` that needs locals of its own lives in a function
// like these. `evaluate` runs once per level of nesting, so every byte of its
// frame is multiplied by section 7.2's 1,000 calls times the deepest nesting
// section 3.4 allows, and a Debug build gives each local its own slot.

/// Section 8.5's properties: `count`, and a list's `first` and `last`. The
/// checker allows nothing else here.
fn evaluateProperty(self: *Interpreter, expression: *const Ast.Expression, member: Ast.Expression.Member) Error!Value {
    if (self.type_names.get(expression)) |static| return self.evaluateTypeName(member, static);
    if (self.method_calls.get(expression)) |key| return self.evaluateMethodValue(member, key);
    // Section 10.7's `super.area`, which runs the base class's getter.
    if (self.super_members.get(expression)) |getter| {
        var callable = self.namedCallable(getter);
        callable.self_value = try self.evaluate(member.base);
        return self.invoke(member.name_span, callable, &.{});
    }
    const base = try self.evaluate(member.base);
    defer self.heap.release(base);

    // Section 8.2's `entry.0`. The checker has proved the position exists, so
    // there is nothing to fail here.
    if (member.position) |position| {
        return Heap.retain(base.data.tuple.items[position]);
    }

    if (base.data == .struct_value) {
        const instance = base.data.struct_value;
        const position = fieldPosition(instance, member.name) orelse
            return self.readProperty(member.name_span, base, member.name);
        try self.requireFieldFree(member.name_span, instance, position);
        return Heap.retain(instance.fields[position]);
    }

    if (base.data == .string) {
        // Section 9.2: a string's count is its characters, not its bytes.
        return .initInt(@intCast(unicode.graphemeCount(base.data.string.bytes)));
    }

    // Section 8.5: `count` is the only property a dictionary or set has.
    if (base.data == .map) return .initInt(@intCast(base.data.map.count()));
    if (base.data == .range) {
        if (std.mem.eql(u8, member.name, "count")) return .initInt(base.data.range.count());
        if (std.mem.eql(u8, member.name, "empty?")) return .initBool(base.data.range.empty());
    }

    const items = base.data.list.items.items;
    if (std.mem.eql(u8, member.name, "count")) return .initInt(@intCast(items.len));
    // Section 4.5: absent rather than an error, because an empty list has no
    // first element to name. `empty?` is the companion that tells the two apart.
    if (items.len == 0) return Value.nothing;
    return Heap.retain(if (std.mem.eql(u8, member.name, "first")) items[0] else items[items.len - 1]);
}

fn evaluateStringLiteral(self: *Interpreter, expression: *const Ast.Expression, bytes: []const u8) Error!Value {
    const cached = try self.literal_texts.getOrPut(self.gpa, expression);
    if (!cached.found_existing) cached.value_ptr.* = try self.heap.literalText(bytes);
    return .{ .data = .{ .string = cached.value_ptr.* } };
}

/// Section 5.1: each interpolated value appears as `print` would display it.
fn evaluateInterpolation(self: *Interpreter, parts: []const Ast.Expression.Part) Error!Value {
    var built: std.Io.Writer.Allocating = .init(self.gpa);
    defer built.deinit();
    for (parts) |part| switch (part) {
        .text => |bytes| try built.writer.writeAll(bytes),
        .expression => |part_expression| {
            const value = try self.evaluate(part_expression);
            defer self.heap.release(value);
            try value.display(&built.writer);
        },
    };
    return .{ .data = .{ .string = try self.heap.createText(try built.toOwnedSlice()) } };
}

/// Section 8.2. The checker recorded the literal's type, which says whether
/// whole numbers in it are to be stored as `Float`s.
/// Section 8.2's `["Ava": 12]`. A duplicate key that only shows up at runtime
/// keeps its position and takes the later value (8.4), which is what `put`
/// already does.
fn evaluateDictionary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    entries: []const Ast.Expression.Entry,
) Error!Value {
    const checked = self.literal_types.get(expression).?;
    const key_kind = kindOf(checked.key.?.*);
    const value_kind = kindOf(checked.element.?.*);

    const map = try self.heap.createMap(key_kind, value_kind, false);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (entries) |entry| {
        const key = widen(try self.evaluate(entry.key), key_kind);
        const hash = try self.hashKey(entry.key.span, key);
        const value = widen(try self.evaluate(entry.value), value_kind);
        try self.heap.put(map, hash, key, value);
    }
    return result;
}

/// Section 8.3: NaN is rejected as a key, directly or inside a tuple, because
/// it is not equal to itself and so could never be found again.
fn hashKey(self: *Interpreter, span: Source.Span, key: Value) Error!u64 {
    if (holdsNan(key)) return self.raise(
        span,
        "a not-a-number value cannot be a key",
        "`nan?` is never equal to anything, including itself, so nothing stored under it could be found again.",
    );
    return Value.hash(self.gpa, key);
}

fn holdsNan(value: Value) bool {
    return switch (value.data) {
        .float => |number| std.math.isNan(number),
        .tuple => |tuple| blk: {
            for (tuple.items) |item| {
                if (holdsNan(item)) break :blk true;
            }
            break :blk false;
        },
        .struct_value => |instance| blk: {
            for (instance.fields) |field| {
                if (holdsNan(field)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn evaluateList(self: *Interpreter, expression: *const Ast.Expression, elements: []const *const Ast.Expression) Error!Value {
    const checked = self.literal_types.get(expression).?;

    // Section 8.2: the same bracketed elements are a set where a set was
    // expected, and an empty `[]` is whichever of the three was.
    if (checked.kind == .set or checked.kind == .dictionary) {
        return self.evaluateSet(elements, checked);
    }

    const element = kindOf(checked.element.?.*);

    const list = try self.heap.createList(element, elements.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (elements) |item| list.items.appendAssumeCapacity(widen(try self.evaluate(item), element));
    return result;
}

/// Section 8.2's `("score", 10)`. The checker recorded the position types, so a
/// whole number written where a `Float` was expected is stored as one, exactly
/// as a list literal's elements are.
fn evaluateTuple(
    self: *Interpreter,
    expression: *const Ast.Expression,
    positions: []const *const Ast.Expression,
) Error!Value {
    const checked = self.literal_types.get(expression).?;

    const items = try self.gpa.alloc(Value, positions.len);
    const kinds = self.gpa.alloc(Value.Kind, positions.len) catch |err| {
        self.gpa.free(items);
        return err;
    };
    for (kinds, checked.elements) |*slot, element| slot.* = kindOf(element);

    // Filled one at a time, so a failure part-way releases only what is built.
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| self.heap.release(item);
        self.gpa.free(items);
        self.gpa.free(kinds);
    }
    while (built < positions.len) : (built += 1) {
        items[built] = widen(try self.evaluate(positions[built]), kinds[built]);
    }

    return .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
}

/// A bracketed literal the checker decided was a set, or an empty one it
/// decided was a set or a dictionary.
fn evaluateSet(
    self: *Interpreter,
    elements: []const *const Ast.Expression,
    checked: Type,
) Error!Value {
    const set = checked.kind == .set;
    const member_kind = kindOf(checked.element.?.*);
    const map = try self.heap.createMap(
        if (set) member_kind else kindOf(checked.key.?.*),
        if (set) .nothing else member_kind,
        set,
    );
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (elements) |element| {
        const member = widen(try self.evaluate(element), member_kind);
        const hash = try self.hashKey(element.span, member);
        try self.heap.put(map, hash, member, Value.nothing);
    }
    return result;
}

fn evaluateIndex(self: *Interpreter, expression: *const Ast.Expression, index: Ast.Expression.Index) Error!Value {
    const base = try self.evaluate(index.base);
    defer self.heap.release(base);

    // Section 8.3: a dictionary lookup can miss, and reports that as absence
    // rather than as an error, which is what makes `.or(0)` the natural reply.
    if (base.data == .map) {
        const map = base.data.map;
        const key = widen(try self.evaluate(index.index), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(index.index.span, key);
        const entry = try Heap.lookupIn(self.gpa, map, hash, key) orelse return Value.nothing;
        return Heap.retain(entry.value);
    }

    const position = (try self.evaluate(index.index)).data.int;
    if (base.data == .string) return self.characterAt(expression.span, base.data.string.bytes, position);
    const list = base.data.list;
    const at = try self.checkIndex(list, position, expression.span);
    return Heap.retain(list.items.items[at]);
}

/// Section 9.1: indexing a string counts characters, from zero.
fn characterAt(self: *Interpreter, span: Source.Span, bytes: []const u8, position: i64) Error!Value {
    if (strings.characterAt(bytes, position)) |character| return self.heap.copyText(character);
    const count = unicode.graphemeCount(bytes);
    if (count == 0) return self.raiseFmt(
        span,
        "index {d} is outside this String, which is empty",
        .{position},
        "Check `empty?()` before indexing.",
    );
    const help = try std.fmt.allocPrint(self.arena, "Valid indices are 0 through {d}.", .{count - 1});
    return self.raiseFmt(
        span,
        "index {d} is outside this String, which has {d} character{s}",
        .{ position, count, if (count == 1) "" else "s" },
        help,
    );
}

/// Section 5.2's `and` and `or`, which short-circuit: the right side is not
/// evaluated when the left already decides the answer.
fn evaluateLogical(self: *Interpreter, logical: Ast.Expression.Logical) Error!Value {
    const left = try self.condition(logical.left);
    const decided = switch (logical.operator) {
        .conjunction => !left,
        .disjunction => left,
    };
    if (decided) return .initBool(left);
    return .initBool(try self.condition(logical.right));
}

/// A comparison chain such as `0 <= score <= 100`.
///
/// Section 5.2 requires each operand to be evaluated once and the chain to
/// short-circuit as if joined by `and`. Carrying the previous value forward
/// gives both: `score` is evaluated once even though two comparisons use it, and
/// a false link returns before the next operand is touched.
fn evaluateComparison(
    self: *Interpreter,
    expression: *const Ast.Expression,
    comparison: Ast.Expression.Comparison,
) Error!Value {
    // Each operand is released once the comparison after it is decided. The
    // `defer` reads `left` when it runs, so it releases whichever is current.
    var left = try self.evaluate(comparison.operands[0]);
    defer self.heap.release(left);

    for (comparison.operators, comparison.operands[1..]) |operator, operand_node| {
        const right = try self.evaluate(operand_node);

        const holds = if (operator.isEquality())
            (try Value.equals(self.gpa, left, right)) == (operator == .equal)
        else if (left.data == .struct_value) ordered: {
            // Section 11.5: `a < b` is `a.compare(b) < 0`.
            const result = try self.callOperator(expression.span, Ast.OperatorContract.ordered.method, left, right);
            break :ordered operator.holds(std.math.order(result.data.int, 0));
        } else if (left.data == .string and right.data == .string)
            // Section 9.2: by the code points of the normalized forms.
            operator.holds(try unicode.order(self.gpa, left.data.string.bytes, right.data.string.bytes))
        else if (Value.order(left, right)) |ordering|
            operator.holds(ordering)
        else if (left.isNumber() and right.isNumber())
            // Unordered means a NaN is involved. Section 5.3 keeps IEEE
            // behavior, under which every comparison is false except `!=`.
            operator == .not_equal
        else
            return self.raiseFmt(
                expression.span,
                "{s} and {s} cannot be compared",
                .{ left.typeName(), right.typeName() },
                "Comparison needs two values of the same kind.",
            );

        self.heap.release(left);
        left = right;
        if (!holds) return .initBool(false);
    }

    return .initBool(true);
}

fn evaluateUnary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    unary: Ast.Expression.Unary,
) Error!Value {
    const operand = try self.evaluate(unary.operand);
    switch (unary.operator) {
        .negate => switch (operand.data) {
            // Negating the minimum `Int` overflows like any other operation,
            // because the range is asymmetric.
            .int => |value| {
                const result = @subWithOverflow(@as(i64, 0), value);
                if (result[1] != 0) return self.raiseFmt(
                    expression.span,
                    "negating {d} overflows Int",
                    .{value},
                    integer_range_help,
                );
                return .initInt(result[0]);
            },
            .float => |value| return .initFloat(-value),
            .nothing, .bool, .string, .range, .list, .tuple, .map, .closure, .struct_value => return self.raiseFmt(
                expression.span,
                "`-` needs a number, but this is {s}",
                .{operand.typeName()},
                "Use `not` to invert a Bool.",
            ),
        },
        .not => switch (operand.data) {
            .bool => |value| return .initBool(!value),
            else => return self.raiseFmt(
                expression.span,
                "`not` needs a Bool, but this is {s}",
                .{operand.typeName()},
                "Compare it to something first, as in `not (count > 0)`.",
            ),
        },
    }
}

fn evaluateBinary(
    self: *Interpreter,
    expression: *const Ast.Expression,
    binary: Ast.Expression.Binary,
) Error!Value {
    // Section 5.2 evaluates ordered expression lists left to right.
    const left = try self.evaluate(binary.left);
    defer self.heap.release(left);
    const right = try self.evaluate(binary.right);
    defer self.heap.release(right);
    return self.applyBinary(expression.span, binary.operator, left, right);
}

/// Shared by binary expressions and compound assignment, which section 5.3
/// lowers through the same operation.
fn applyBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: Value,
    right: Value,
) Error!Value {
    // `+` joins two strings into a new one. The operands stay the caller's to
    // release: compound assignment passes a binding's value without retaining.
    if (left.data == .string and right.data == .string) {
        const joined = try std.mem.concat(self.gpa, u8, &.{ left.data.string.bytes, right.data.string.bytes });
        return .{ .data = .{ .string = try self.heap.createText(joined) } };
    }
    if (left.data == .struct_value) {
        if (operator.contract()) |contract| return self.callOperator(span, contract.method, left, right);
    }
    if (!left.isNumber() or !right.isNumber()) return self.raiseFmt(
        span,
        "{s} needs numbers, but this is {s} and {s}",
        .{ operator.describe(), left.typeName(), right.typeName() },
        "Arithmetic works on Int and Float.",
    );

    // This one always produces a Float regardless of operand types.
    if (operator == .divide) {
        const divisor = toFloat(right);
        if (divisor == 0) return self.raiseDivisionByZero(span, operator);
        return .initFloat(toFloat(left) / divisor);
    }

    const both_int = left.data == .int and right.data == .int;
    if (!both_int) return self.evaluateFloatBinary(span, operator, toFloat(left), toFloat(right));

    return self.evaluateIntBinary(span, operator, left.data.int, right.data.int);
}

/// Section 11.5: an operator on a value of a user type runs the method its
/// trait names, on the left operand and with the right one as the argument.
/// The checker has made sure the method leaves a struct operand as it is, and
/// the operands stay the caller's, as they do for numbers.
fn callOperator(self: *Interpreter, span: Source.Span, name: []const u8, left: Value, right: Value) Error!Value {
    const object = left.data.struct_value;
    const method = object.descriptor.methods.?.get(name).?;
    if (method.depth > object.built) return self.raiseUnbuilt(span, name, method.owner, object.descriptor.display_name);
    var callable = self.namedCallable(method.key);
    callable.self_value = Heap.retain(left);
    return self.invoke(span, callable, &.{Heap.retain(right)});
}

fn evaluateIntBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: i64,
    right: i64,
) Error!Value {
    switch (operator) {
        .add, .subtract, .multiply => {
            const result = switch (operator) {
                .add => @addWithOverflow(left, right),
                .subtract => @subWithOverflow(left, right),
                .multiply => @mulWithOverflow(left, right),
                else => unreachable,
            };
            if (result[1] != 0) return self.raiseFmt(
                span,
                "{s} of {d} and {d} overflows Int",
                .{ operator.describe(), left, right },
                integer_range_help,
            );
            return .initInt(result[0]);
        },
        .floor_divide => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // The only overflowing quotient: the minimum Int divided by -1 has
            // no positive counterpart in an asymmetric range.
            if (left == std.math.minInt(i64) and right == -1) return self.raiseFmt(
                span,
                "{s} of {d} and {d} overflows Int",
                .{ operator.describe(), left, right },
                integer_range_help,
            );
            return .initInt(@divFloor(left, right));
        },
        .remainder => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // Every value is exactly divisible by -1, so the remainder is zero.
            // Stating it avoids relying on host behavior at the range edge.
            if (right == -1) return .initInt(0);
            return .initInt(@mod(left, right));
        },
        .power => return self.evaluateIntPower(span, left, right),
        .divide => unreachable, // handled before operand kinds matter
    }
}

/// Section 5.3: two `Int`s give an `Int`, so `side ** 2` stays whole. An `Int`
/// has no fraction to hold `2 ** -1`, so a negative exponent raises and points
/// at the `Float` spelling.
///
/// Squaring by repeated halving takes as many steps as the exponent has bits,
/// so `1 ** 1_000_000_000` is instant. The base is squared only while bits of
/// the exponent remain, which means that when squaring overflows, the result it
/// was headed for would have too, so no false overflow is reported.
fn evaluateIntPower(self: *Interpreter, span: Source.Span, base: i64, exponent: i64) Error!Value {
    if (exponent < 0) return self.raiseFmt(
        span,
        "an Int cannot be raised to the negative power {d}",
        .{exponent},
        "Make the base a Float, as in `2.0 ** -1`, for a fractional result.",
    );

    var result: i64 = 1;
    var factor = base;
    var remaining = exponent;
    while (remaining > 0) {
        if (remaining & 1 == 1) {
            const product = @mulWithOverflow(result, factor);
            if (product[1] != 0) return self.raisePowerOverflow(span, base, exponent);
            result = product[0];
        }
        remaining >>= 1;
        if (remaining > 0) {
            const square = @mulWithOverflow(factor, factor);
            if (square[1] != 0) return self.raisePowerOverflow(span, base, exponent);
            factor = square[0];
        }
    }
    return .initInt(result);
}

fn raisePowerOverflow(self: *Interpreter, span: Source.Span, base: i64, exponent: i64) Error {
    return self.raiseFmt(
        span,
        "exponentiation of {d} and {d} overflows Int",
        .{ base, exponent },
        integer_range_help,
    );
}

fn evaluateFloatBinary(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: f64,
    right: f64,
) Error!Value {
    switch (operator) {
        .add => return .initFloat(left + right),
        .subtract => return .initFloat(left - right),
        .multiply => return .initFloat(left * right),
        .floor_divide => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            return .initFloat(@floor(left / right));
        },
        .remainder => {
            if (right == 0) return self.raiseDivisionByZero(span, operator);
            // A NaN or infinite operand produces NaN, which @mod already gives.
            return .initFloat(@mod(left, right));
        },
        .power => return .initFloat(std.math.pow(f64, left, right)),
        .divide => unreachable,
    }
}

// Calls.

fn evaluateCall(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Value {
    // `Shapes.area(3)` calls a declaration; `text.upper()` calls a method. The
    // resolver decided which, and recorded it.
    if (self.trait_calls.get(expression)) |key| return self.callTraitDefault(expression.span, key, call);
    if (self.facts.qualified.get(call.callee)) |key| {
        try self.reach(key, call.callee.span);
        if (self.structs.get(key)) |descriptor| return self.constructStruct(expression.span, key, descriptor, call);
        if (self.functions.contains(key)) return self.callFunction(expression.span, key, call);
        return self.callValue(expression.span, call);
    }
    // A tuple position holding a block is called through its value.
    if (call.callee.data == .member and call.callee.data.member.position == null) {
        return self.callMethod(expression, call, call.callee.data.member);
    }
    // Anything that is not a plain name is a value that must be evaluated
    // first: a lambda called where it is written, or an element of a list of
    // functions.
    if (call.callee.data != .name) return self.callValue(expression.span, call);

    // The checker has proved the callee is a function: a variable holding one,
    // a program function, which shadows the prelude as any declaration would,
    // or a prelude one.
    const name = call.callee.data.name;
    const key = self.keyOf(name);
    try self.reach(key, call.callee.span);
    if (self.find(name) != null) return self.callValue(expression.span, call);
    if (self.structs.get(key)) |descriptor| return self.constructStruct(expression.span, key, descriptor, call);
    if (self.functions.contains(key)) return self.callFunction(expression.span, key, call);
    if (std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "input_maybe")) {
        return self.evaluateInput(expression.span, call, std.mem.eql(u8, name, "input_maybe"));
    }
    if (std.mem.eql(u8, name, "random")) {
        const range = (try self.evaluate(call.arguments[0])).data.range;
        if (range.empty()) return self.raise(expression.span, "`random` cannot choose from an empty Range", "Pass a Range that contains at least one value.");
        const position = self.random().uintLessThan(u64, @intCast(range.count()));
        const distance = @as(i128, position) * range.step_size;
        return .initInt(@intCast(if (range.descending) @as(i128, range.first) - distance else @as(i128, range.first) + distance));
    }
    if (std.mem.eql(u8, name, "exit")) {
        const code: i64 = if (call.arguments.len == 0) 0 else (try self.evaluate(call.arguments[0])).data.int;
        if (code < 0 or code > 255) return self.raiseFmt(expression.span, "`exit` cannot use status {d}", .{code}, "Pass a whole number from 0 through 255.");
        self.exit_code = @intCast(code);
        return error.Exited;
    }
    return self.evaluatePrint(call, std.mem.eql(u8, name, "print"));
}

fn random(self: *Interpreter) std.Random {
    if (self.random_engine == null) self.random_engine = std.Random.DefaultPrng.init(@intFromPtr(self) ^ 0xa0761d6478bd642f);
    return self.random_engine.?.random();
}

fn constructStruct(
    self: *Interpreter,
    call_span: Source.Span,
    key: []const u8,
    descriptor: *const Value.StructType,
    call: Ast.Expression.Call,
) Error!Value {
    const info = self.struct_infos.get(key).?;
    if (info.base != null and descriptor.isOrExtends(Resolver.preludeKey("Error")) and info.declaration.fields.len == 0 and descriptor.fields.len == 1 and !self.constructors.contains(key)) {
        const bound = try self.evaluateBound(call, &.{"message"}, &.{false});
        const instance: Value = .{ .data = .{ .struct_value = try self.heap.createStruct(descriptor, bound.values) } };
        if (bound.omitted) |omitted| self.gpa.free(omitted);
        return instance;
    }
    // Section 10.7: an object of a subclass is built one class at a time,
    // starting from the class every other extends.
    if (info.base != null) {
        const fields = try self.gpa.alloc(Value, descriptor.fields.len);
        @memset(fields, Value.nothing);
        const object = try self.heap.createStruct(descriptor, fields);
        object.built = 0;
        const instance: Value = .{ .data = .{ .struct_value = object } };
        errdefer self.heap.release(instance);
        try self.buildPart(call_span, key, instance, call);
        return instance;
    }
    const constructor = self.constructors.get(key) orelse {
        const bound = try self.evaluateBound(call, info.field_names, info.has_default);
        for (bound.values, descriptor.fields) |*field, metadata| field.* = widen(field.*, metadata.kind);
        const instance: Value = .{ .data = .{ .struct_value = self.heap.createStruct(descriptor, bound.values) catch |err| {
            if (bound.omitted) |omitted| self.gpa.free(omitted);
            return err;
        } } };
        const omitted = bound.omitted orelse return instance;
        defer self.gpa.free(omitted);
        return self.runFieldDefaults(call_span, key, instance, omitted);
    };

    // Section 10.2's custom constructor. The arguments are evaluated in the
    // caller's scopes first, as for any call. The instance starts with every
    // field holding `nothing`; the checker has proved the body sets each one
    // before anything can read it or `self` can go anywhere. Field defaults
    // run before the body, so a field that has one starts out set.
    const declared = constructor.declaration.parameters;
    const bound = try self.evaluateBoundParameters(call, declared);
    defer self.gpa.free(bound.values);
    defer if (bound.omitted) |omitted| self.gpa.free(omitted);
    const fields = self.gpa.alloc(Value, descriptor.fields.len) catch |err| {
        self.releaseBound(bound);
        return err;
    };
    @memset(fields, Value.nothing);
    var instance: Value = .{ .data = .{ .struct_value = self.heap.createStruct(descriptor, fields) catch |err| {
        self.releaseBound(bound);
        return err;
    } } };
    if (info.any_default) {
        instance = self.runFieldDefaults(call_span, key, instance, info.has_default) catch |err| {
            self.releaseBound(bound);
            return err;
        };
    }

    var built: Value = Value.nothing;
    const result = self.invoke(call_span, .{
        .name = constructor.frame_name,
        .named = false,
        .file = self.facts.owner.get(key) orelse self.file,
        .signature = self.signatures.get(key).?,
        .body = .{ .statements = constructor.declaration.body.statements },
        .captured = &.{},
        .written = declared,
        .omitted = bound.omitted,
        .self_value = instance,
        .self_out = &built,
    }, bound.values) catch |err| {
        self.heap.release(built);
        return err;
    };
    // A constructor's own result is always `nothing`; what it built is `self`.
    self.heap.release(result);
    return built;
}

/// Section 11.2's `Trait.method(value, ...)`: the default, run with the first
/// argument as `self`.
fn callTraitDefault(self: *Interpreter, call_span: Source.Span, key: []const u8, call: Ast.Expression.Call) Error!Value {
    var callable = self.namedCallable(key);
    const names = try self.gpa.alloc([]const u8, callable.written.len + 1);
    defer self.gpa.free(names);
    const defaults = try self.gpa.alloc(bool, callable.written.len + 1);
    defer self.gpa.free(defaults);
    names[0] = "self";
    defaults[0] = false;
    for (callable.written, names[1..], defaults[1..]) |parameter, *name, *defaulted| {
        name.* = parameter.name;
        defaulted.* = parameter.default != null;
    }
    const bound = try self.evaluateBound(call, names, defaults);
    defer self.gpa.free(bound.values);
    defer if (bound.omitted) |omitted| self.gpa.free(omitted);
    callable.self_value = bound.values[0];
    if (bound.omitted) |omitted| callable.omitted = omitted[1..];
    return self.invoke(call_span, callable, bound.values[1..]);
}

/// Builds the part of an object of a subclass that the class `key` declares,
/// after its base classes' parts (10.2). `instance` stays the caller's. `call`
/// supplies the arguments: the construction itself, a `super(...)`, or null
/// for the call with no arguments that a constructor without `super(...)`, or a
/// class without a constructor, makes.
fn buildPart(
    self: *Interpreter,
    call_span: Source.Span,
    key: []const u8,
    instance: Value,
    call: ?Ast.Expression.Call,
) Error!void {
    const info = self.struct_infos.get(key).?;
    const object = instance.data.struct_value;
    if (self.constructors.get(key)) |constructor| {
        const declared = constructor.declaration.parameters;
        const bound = if (call) |arguments| try self.evaluateBoundParameters(arguments, declared) else try self.omittedBound(declared.len);
        defer self.gpa.free(bound.values);
        defer if (bound.omitted) |omitted| self.gpa.free(omitted);
        if (info.base == null) {
            object.built = @max(object.built, self.structs.get(key).?.depth);
            if (info.any_default) {
                const same = self.runFieldDefaults(call_span, key, Heap.retain(instance), info.has_default) catch |err| {
                    self.releaseBound(bound);
                    return err;
                };
                self.heap.release(same);
            }
        }
        var built: Value = Value.nothing;
        const result = self.invoke(call_span, .{
            .name = constructor.frame_name,
            .named = false,
            .file = self.facts.owner.get(key) orelse self.file,
            .signature = self.signatures.get(key).?,
            .body = .{ .statements = constructor.declaration.body.statements },
            .captured = &.{},
            .written = declared,
            .omitted = bound.omitted,
            .self_value = Heap.retain(instance),
            .self_out = &built,
            .construct = if (info.base != null) key else null,
        }, bound.values) catch |err| {
            self.heap.release(built);
            return err;
        };
        self.heap.release(result);
        self.heap.release(built);
        return;
    }

    if (info.base) |base| try self.buildPart(call_span, base, instance, null);
    object.built = self.structs.get(key).?.depth;
    var which = info.has_default;
    var omitted_owned: ?[]bool = null;
    defer if (omitted_owned) |omitted| self.gpa.free(omitted);
    if (info.base == null) if (call) |arguments| {
        const bound = try self.evaluateBound(arguments, info.field_names, info.has_default);
        defer self.gpa.free(bound.values);
        const end = info.offset + info.field_names.len;
        for (bound.values, object.fields[info.offset..end], object.descriptor.fields[info.offset..end]) |value, *field, metadata| {
            self.heap.release(field.*);
            field.* = widen(value, metadata.kind);
        }
        omitted_owned = bound.omitted;
        which = bound.omitted orelse return;
    };
    const same = try self.runFieldDefaults(call_span, key, Heap.retain(instance), which);
    self.heap.release(same);
}

/// Every parameter left to its default, for the call a subclass's constructor
/// makes to its base class's when it has no `super(...)`.
fn omittedBound(self: *Interpreter, count: usize) Error!Bound {
    const values = try self.gpa.alloc(Value, count);
    @memset(values, Value.nothing);
    if (count == 0) return .{ .values = values, .omitted = null };
    const omitted = self.gpa.alloc(bool, count) catch |err| {
        self.gpa.free(values);
        return err;
    };
    @memset(omitted, true);
    return .{ .values = values, .omitted = omitted };
}

/// At the start of the constructor of a class that extends another: builds
/// the base class's part, through the `super(...)` that begins the body if
/// there is one, then runs this class's field defaults. Returns the rest of the
/// body.
fn buildBaseFirst(
    self: *Interpreter,
    call_span: Source.Span,
    key: []const u8,
    frame: *Environment,
    statements: []const Ast.Statement,
) Error![]const Ast.Statement {
    const info = self.struct_infos.get(key).?;
    const instance = frame.bindings.get("self").?.value.?;
    var rest = statements;
    if (superCallOf(statements)) |expression| {
        try self.buildPart(expression.span, info.base.?, instance, expression.data.call);
        rest = statements[1..];
    } else {
        try self.buildPart(call_span, info.base.?, instance, null);
    }
    instance.data.struct_value.built = self.structs.get(key).?.depth;
    if (info.any_default) {
        self.heap.release(try self.runFieldDefaults(call_span, key, Heap.retain(instance), info.has_default));
    }
    return rest;
}

/// A constructor's `super(...)`, which can only be its first statement.
fn superCallOf(statements: []const Ast.Statement) ?*const Ast.Expression {
    if (statements.len == 0 or statements[0].data != .expression) return null;
    const expression = statements[0].data.expression;
    if (expression.data != .call or !isSuper(expression.data.call.callee)) return null;
    return expression;
}

fn isSuper(expression: *const Ast.Expression) bool {
    return expression.data == .name and std.mem.eql(u8, expression.data.name, "super");
}

/// Section 10.7: the version of the method `key` that an object's own class
/// runs. An object still being built may not run a version declared by a class
/// whose part of it has not begun, since that version could read fields that
/// hold nothing yet.
fn dispatch(self: *Interpreter, span: Source.Span, receiver: Value, key: []const u8) Error![]const u8 {
    const method = versionOf(receiver, key) orelse return key;
    try self.requireVersionBuilt(span, receiver, key, method);
    return method.key;
}

/// Raises when an object still being built has not begun the part of the
/// class that declares `method`, the version of the method `key` it runs.
fn requireVersionBuilt(self: *Interpreter, span: Source.Span, receiver: Value, key: []const u8, method: Value.StructType.Method) Error!void {
    const object = receiver.data.struct_value;
    if (method.depth > object.built) return self.raiseUnbuilt(span, methodName(key), method.owner, object.descriptor.display_name);
}

/// The entry for the version of the method `key` that the receiver's own
/// class runs, or null when nothing can replace it.
fn versionOf(receiver: Value, key: []const u8) ?Value.StructType.Method {
    if (receiver.data != .struct_value) return null;
    const methods = receiver.data.struct_value.descriptor.methods orelse return null;
    const name = methodName(key);
    // A private method is never replaced, and two traits may each have one.
    if (Resolver.isPrivate(name)) return null;
    return methods.get(name);
}

fn methodName(key: []const u8) []const u8 {
    return key[std.mem.lastIndexOf(u8, key, Resolver.method_separator).? + Resolver.method_separator.len ..];
}

/// A property of an object, at the version its own class has, under the same
/// rule as `dispatch`.
fn propertyOf(self: *Interpreter, span: Source.Span, object: *const Heap.StructValue, name: []const u8) Error!Value.StructType.Property {
    const property = object.descriptor.property(name).?;
    if (property.depth > object.built) return self.raiseUnbuilt(span, name, property.owner, object.descriptor.display_name);
    return property;
}

fn raiseUnbuilt(self: *Interpreter, span: Source.Span, name: []const u8, owner: []const u8, class: []const u8) Error {
    if (std.mem.eql(u8, owner, class)) return self.raiseFmt(
        span,
        "`{s}`'s version of `{s}` ran before this `{s}` was built",
        .{ owner, name, class },
        "A base class's constructor let the object be used before the classes that extend it were built. Finish building the object before passing `self` on or running code that calls its methods.",
    );
    return self.raiseFmt(
        span,
        "`{s}`'s version of `{s}` ran before the `{s}` part of this `{s}` was built",
        .{ owner, name, owner, class },
        "A base class's constructor let the object be used before the classes that extend it were built. Finish building the object before passing `self` on or running code that calls its methods.",
    );
}

/// Section 10.2: the defaults of the fields `which` marks, in declaration
/// order, each seeing `self` as construction has left it so far. Takes the
/// instance and gives it back finished.
fn runFieldDefaults(
    self: *Interpreter,
    call_span: Source.Span,
    key: []const u8,
    instance: Value,
    which: []const bool,
) Error!Value {
    const info = self.struct_infos.get(key).?;
    const outer_scopes = self.scopes;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > 0) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
    }
    const frame = self.pushScope() catch |err| {
        self.heap.release(instance);
        return err;
    };
    frame.bindings.put(self.gpa, "self", .{ .kind = .struct_value, .value = instance }) catch |err| {
        self.heap.release(instance);
        return err;
    };

    try self.call_stack.append(self.gpa, .{
        .function = info.defaults_frame,
        .call_span = call_span,
        .file = self.file,
        .named = false,
    });
    defer _ = self.call_stack.pop();
    const outer_file = self.file;
    self.file = self.facts.owner.get(key) orelse self.file;
    defer self.file = outer_file;

    for (info.declaration.fields, which, 0..) |field, runs, position| {
        if (!runs) continue;
        const value = try self.evaluate(field.default.?);
        const slot = &frame.bindings.getPtr("self").?.value.?;
        const building = self.heap.uniqueStruct(slot) catch |err| {
            self.heap.release(value);
            return err;
        };
        self.heap.release(building.fields[info.offset + position]);
        building.fields[info.offset + position] = widen(value, building.descriptor.fields[info.offset + position].kind);
    }
    return Heap.retain(frame.bindings.get("self").?.value.?);
}

/// A call's arguments, evaluated left to right as written and then placed in
/// parameter order (7.3). A parameter left to its default holds `nothing` and is
/// marked in `omitted`, which is null when none is.
const Bound = struct {
    values: []Value,
    omitted: ?[]bool,
};

fn evaluateBound(
    self: *Interpreter,
    call: Ast.Expression.Call,
    parameter_names: []const []const u8,
    has_default: []const bool,
) Error!Bound {
    const written = try self.evaluateArguments(call.arguments);
    if (call_arguments.isPlain(call, parameter_names.len)) return .{ .values = written, .omitted = null };
    defer self.gpa.free(written);

    const positions = self.gpa.alloc(?usize, parameter_names.len) catch |err| {
        for (written) |value| self.heap.release(value);
        return err;
    };
    defer self.gpa.free(positions);
    // The checker accepted this call, so the matching cannot fail here.
    std.debug.assert(call_arguments.bind(call, parameter_names, has_default, positions) == .none);

    const values = self.gpa.alloc(Value, parameter_names.len) catch |err| {
        for (written) |value| self.heap.release(value);
        return err;
    };
    const omitted = self.gpa.alloc(bool, parameter_names.len) catch |err| {
        self.gpa.free(values);
        for (written) |value| self.heap.release(value);
        return err;
    };
    var any_omitted = false;
    for (positions, values, omitted) |position, *value, *left| {
        value.* = if (position) |index| written[index] else Value.nothing;
        left.* = position == null;
        any_omitted = any_omitted or left.*;
    }
    if (!any_omitted) {
        self.gpa.free(omitted);
        return .{ .values = values, .omitted = null };
    }
    return .{ .values = values, .omitted = omitted };
}

fn evaluateBoundParameters(self: *Interpreter, call: Ast.Expression.Call, written: []const Ast.Parameter) Error!Bound {
    if (call_arguments.isPlain(call, written.len)) {
        return .{ .values = try self.evaluateArguments(call.arguments), .omitted = null };
    }
    const names = try self.gpa.alloc([]const u8, written.len);
    defer self.gpa.free(names);
    const defaults = try self.gpa.alloc(bool, written.len);
    defer self.gpa.free(defaults);
    for (written, names, defaults) |parameter, *name, *defaulted| {
        name.* = parameter.name;
        defaulted.* = parameter.default != null;
    }
    return self.evaluateBound(call, names, defaults);
}

/// Releases what `evaluateBound` produced when the call it was for never runs.
fn releaseBound(self: *Interpreter, bound: Bound) void {
    for (bound.values) |value| self.heap.release(value);
}

/// Section 15.2's `input(prompt)` and `input_maybe(prompt)`: writes the prompt,
/// reads one line, and returns it without its line ending. Pressing Enter gives
/// `""`. They differ only at the end of the input, where `input` raises — not
/// catchable yet, as nothing is — and `input_maybe` reports absence (4.5).
fn evaluateInput(self: *Interpreter, span: Source.Span, call: Ast.Expression.Call, maybe: bool) Error!Value {
    if (call.arguments.len == 1) {
        const prompt = try self.evaluate(call.arguments[0]);
        defer self.heap.release(prompt);
        try self.out.writeAll(prompt.data.string.bytes);
    }
    // A prompt has to be seen before the program waits for an answer.
    try self.out.flush();

    var line: std.Io.Writer.Allocating = .init(self.gpa);
    defer line.deinit();
    const length = self.in.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return self.raise(span, "the program's input could not be read", "Check how the program's input is being provided."),
    };
    const at_end = self.in.bufferedLen() == 0;
    if (!at_end) self.in.toss(1); // the newline
    if (at_end and length == 0) {
        // Section 15.2: `input_maybe` reports the end of the input as absence,
        // which is how a program reads until there is nothing left.
        if (maybe) return Value.nothing;
        return self.raise(
            span,
            "`input` reached the end of the input",
            "There are no more lines to read. Use `input_maybe`, which gives `nothing` instead, to read until the input ends.",
        );
    }

    const bytes = std.mem.trimEnd(u8, line.written(), "\r");
    if (!std.unicode.utf8ValidateSlice(bytes)) return self.raise(
        span,
        "the line read by `input` is not valid UTF-8 text",
        "Emerald strings hold Unicode text; check how the input was produced.",
    );
    return self.heap.copyText(bytes);
}

/// Every argument is evaluated before anything is written, as for any other
/// call. Displaying each as it arrived would interleave the output of an
/// argument that prints with the line being built, and an argument that
/// failed would leave half a line behind.
fn evaluatePrint(self: *Interpreter, call: Ast.Expression.Call, newline: bool) Error!Value {
    const values = try self.evaluateArguments(call.arguments);
    defer {
        for (values) |value| self.heap.release(value);
        self.gpa.free(values);
    }

    for (values, 0..) |value, position| {
        // Section 15.2 separates multiple arguments with one space.
        if (position != 0) try self.out.writeAll(" ");
        try value.display(self.out);
    }
    // Section 15.2: `print` ends the line and `write` does not.
    if (newline) try self.out.writeAll("\n");
    // Section 15.2 gives both no result, which is section 4.2's `Nothing`.
    return Value.nothing;
}

/// One call, whatever form it was written in. `captured` is the scope stack the
/// callee runs against: empty for a named function, which can only read the
/// module, and section 7.4's captured scopes for a lambda.
const StructInfo = struct {
    declaration: Ast.StructDeclaration,
    /// The type's own fields, which follow its base classes' in a value.
    field_names: []const []const u8,
    has_default: []const bool,
    any_default: bool,
    /// Section 10.7's base class, by key.
    base: ?[]const u8 = null,
    /// Section 11.2's `with` list, by key.
    traits: []const []const u8 = &.{},
    /// Where the type's own fields start among all of a value's fields.
    offset: usize = 0,
    /// What a stack trace calls the frame field defaults run in.
    defaults_frame: []const u8,
};

/// A trait (11.1), which has no descriptor of its own.
const TraitInfo = struct {
    declaration: Ast.StructDeclaration,
    traits: []const []const u8,
    display_name: []const u8,
};

/// A custom constructor, with what a stack trace calls it worked out once
/// rather than at every construction.
const Constructor = struct {
    declaration: Ast.StructDeclaration.Constructor,
    frame_name: []const u8,
};

const Callable = struct {
    /// What a stack trace calls it.
    name: []const u8,
    /// A lambda's parameters as written, so section 8.6's `(name, age)` can be
    /// unpacked where it is bound. Empty for a named function, whose
    /// parameters are always plain names.
    parameters: []const Ast.Expression.LambdaParameter = &.{},
    /// Whether `name` is the program's own name for it, which a lambda has not.
    named: bool = true,
    /// The file its body was written in, which is what its bare module-level
    /// names mean and where its own errors are reported.
    file: u32 = 0,
    /// The checked shape, which is where widening comes from (4.4).
    signature: Type.Signature,
    body: Body,
    captured: []const *Environment,
    /// A named function's parameters as written, for their defaults (7.3).
    written: []const Ast.Parameter = &.{},
    /// Which parameters the call left to their defaults; null when none.
    omitted: ?[]const bool = null,
    /// For a constructor or method, the value bound as `self`, which the call
    /// takes ownership of.
    self_value: ?Value = null,
    /// Where to leave what `self` holds when the body ends, for a caller that
    /// keeps the result: a constructor, or a method that changes `self`.
    self_out: ?*Value = null,
    /// For a method that changes `self`, the place its receiver is taken from
    /// once every argument, defaults included, has been evaluated.
    take: ?*Take = null,
    /// For the constructor of a class that extends another, its key: the base
    /// class's part of `self` is built before the body runs (10.2).
    construct: ?[]const u8 = null,
    /// The file an overridden method's parameter defaults were written in,
    /// when it is not the one its body was: an override uses the defaults of
    /// the declaration it replaces (7.3).
    defaults_file: ?u32 = null,

    const Body = union(enum) {
        statements: []const Ast.Statement,
        /// A single-expression lambda, whose value is its result (7.4).
        expression: *const Ast.Expression,
    };
};

/// Section 4.3's exclusive access, which begins when a changing method's
/// arguments are all evaluated. Section 7.3 counts defaults among them, so a
/// default may still read the variable the receiver lives in; `invoke` takes the
/// receiver only after the defaults have run.
const Take = struct {
    root: *const Ast.Expression,
    steps: []const PlaceStep,
    method: []const u8,
    /// What the root binding held, while it is taken.
    root_value: Value = Value.nothing,
    /// Where the receiver came from, inside `root_value`, once taken.
    slot: ?*Value = null,
};

/// Section 7.1's calling convention. The checker has already proved arity and
/// argument types, so nothing here checks them again.
fn callFunction(
    self: *Interpreter,
    call_span: Source.Span,
    name: []const u8,
    call: Ast.Expression.Call,
) Error!Value {
    // Arguments evaluate in the caller's scopes before the callee's replace
    // them.
    var callable = self.namedCallable(name);
    const bound = try self.evaluateBoundParameters(call, callable.written);
    defer self.gpa.free(bound.values);
    defer if (bound.omitted) |omitted| self.gpa.free(omitted);
    callable.omitted = bound.omitted;
    return self.invoke(call_span, callable, bound.values);
}

fn namedCallable(self: *Interpreter, key: []const u8) Callable {
    const declaration = self.functions.get(key).?;
    // Section 7.3: an override uses the defaults of the declaration it
    // replaces, which are written with that declaration's parameters.
    if (self.overrides.get(key)) |original| {
        return .{
            .name = declaration.name,
            .file = self.facts.owner.get(key) orelse self.file,
            .signature = self.signatures.get(key).?,
            .body = .{ .statements = declaration.body.statements },
            .captured = &.{},
            .written = self.functions.get(original).?.parameters,
            .defaults_file = self.facts.owner.get(original) orelse self.file,
        };
    }
    return .{
        // The name as it was written, not the key: a stack trace should read
        // the way the file reads.
        .name = declaration.name,
        .file = self.facts.owner.get(key) orelse self.file,
        .signature = self.signatures.get(key).?,
        .body = .{ .statements = declaration.body.statements },
        .captured = &.{},
        .written = declaration.parameters,
    };
}

/// A call through a value: `double(3)` where `double` holds a lambda, or a
/// lambda called where it is written.
fn callValue(self: *Interpreter, call_span: Source.Span, call: Ast.Expression.Call) Error!Value {
    const callee = try self.evaluate(call.callee);
    defer self.heap.release(callee);
    var callable = self.closureCallable(callee.data.closure);
    // A named function, nested ones included, may leave parameters to their
    // defaults and take arguments by name (7.3).
    if (callee.data.closure.function == .named) {
        const bound = try self.evaluateBoundParameters(call, callable.written);
        defer self.gpa.free(bound.values);
        defer if (bound.omitted) |omitted| self.gpa.free(omitted);
        callable.omitted = bound.omitted;
        return self.invoke(call_span, callable, bound.values);
    }
    const arguments = try self.evaluateArguments(call.arguments);
    defer self.gpa.free(arguments);
    return self.invokeClosure(call_span, callee.data.closure, callable, arguments);
}

/// Runs a function value against already-evaluated arguments, which it takes
/// ownership of. A captured method runs on the closure's copy of its receiver;
/// a changing one takes that copy out while it runs and leaves the changed
/// value behind, so the next call sees it (7.5). `callable` is the closure's
/// `closureCallable`, which a caller running the same block many times works
/// out once.
fn invokeClosure(
    self: *Interpreter,
    call_span: Source.Span,
    closure: *Heap.Closure,
    closure_callable: Callable,
    arguments: []const Value,
) Error!Value {
    var callable = closure_callable;
    const key = switch (closure.function) {
        .method => |key| key,
        else => return self.invoke(call_span, callable, arguments),
    };
    // Section 10.7: a method taken from an object still being built runs only
    // once its class's part has begun. A `super` version is never the object's
    // own, and is reachable only once its part is.
    if (versionOf(closure.receiver, key)) |method| if (std.mem.eql(u8, method.key, key)) {
        self.requireVersionBuilt(call_span, closure.receiver, key, method) catch |err| {
            for (arguments) |argument| self.heap.release(argument);
            return err;
        };
    };
    if (!self.changing_methods.contains(key)) {
        callable.self_value = Heap.retain(closure.receiver);
        return self.invoke(call_span, callable, arguments);
    }
    if (closure.running) {
        for (arguments) |argument| self.heap.release(argument);
        return self.raiseFmt(
            call_span,
            "`{s}` is already changing its captured copy, so it cannot be called again until that call finishes",
            .{callable.name},
            "A captured method has its copy to itself while it changes it. Call the method on a value directly instead of through the captured one.",
        );
    }
    callable.self_value = closure.receiver;
    closure.receiver = Value.nothing;
    closure.running = true;
    var changed: Value = Value.nothing;
    callable.self_out = &changed;
    defer {
        closure.running = false;
        closure.receiver = changed;
    }
    return self.invoke(call_span, callable, arguments);
}

fn closureCallable(self: *Interpreter, closure: *Heap.Closure) Callable {
    return switch (closure.function) {
        .named => |name| blk: {
            // A nested function (7.1) sees the scopes it was created in; a
            // program function captured none.
            var callable = self.namedCallable(name);
            callable.captured = closure.captured;
            break :blk callable;
        },
        .method => |name| self.namedCallable(name),
        .lambda => |expression| .{
            .name = "a block",
            .named = false,
            .file = closure.file,
            .parameters = expression.data.lambda.parameters,
            // The checker recorded the lambda's type where it is written, which
            // is the only place its parameter and result types were known.
            .signature = self.literal_types.get(expression).?.signature.?.*,
            .body = switch (expression.data.lambda.body) {
                .expression => |body| .{ .expression = body },
                .block => |body| .{ .statements = body.statements },
            },
            .captured = closure.captured,
        },
    };
}

/// Runs a callable against already-evaluated arguments, which it takes
/// ownership of.
fn invoke(
    self: *Interpreter,
    call_span: Source.Span,
    callable: Callable,
    arguments: []const Value,
) Error!Value {
    if (self.call_stack.items.len >= max_call_depth) {
        for (arguments) |argument| self.heap.release(argument);
        if (callable.self_value) |instance| {
            if (callable.self_out) |out| out.* = instance else self.heap.release(instance);
        }
        return self.raiseTooMuchRecursion(call_span, callable.name, true);
    }

    // The callee's own block scopes push onto and pop off this list, so by the
    // time it is restored only what it started with is left. The captured
    // scopes are held by the closure, not by this list, so they are left alone.
    const outer_scopes = self.scopes;
    self.scopes = .empty;
    defer {
        while (self.scopes.items.len > callable.captured.len) self.popScope();
        self.scopes.deinit(self.gpa);
        self.scopes = outer_scopes;
    }
    try self.scopes.appendSlice(self.gpa, callable.captured);

    const frame = try self.pushScope();
    if (callable.self_value) |instance| {
        frame.bindings.put(self.gpa, "self", .{ .kind = .struct_value, .value = instance }) catch |err| {
            self.heap.release(instance);
            return err;
        };
    }
    for (callable.signature.parameter_names, arguments, callable.signature.parameters, 0..) |name, argument, parameter_type, index| {
        // An `Int` passed to a `Float` parameter arrives as a `Float`.
        const kind = kindOf(parameter_type);

        // Section 8.6's `{ (name, age) => ... }`: one argument, unpacked into
        // the names the block's header gave its positions.
        if (index < callable.parameters.len) {
            if (callable.parameters[index].pattern) |pattern| {
                defer self.heap.release(argument);
                try self.unpackInto(pattern, argument, .declare);
                continue;
            }
        }

        // Section 7.4: `_` names nothing, so its argument has nowhere to live.
        if (std.mem.eql(u8, name, "_")) {
            self.heap.release(argument);
            continue;
        }
        // Left to its default, which is evaluated below, inside the callee.
        if (callable.omitted) |omitted| if (omitted[index]) continue;
        try frame.bindings.put(self.gpa, name, .{ .kind = kind, .value = widen(argument, kind) });
    }

    // A changing value is returned to its place even when the body or a
    // default raises. Mutations completed before the error remain visible,
    // just as changes to a class do.
    errdefer if (callable.self_out) |out| {
        if (out.data == .nothing) {
            if (frame.bindings.get("self")) |binding| {
                if (binding.value) |instance| out.* = Heap.retain(instance);
            }
        }
    };

    try self.call_stack.append(self.gpa, .{
        .function = callable.name,
        .call_span = call_span,
        // The call is in the caller's file; the body that follows is not.
        .file = self.file,
        .named = callable.named,
    });
    defer _ = self.call_stack.pop();

    const outer_file = self.file;
    self.file = callable.file;
    defer self.file = outer_file;

    // Section 7.3: "Explicit arguments evaluate left to right as written,
    // followed by omitted defaults in parameter order." A default sees the
    // parameters before it, which are already bound.
    if (callable.omitted) |omitted| {
        if (callable.defaults_file) |file| self.file = file;
        defer self.file = callable.file;
        for (omitted, callable.written, callable.signature.parameters) |left, parameter, parameter_type| {
            if (!left) continue;
            const kind = kindOf(parameter_type);
            const value = try self.evaluate(parameter.default.?);
            frame.bindings.put(self.gpa, parameter.name, .{ .kind = kind, .value = widen(value, kind) }) catch |err| {
                self.heap.release(value);
                return err;
            };
        }
    }

    if (callable.take) |take| try self.takeReceiver(take, frame, outer_scopes, outer_file);

    const result = switch (callable.body) {
        .expression => |body| try self.evaluate(body),
        .statements => |statements| blk: {
            const body = if (callable.construct) |key| try self.buildBaseFirst(call_span, key, frame, statements) else statements;
            self.executeAll(body) catch |err| switch (err) {
                error.Returned => {},
                else => return err,
            };
            const returned = self.return_value orelse Value.nothing;
            self.return_value = null;
            // `self` as the body left it, which may no longer be the instance
            // it started with if copy-on-write replaced it. The frame's
            // binding still holds its own count, released when the frame ends.
            if (callable.self_out) |out| out.* = Heap.retain(frame.bindings.get("self").?.value.?);
            break :blk returned;
        },
    };
    // As with parameters, and including a return type the checker inferred:
    // `return 1` from a function whose returns merged to `Float` yields `1.0`.
    return widen(result, kindOf(callable.signature.return_type));
}

/// Section 4.5's `value.or(fallback)`.
///
/// The fallback is evaluated only when it is needed, the way the `or` operator
/// short-circuits (5.2). `.or(next_ticket())` should not draw a ticket it is
/// going to discard, and nothing else a program can write depends on the
/// argument running.
fn callOr(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const value = try self.evaluate(member.base);
    if (value.data != .nothing) return value;

    // An `Int` standing in for a `Float?` arrives as a `Float`, as anywhere
    // else the checker allowed the widening (4.4).
    const present = self.literal_types.get(expression).?;
    return widen(try self.evaluate(call.arguments[0]), kindOf(present));
}

/// Section 8.5's `each` and section 8.6's callback collection methods.
///
/// The receiver is held for the whole traversal, so the list being visited
/// cannot change underneath it: a block that changes the same variable finds
/// the buffer shared and copies it first, which is section 8.1's value
/// semantics doing exactly what it promises.
/// One value per entry: the member for a set, a `(key, value)` tuple for a
/// dictionary. The caller owns one holder of each.
fn collectItems(self: *Interpreter, map: *const Heap.Map) Error![]Value {
    const items = try self.gpa.alloc(Value, map.entries.items.len);
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| self.heap.release(item);
        self.gpa.free(items);
    }
    while (built < items.len) : (built += 1) {
        const entry = map.entries.items[built];
        items[built] = if (map.is_set)
            Heap.retain(entry.key)
        else
            try self.entryTuple(map, .{
                .hash = entry.hash,
                .key = Heap.retain(entry.key),
                .value = Heap.retain(entry.value),
            });
    }
    return items;
}

/// Section 8.5's dictionary and set methods that only look.
fn readMap(
    self: *Interpreter,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    map: *const Heap.Map,
    arguments: []const Value,
) Error!Value {
    const name = member.name;

    if (std.mem.eql(u8, name, "empty?")) return .initBool(map.count() == 0);

    if (map.is_set) {
        if (std.mem.eql(u8, name, "union") or
            std.mem.eql(u8, name, "intersection") or
            std.mem.eql(u8, name, "difference") or
            std.mem.eql(u8, name, "symmetric_difference"))
        {
            const other = arguments[0];
            if (other.kind() != .map or !other.data.map.is_set) {
                return self.raiseFmt(
                    call.arguments[0].span,
                    "`{s}` needs a Set",
                    .{name},
                    "Pass a set with the same element type.",
                );
            }
            const result = try self.heap.createMap(map.key_kind, .nothing, true);
            const value: Value = .{ .data = .{ .map = result } };
            errdefer self.heap.release(value);
            if (std.mem.eql(u8, name, "union")) {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try self.hashKey(call.arguments[0].span, key);
                    try self.heap.put(result, hash, key, Value.nothing);
                }
                for (other.data.map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try self.hashKey(call.arguments[0].span, key);
                    try self.heap.put(result, hash, key, Value.nothing);
                }
                return value;
            }
            if (std.mem.eql(u8, name, "intersection")) {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try self.hashKey(call.arguments[0].span, key);
                    if (try Heap.lookupIn(self.gpa, other.data.map, hash, key) == null) continue;
                    try self.heap.put(result, hash, key, Value.nothing);
                }
                return value;
            }
            if (std.mem.eql(u8, name, "difference")) {
                for (map.entries.items) |entry| {
                    const key = Heap.retain(entry.key);
                    const hash = try self.hashKey(call.arguments[0].span, key);
                    if (try Heap.lookupIn(self.gpa, other.data.map, hash, key) != null) continue;
                    try self.heap.put(result, hash, key, Value.nothing);
                }
                return value;
            }
            for (map.entries.items) |entry| {
                const key = Heap.retain(entry.key);
                const hash = try self.hashKey(call.arguments[0].span, key);
                if (try Heap.lookupIn(self.gpa, other.data.map, hash, key) == null) {
                    try self.heap.put(result, hash, key, Value.nothing);
                }
            }
            for (other.data.map.entries.items) |entry| {
                const key = Heap.retain(entry.key);
                const hash = try self.hashKey(call.arguments[0].span, key);
                if (try Heap.lookupIn(self.gpa, map, hash, key) == null) {
                    try self.heap.put(result, hash, key, Value.nothing);
                }
            }
            return value;
        }

        if (std.mem.eql(u8, name, "subset?") or std.mem.eql(u8, name, "superset?") or std.mem.eql(u8, name, "disjoint?")) {
            const other = arguments[0];
            if (other.kind() != .map or !other.data.map.is_set) {
                return self.raiseFmt(
                    call.arguments[0].span,
                    "`{s}` needs a Set",
                    .{name},
                    "Pass a set with the same element type.",
                );
            }
            if (std.mem.eql(u8, name, "subset?")) {
                for (map.entries.items) |entry| {
                    const hash = try self.hashKey(call.arguments[0].span, entry.key);
                    if (try Heap.lookupIn(self.gpa, other.data.map, hash, entry.key) == null) return .initBool(false);
                }
                return .initBool(true);
            }
            if (std.mem.eql(u8, name, "superset?")) {
                for (other.data.map.entries.items) |entry| {
                    const hash = try self.hashKey(call.arguments[0].span, entry.key);
                    if (try Heap.lookupIn(self.gpa, map, hash, entry.key) == null) return .initBool(false);
                }
                return .initBool(true);
            }
            for (map.entries.items) |entry| {
                const hash = try self.hashKey(call.arguments[0].span, entry.key);
                if (try Heap.lookupIn(self.gpa, other.data.map, hash, entry.key) != null) return .initBool(false);
            }
            return .initBool(true);
        }
    }

    if (std.mem.eql(u8, name, "contains_key?") or std.mem.eql(u8, name, "contains?")) {
        const key = widen(Heap.retain(arguments[0]), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(call.arguments[0].span, key);
        return .initBool(try Heap.lookupIn(self.gpa, map, hash, key) != null);
    }

    if (std.mem.eql(u8, name, "contains_value?")) {
        for (map.entries.items) |entry| {
            if (try Value.equals(self.gpa, entry.value, arguments[0])) return .initBool(true);
        }
        return .initBool(false);
    }

    if (std.mem.eql(u8, name, "keys")) return self.mapHalf(map, .key);
    if (std.mem.eql(u8, name, "values")) return self.mapHalf(map, .value);

    // `entries`
    const items = try self.collectItems(map);
    defer self.gpa.free(items);
    const list = try self.heap.createList(.tuple, items.len);
    for (items) |item| list.items.appendAssumeCapacity(item);
    return .{ .data = .{ .list = list } };
}

/// Section 8.5's dictionary and set methods that change what they are called
/// on. `map` has already been made safe to change.
fn changeMap(
    self: *Interpreter,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    map: *Heap.Map,
    arguments: []const Value,
) Error!Value {
    const name = member.name;

    if (std.mem.eql(u8, name, "add")) {
        const held = widen(Heap.retain(arguments[0]), map.key_kind);
        const hash = try self.hashKey(call.arguments[0].span, held);
        try self.heap.put(map, hash, held, Value.nothing);
        return Value.nothing;
    }

    if (std.mem.eql(u8, name, "remove")) {
        const key = widen(Heap.retain(arguments[0]), map.key_kind);
        defer self.heap.release(key);
        const hash = try self.hashKey(call.arguments[0].span, key);
        const removed = try self.heap.removeKey(map, hash, key);
        // A set reports nothing; a dictionary answers with what was there, and
        // absence when the key was not (4.5).
        if (map.is_set) {
            if (removed) |value| self.heap.release(value);
            return Value.nothing;
        }
        return removed orelse Value.nothing;
    }

    // `merge`. The other dictionary's entries are copied first, because merging
    // one into itself would otherwise walk a list growing underneath it.
    const other = arguments[0].data.map;
    const entries = try self.gpa.dupe(Heap.Map.Entry, other.entries.items);
    defer self.gpa.free(entries);
    for (entries) |entry| {
        try self.heap.put(
            map,
            entry.hash,
            Heap.retain(entry.key),
            widen(Heap.retain(entry.value), map.value_kind),
        );
    }
    return Value.nothing;
}

const Half = enum { key, value };

/// Section 8.5's `keys` and `values`, each a list in insertion order.
fn mapHalf(self: *Interpreter, map: *const Heap.Map, half: Half) Error!Value {
    const list = try self.heap.createList(
        if (half == .key) map.key_kind else map.value_kind,
        map.entries.items.len,
    );
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (map.entries.items) |entry| {
        list.items.appendAssumeCapacity(Heap.retain(if (half == .key) entry.key else entry.value));
    }
    return result;
}

fn callHigherOrder(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);

    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;

    // Section 8.6: every collection block receives one logical item, and a
    // dictionary's is a `(key, value)` tuple. Building that list up front also
    // gives a dictionary the same "as it was when the loop began" guarantee a
    // list gets for free.
    var built: ?[]Value = null;
    defer if (built) |owned| {
        for (owned) |item| self.heap.release(item);
        self.gpa.free(owned);
    };
    const items: []const Value = if (receiver.data == .map) blk: {
        built = try self.collectItems(receiver.data.map);
        break :blk built.?;
    } else receiver.data.list.items.items;

    const Kind = enum {
        each,
        each_with_index,
        reverse_each,
        map,
        filter,
        reject,
        flat_map,
        filter_map,
        take_while,
        drop_while,
        @"any?",
        @"all?",
        @"none?",
        @"one?",
        count_where,
        find,
        find_index,
    };
    const kind = std.meta.stringToEnum(Kind, member.name).?;

    if (receiver.data == .map and (kind == .filter or kind == .reject)) {
        const map = receiver.data.map;
        const result = try self.heap.createMap(map.key_kind, map.value_kind, map.is_set);
        const value: Value = .{ .data = .{ .map = result } };
        errdefer self.heap.release(value);
        for (items) |item| {
            const argument = [_]Value{Heap.retain(item)};
            const produced = try self.invokeClosure(expression.span, closure, callable, &argument);
            defer self.heap.release(produced);
            const accepted = produced.data.bool;
            if ((kind == .filter and accepted) or (kind == .reject and !accepted)) {
                if (map.is_set) {
                    const hash = try self.hashKey(expression.span, item);
                    try self.heap.put(result, hash, Heap.retain(item), Value.nothing);
                } else {
                    const tuple = item.data.tuple;
                    const key = tuple.items[0];
                    const value_for_key = tuple.items[1];
                    const hash = try self.hashKey(expression.span, key);
                    try self.heap.put(result, hash, Heap.retain(key), Heap.retain(value_for_key));
                }
            }
        }
        return value;
    }

    // The checker exposes these value-producing methods only on Lists for
    // now. Keeping a runtime kind for the collection item still lets an
    // already-diagnosed invalid Dictionary or Set call finish without a host
    // crash while diagnostics are being collected.
    const element_kind: Value.Kind = switch (receiver.data) {
        .list => |list| list.element,
        .map => |map| if (map.is_set) map.key_kind else .tuple,
        else => unreachable,
    };

    const collected: ?*Heap.List = switch (kind) {
        .map => try self.heap.createList(kindOf(callable.signature.return_type), items.len),
        .flat_map => try self.heap.createList(
            if (callable.signature.return_type.kind == .list)
                kindOf(callable.signature.return_type.element.?.*)
            else
                .nothing,
            0,
        ),
        .filter_map => try self.heap.createList(
            if (callable.signature.return_type.optional)
                kindOf(callable.signature.return_type.payload())
            else
                .nothing,
            items.len,
        ),
        .filter, .reject, .take_while, .drop_while => try self.heap.createList(element_kind, items.len),
        else => null,
    };
    const result: Value = if (collected) |list| .{ .data = .{ .list = list } } else Value.nothing;
    errdefer self.heap.release(result);

    var matches: i64 = 0;
    var dropping = true;
    var visited: usize = 0;
    while (visited < items.len) : (visited += 1) {
        const index = if (kind == .reverse_each) items.len - visited - 1 else visited;
        const item = items[index];
        if (kind == .drop_while and !dropping) {
            collected.?.items.appendAssumeCapacity(Heap.retain(item));
            continue;
        }
        const produced = if (kind == .each_with_index) blk: {
            const arguments = [_]Value{ Heap.retain(item), .initInt(@intCast(index)) };
            break :blk try self.invokeClosure(expression.span, closure, callable, &arguments);
        } else blk: {
            const argument = [_]Value{Heap.retain(item)};
            break :blk try self.invokeClosure(expression.span, closure, callable, &argument);
        };
        if (collected) |list| {
            if (kind == .map) {
                list.items.appendAssumeCapacity(produced);
                continue;
            }
            if (kind == .flat_map) {
                if (produced.data == .list) for (produced.data.list.items.items) |nested| {
                    try list.items.append(self.gpa, Heap.retain(nested));
                };
                self.heap.release(produced);
                continue;
            }
            if (kind == .filter_map) {
                if (produced.data == .nothing) self.heap.release(produced) else list.items.appendAssumeCapacity(produced);
                continue;
            }
            const accepted = produced.data.bool;
            self.heap.release(produced);
            if ((kind == .filter and accepted) or (kind == .reject and !accepted)) {
                list.items.appendAssumeCapacity(Heap.retain(item));
            }
            if (kind == .take_while) {
                if (!accepted) break;
                list.items.appendAssumeCapacity(Heap.retain(item));
            }
            if (kind == .drop_while and !accepted) {
                dropping = false;
                list.items.appendAssumeCapacity(Heap.retain(item));
            }
            continue;
        }
        if (kind == .each or kind == .each_with_index or kind == .reverse_each) {
            self.heap.release(produced);
            continue;
        }
        const accepted = produced.data.bool;
        self.heap.release(produced);
        switch (kind) {
            // These questions stop as soon as later values cannot change the
            // answer. `one?` can stop after its second accepted value.
            .@"any?" => if (accepted) return .initBool(true),
            .@"all?" => if (!accepted) return .initBool(false),
            .@"none?" => if (accepted) return .initBool(false),
            .@"one?" => if (accepted) {
                matches += 1;
                if (matches == 2) return .initBool(false);
            },
            .count_where => {
                if (accepted) matches += 1;
            },
            // Searching stops at the first element the block accepts, and
            // reports absence when none does (4.5).
            .find => if (accepted) return Heap.retain(item),
            .find_index => if (accepted) return .initInt(@intCast(index)),
            else => unreachable,
        }
    }
    return switch (kind) {
        .@"any?" => .initBool(false),
        .@"all?", .@"none?" => .initBool(true),
        .@"one?" => .initBool(matches == 1),
        .count_where => .initInt(matches),
        else => result,
    };
}

/// Section 8.6's left-to-right List reduction. The first explicit value is
/// returned unchanged for an empty List; otherwise each block result becomes
/// the next accumulator. The checker establishes the two block parameters and
/// matching result type before execution.
fn callReduce(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    var accumulator = try self.evaluate(call.arguments[0]);
    errdefer self.heap.release(accumulator);
    const block = try self.evaluate(call.arguments[1]);
    defer self.heap.release(block);

    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    for (receiver.data.list.items.items) |item| {
        const arguments = [_]Value{ accumulator, Heap.retain(item) };
        accumulator = try self.invokeClosure(expression.span, closure, callable, &arguments);
    }
    return accumulator;
}

/// Section 8.6's right-to-left List reduction. It behaves like `reduce`, but it
/// visits the List from its end toward its start, so the block sees the last
/// item first and the first item last.
fn callReduceRight(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    var accumulator = try self.evaluate(call.arguments[0]);
    errdefer self.heap.release(accumulator);
    const block = try self.evaluate(call.arguments[1]);
    defer self.heap.release(block);

    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    var index = receiver.data.list.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = receiver.data.list.items.items[index];
        const arguments = [_]Value{ accumulator, Heap.retain(item) };
        accumulator = try self.invokeClosure(expression.span, closure, callable, &arguments);
    }
    return accumulator;
}

fn callPartition(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    receiver: Value,
) Error!Value {
    _ = member;
    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);

    const list = receiver.data.list;
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const kept = try self.heap.createList(list.element, list.items.items.len);
    const dropped = try self.heap.createList(list.element, list.items.items.len);
    const items = try self.gpa.alloc(Value, 2);
    const kinds = try self.gpa.alloc(Value.Kind, 2);
    items[0] = .{ .data = .{ .list = kept } };
    items[1] = .{ .data = .{ .list = dropped } };
    kinds[0] = .list;
    kinds[1] = .list;
    const result: Value = .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
    errdefer self.heap.release(result);

    for (list.items.items) |item| {
        const argument = [_]Value{Heap.retain(item)};
        const produced = try self.invokeClosure(expression.span, closure, callable, &argument);
        defer self.heap.release(produced);
        if (produced.data.bool) {
            kept.items.appendAssumeCapacity(Heap.retain(item));
        } else {
            dropped.items.appendAssumeCapacity(Heap.retain(item));
        }
    }
    return result;
}

fn callGroupBy(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    receiver: Value,
) Error!Value {
    _ = member;
    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);

    const list = receiver.data.list;
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const groups = try self.heap.createMap(kindOf(callable.signature.return_type), .list, false);
    const result: Value = .{ .data = .{ .map = groups } };
    errdefer self.heap.release(result);

    for (list.items.items) |item| {
        const argument = [_]Value{Heap.retain(item)};
        const key = try self.invokeClosure(expression.span, closure, callable, &argument);
        const hash = try self.hashKey(expression.span, key);
        switch (try self.heap.locate(groups, hash, key)) {
            .entry => |index| {
                const group = groups.entries.items[index].value.data.list;
                group.items.appendAssumeCapacity(Heap.retain(item));
                self.heap.release(key);
            },
            .vacancy => {
                const group = try self.heap.createList(list.element, 1);
                try self.heap.put(groups, hash, key, .{ .data = .{ .list = group } });
                group.items.appendAssumeCapacity(Heap.retain(item));
            },
        }
    }
    return result;
}

fn callFrequencies(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    receiver: Value,
) Error!Value {
    _ = call;
    _ = member;
    const list = receiver.data.list;
    const counts = try self.heap.createMap(list.element, .int, false);
    const result: Value = .{ .data = .{ .map = counts } };
    errdefer self.heap.release(result);

    for (list.items.items) |item| {
        const hash = try self.hashKey(expression.span, item);
        switch (try self.heap.locate(counts, hash, item)) {
            .entry => |index| {
                const current = counts.entries.items[index].value.data.int;
                counts.entries.items[index].value = .initInt(current + 1);
            },
            .vacancy => {
                try self.heap.put(counts, hash, Heap.retain(item), .initInt(1));
            },
        }
    }
    return result;
}

/// Section 8.6's keyed extrema. A block result is only a comparison key: the
/// List item remains the answer. Keys are called once per item, left to right,
/// and the first equal key wins.
fn callExtremeBy(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const items = receiver.data.list.items.items;
    if (items.len == 0) return Value.nothing;
    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const minimum = std.mem.eql(u8, member.name, "min_by");

    var chosen = Heap.retain(items[0]);
    errdefer self.heap.release(chosen);
    const first_argument = [_]Value{Heap.retain(items[0])};
    var chosen_key = try self.invokeClosure(expression.span, closure, callable, &first_argument);
    errdefer self.heap.release(chosen_key);
    if (chosen_key.data == .float and std.math.isNan(chosen_key.data.float)) return self.raiseExtremeNaN(expression.span, .keyed);

    for (items[1..]) |item| {
        const argument = [_]Value{Heap.retain(item)};
        const key = try self.invokeClosure(expression.span, closure, callable, &argument);
        errdefer self.heap.release(key);
        const ordering = try self.orderListItems(expression.span, chosen_key.data, chosen_key, key, .keyed);
        const replace = if (minimum) ordering == .gt else ordering == .lt;
        if (!replace) {
            self.heap.release(key);
            continue;
        }
        self.heap.release(chosen);
        self.heap.release(chosen_key);
        chosen = Heap.retain(item);
        chosen_key = key;
    }
    self.heap.release(chosen_key);
    return chosen;
}

/// Section 8.6's paired extrema. Both selections make one pass over the List;
/// an empty List has neither answer, so both tuple positions are `nothing`.
fn callMinMax(self: *Interpreter, expression: *const Ast.Expression, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    return self.listMinMax(expression.span, receiver.data.list);
}

/// Section 8.6's `sort_by`: each item's key is computed once, left to right,
/// then a stable sort by that key reorders the items themselves — `sort`'s
/// items are their own keys, and this is what lets `sort` on a List of
/// `Ordered` structs share the same underlying pass.
fn callSortBy(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const list = receiver.data.list;
    const items = list.items.items;
    const result = try self.heap.createList(list.element, items.len);
    const value: Value = .{ .data = .{ .list = result } };
    errdefer self.heap.release(value);
    if (items.len == 0) return value;

    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const key_kind = kindOf(callable.signature.return_type);

    const keys = try self.gpa.alloc(Value, items.len);
    var built: usize = 0;
    defer {
        for (keys[0..built]) |key| self.heap.release(key);
        self.gpa.free(keys);
    }
    for (items) |item| {
        const argument = [_]Value{Heap.retain(item)};
        keys[built] = try self.invokeClosure(expression.span, closure, callable, &argument);
        built += 1;
    }
    if (key_kind == .float and std.math.isNan(keys[0].data.float)) return self.raiseExtremeNaN(expression.span, .sort_by);

    for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
    try self.sortItemsByKeys(expression.span, key_kind, result.items.items, keys, .sort_by);
    return value;
}

/// Section 8.6's `unique_by`: a block computes a dictionary-eligible key per
/// item, once, left to right; the first item seen for each key is kept, in
/// the List's own order, mirroring what `unique` does by whole-element
/// equality. A private Set of seen keys, released before returning, decides
/// which items pass.
fn callUniqueBy(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const list = receiver.data.list;
    const items = list.items.items;

    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const key_kind = kindOf(callable.signature.return_type);

    const seen = try self.heap.createMap(key_kind, .nothing, true);
    defer self.heap.release(.{ .data = .{ .map = seen } });

    const result = try self.heap.createList(list.element, items.len);
    const value: Value = .{ .data = .{ .list = result } };
    errdefer self.heap.release(value);
    for (items) |item| {
        const argument = [_]Value{Heap.retain(item)};
        const key = try self.invokeClosure(expression.span, closure, callable, &argument);
        const hash = try self.hashKey(expression.span, key);
        switch (try self.heap.locate(seen, hash, key)) {
            .entry => self.heap.release(key),
            .vacancy => {
                try self.heap.put(seen, hash, key, Value.nothing);
                result.items.appendAssumeCapacity(Heap.retain(item));
            },
        }
    }
    return value;
}

/// Section 8.6's sequence-to-dictionary construction. `associate`'s block
/// returns the whole `(key, value)` entry, once per item, left to right;
/// `associate_by`'s returns only the key, and the item itself becomes the
/// value. A later item's key replaces an earlier one's value in place,
/// exactly as an ordinary dictionary assignment does (8.4).
fn callAssociate(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const by_key_only = std.mem.eql(u8, member.name, "associate_by");
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const list = receiver.data.list;
    const items = list.items.items;

    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);
    const callable = self.closureCallable(block.data.closure);
    const closure = block.data.closure;
    const produced = callable.signature.return_type;
    const key_kind = if (by_key_only) kindOf(produced) else kindOf(produced.elements[0]);
    const value_kind = if (by_key_only) list.element else kindOf(produced.elements[1]);

    const map = try self.heap.createMap(key_kind, value_kind, false);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (items) |item| {
        const argument = [_]Value{Heap.retain(item)};
        const produced_value = try self.invokeClosure(expression.span, closure, callable, &argument);
        if (by_key_only) {
            const key = widen(produced_value, key_kind);
            const hash = try self.hashKey(expression.span, key);
            try self.heap.put(map, hash, key, Heap.retain(item));
        } else {
            defer self.heap.release(produced_value);
            const tuple = produced_value.data.tuple;
            const key = widen(Heap.retain(tuple.items[0]), key_kind);
            const value = widen(Heap.retain(tuple.items[1]), value_kind);
            const hash = try self.hashKey(expression.span, key);
            try self.heap.put(map, hash, key, value);
        }
    }
    return result;
}

/// Section 8.6's `to_dictionary`: a List already holding `(key, value)`
/// tuples becomes a Dictionary directly, with no block to say how. The
/// checker recorded the built Dictionary type on this call expression, since
/// an empty List's element kind alone cannot say what a tuple's own two
/// positions held.
fn callToDictionary(self: *Interpreter, expression: *const Ast.Expression, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const list = receiver.data.list;
    const built = self.literal_types.get(expression).?;
    const key_kind = kindOf(built.key.?.*);
    const value_kind = kindOf(built.element.?.*);

    const map = try self.heap.createMap(key_kind, value_kind, false);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);
    for (list.items.items) |item| {
        const tuple = item.data.tuple;
        const key = widen(Heap.retain(tuple.items[0]), key_kind);
        const value = widen(Heap.retain(tuple.items[1]), value_kind);
        const hash = try self.hashKey(expression.span, key);
        try self.heap.put(map, hash, key, value);
    }
    return result;
}

/// Section 8.5's list methods. The checker has proved the receiver is a list,
/// the method exists, and the arguments fit it.
///
/// A method that changes the list works on the list where it is stored, found
/// the same way an element assignment finds its target: the receiver's indices
/// and then the arguments are evaluated, left to right, and only then is the
/// list walked to and made unique. A method that only reads works on the
/// receiver's value.
fn callMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    if (std.mem.eql(u8, member.name, "next") or std.mem.eql(u8, member.name, "choose") or
        (std.mem.eql(u8, member.name, "shuffle!") and call.arguments.len == 1))
    {
        return self.callRandomMethod(expression, call, member);
    }
    // Decided by the checker from the receiver's type, so a struct's own
    // `append` or `each` is never mistaken for a collection's.
    if (self.method_calls.get(call.callee)) |key| return self.callStructMethod(expression, call, member, key);
    // Section 4.5's way out of an optional, and the one method allowed on a
    // value that may be absent.
    if (std.mem.eql(u8, member.name, "or")) return self.callOr(expression, call, member);
    if (std.mem.eql(u8, member.name, "reduce")) return self.callReduce(expression, call, member);
    if (std.mem.eql(u8, member.name, "reduce_right")) return self.callReduceRight(expression, call, member);
    if (std.mem.eql(u8, member.name, "partition")) {
        const receiver = try self.evaluate(member.base);
        defer self.heap.release(receiver);
        if (receiver.data == .list) return self.callPartition(expression, call, member, receiver);
    }
    if (std.mem.eql(u8, member.name, "group_by")) {
        const receiver = try self.evaluate(member.base);
        defer self.heap.release(receiver);
        if (receiver.data == .list) return self.callGroupBy(expression, call, member, receiver);
    }
    if (std.mem.eql(u8, member.name, "frequencies")) {
        const receiver = try self.evaluate(member.base);
        defer self.heap.release(receiver);
        if (receiver.data == .list) return self.callFrequencies(expression, call, member, receiver);
    }
    if (std.mem.eql(u8, member.name, "min_by") or std.mem.eql(u8, member.name, "max_by")) return self.callExtremeBy(expression, call, member);
    if (std.mem.eql(u8, member.name, "min_max")) return self.callMinMax(expression, member);
    if (std.mem.eql(u8, member.name, "sort_by")) return self.callSortBy(expression, call, member);
    if (std.mem.eql(u8, member.name, "unique_by")) return self.callUniqueBy(expression, call, member);
    if (std.mem.eql(u8, member.name, "associate") or std.mem.eql(u8, member.name, "associate_by")) return self.callAssociate(expression, call, member);
    if (std.mem.eql(u8, member.name, "to_dictionary")) return self.callToDictionary(expression, member);
    if (std.mem.eql(u8, member.name, "map_keys") or std.mem.eql(u8, member.name, "map_values")) return self.callMapTransform(expression, call, member);
    // A block, on a list, a dictionary, or a set.
    if (std.mem.eql(u8, member.name, "each") or std.mem.eql(u8, member.name, "each_with_index") or std.mem.eql(u8, member.name, "reverse_each") or std.mem.eql(u8, member.name, "map") or
        std.mem.eql(u8, member.name, "filter") or std.mem.eql(u8, member.name, "reject") or std.mem.eql(u8, member.name, "flat_map") or std.mem.eql(u8, member.name, "filter_map") or std.mem.eql(u8, member.name, "take_while") or std.mem.eql(u8, member.name, "drop_while") or std.mem.eql(u8, member.name, "any?") or
        std.mem.eql(u8, member.name, "all?") or std.mem.eql(u8, member.name, "none?") or std.mem.eql(u8, member.name, "one?") or
        std.mem.eql(u8, member.name, "count_where") or
        std.mem.eql(u8, member.name, "find") or std.mem.eql(u8, member.name, "find_index"))
    {
        return self.callHigherOrder(expression, call, member);
    }
    if (std.mem.eql(u8, member.name, "to_set")) return self.callToSet(member);
    if (std.mem.eql(u8, member.name, "zip")) {
        const receiver = try self.evaluate(member.base);
        defer self.heap.release(receiver);
        const arguments = try self.evaluateArguments(call.arguments);
        defer {
            for (arguments) |argument| self.heap.release(argument);
            self.gpa.free(arguments);
        }
        if (arguments.len != 1 or arguments[0].kind() != .list) {
            return self.raise(
                expression.span,
                "`zip` needs one List argument",
                "Pass another List to pair the items up.",
            );
        }
        return self.readListMethod(expression.span, receiver.data.list, member.name, arguments);
    }

    const list_method = Type.list_methods.get(member.name);
    const map_method = Type.map_methods.has(member.name);
    if (list_method == null and !map_method) return self.callValueMethod(expression.span, call, member);

    // Whether it changes what it is called on decides how the receiver is
    // reached, and the receiver is reached exactly once either way. Evaluating
    // it twice would run `input().to_int()` twice, which is a real mistake this
    // file made once.
    const mutates = (list_method != null and list_method.?.mutates) or Type.map_mutators.has(member.name);
    if (!mutates) return self.callReadingMethod(expression, call, member);
    return self.callChangingMethod(expression, call, member);
}

fn callRandomMethod(self: *Interpreter, expression: *const Ast.Expression, call: Ast.Expression.Call, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const instance = receiver.data.struct_value;
    if (std.mem.eql(u8, member.name, "next")) {
        const range = (try self.evaluate(call.arguments[0])).data.range;
        if (range.empty()) return self.raise(expression.span, "`next` cannot choose from an empty Range", "Pass a Range that contains at least one value.");
        return .initInt(self.seededRange(instance, range));
    }
    if (std.mem.eql(u8, member.name, "choose")) {
        const list_value = try self.evaluate(call.arguments[0]);
        defer self.heap.release(list_value);
        const items = list_value.data.list.items.items;
        if (items.len == 0) return Value.nothing;
        return Heap.retain(items[self.seededIndex(instance, items.len)]);
    }

    const path = try self.evaluateReceiverPath(call.arguments[0]);
    defer self.freeSteps(path.steps);
    var temporary = try self.temporaryRoot(path.root);
    defer if (temporary) |value| self.heap.release(value);
    const binding: ?*Binding = if (temporary != null) null else try self.placeBinding(self.rootName(path.root), path.root.span);
    var object: Value = Value.nothing;
    defer self.heap.release(object);
    var slot = if (binding) |found| &found.value.? else &temporary.?;
    if (objectOnPath(slot.*, path.steps)) |in_object| {
        object = Heap.retain(in_object.object);
        slot = try self.containerSlot(expression.span, &object, in_object.rest);
    } else if (path.steps.len > 0) slot = try self.containerSlot(expression.span, slot, path.steps);
    const list = try self.heap.unique(slot);
    self.seededShuffle(instance, list.items.items);
    return Value.nothing;
}

fn seededIndex(self: *Interpreter, instance: *Heap.StructValue, length: usize) usize {
    var engine = std.Random.DefaultPrng.init(@bitCast(instance.fields[0].data.int));
    const source = engine.random();
    const result = source.uintLessThan(usize, length);
    instance.fields[0] = .initInt(@bitCast(source.int(u64)));
    _ = self;
    return result;
}

fn seededRange(self: *Interpreter, instance: *Heap.StructValue, range: Range) i64 {
    const position = self.seededIndex(instance, @intCast(range.count()));
    const distance = @as(i128, position) * range.step_size;
    return @intCast(if (range.descending) @as(i128, range.first) - distance else @as(i128, range.first) + distance);
}

fn seededShuffle(self: *Interpreter, instance: *Heap.StructValue, items: []Value) void {
    var engine = std.Random.DefaultPrng.init(@bitCast(instance.fields[0].data.int));
    const source = engine.random();
    source.shuffle(Value, items);
    instance.fields[0] = .initInt(@bitCast(source.int(u64)));
    _ = self;
}

/// A method that only looks at its receiver, which may therefore be any
/// expression at all.
fn callReadingMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const arguments = try self.evaluateArguments(call.arguments);
    defer {
        for (arguments) |argument| self.heap.release(argument);
        self.gpa.free(arguments);
    }

    // `empty?` and `contains?` belong to strings, lists, and sets alike.
    if (receiver.data == .string) {
        return self.stringMethod(expression.span, receiver.data.string.bytes, member.name, arguments);
    }
    if (receiver.data == .map) {
        return self.readMap(call, member, receiver.data.map, arguments);
    }

    return self.readListMethod(expression.span, receiver.data.list, member.name, arguments);
}

fn callMapTransform(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    if (receiver.data != .map or receiver.data.map.is_set) {
        return self.raiseFmt(
            expression.span,
            "`{s}` needs a Dictionary",
            .{member.name},
            "Map each key or value on a dictionary, as in `ages.map_values { age => age + 1 }`.",
        );
    }

    const block = try self.evaluate(call.arguments[0]);
    defer self.heap.release(block);
    const closure = block.data.closure;
    const callable = self.closureCallable(closure);
    const map = receiver.data.map;
    const changing = std.mem.eql(u8, member.name, "map_keys");
    const key_kind = if (changing) kindOf(callable.signature.return_type) else map.key_kind;
    const value_kind = if (changing) map.value_kind else kindOf(callable.signature.return_type);
    const result = try self.heap.createMap(key_kind, value_kind, false);
    errdefer self.heap.release(.{ .data = .{ .map = result } });

    for (map.entries.items) |entry| {
        const argument = [_]Value{Heap.retain(if (changing) entry.key else entry.value)};
        const produced = try self.invokeClosure(expression.span, closure, callable, &argument);
        errdefer self.heap.release(produced);
        const key = if (changing) widen(produced, key_kind) else widen(Heap.retain(entry.key), key_kind);
        const value = if (changing) widen(Heap.retain(entry.value), value_kind) else widen(produced, value_kind);
        const hash = try self.hashKey(member.name_span, key);
        try self.heap.put(result, hash, key, value);
    }
    return .{ .data = .{ .map = result } };
}

/// A list method that does not change its receiver. Value-producing methods
/// retain their items into a fresh list, preserving list value semantics even
/// when an item is itself a collection or object.
fn readListMethod(self: *Interpreter, span: Source.Span, list: *const Heap.List, name: []const u8, arguments: []const Value) Error!Value {
    const items = list.items.items;
    const Method = enum { @"empty?", @"contains?", chain, chunks, windows, pairs, take, drop, reverse, unique, zip, sum, average, min, max, sort, shuffle, random };
    return switch (std.meta.stringToEnum(Method, name).?) {
        .@"empty?" => .initBool(items.len == 0),
        .@"contains?" => blk: {
            for (items) |item| {
                if (try Value.equals(self.gpa, item, arguments[0])) break :blk .initBool(true);
            }
            break :blk .initBool(false);
        },
        .chain => blk: {
            const other = arguments[0];
            if (other.kind() != .list) return self.raise(
                span,
                "`chain` needs a List, but this is not a List",
                "Pass another List to keep the same element type and append it on the end.",
            );
            const right = other.data.list;
            const result = try self.heap.createList(list.element, items.len + right.items.items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            for (right.items.items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            break :blk value;
        },
        .chunks => blk: {
            const width = arguments[0].data.int;
            if (width < 1) return self.raiseFmt(
                span,
                "`chunks` cannot use size {d}",
                .{width},
                "Pass a whole number greater than 0, as in `items.chunks(3)`.",
            );
            const result = try self.heap.createList(.list, if (items.len == 0) 0 else (items.len + @as(usize, @intCast(width)) - 1) / @as(usize, @intCast(width)));
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            var start: usize = 0;
            while (start < items.len) : (start += @as(usize, @intCast(width))) {
                const end = @min(start + @as(usize, @intCast(width)), items.len);
                const chunk = try self.copyList(list.element, items[start..end]);
                result.items.appendAssumeCapacity(chunk);
            }
            break :blk value;
        },
        .windows => blk: {
            const width = arguments[0].data.int;
            if (width < 1) return self.raiseFmt(
                span,
                "`windows` cannot use size {d}",
                .{width},
                "Pass a whole number greater than 0, as in `items.windows(2)`.",
            );
            const count: usize = if (width > items.len) 0 else items.len - @as(usize, @intCast(width)) + 1;
            const result = try self.heap.createList(.list, count);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            var start: usize = 0;
            while (start + @as(usize, @intCast(width)) <= items.len) : (start += 1) {
                const chunk = try self.copyList(list.element, items[start .. start + @as(usize, @intCast(width))]);
                result.items.appendAssumeCapacity(chunk);
            }
            break :blk value;
        },
        .pairs => blk: {
            const result = try self.heap.createList(.tuple, @max(items.len - 1, 0));
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            for (items[0..@max(items.len - 1, 0)], items[1..]) |left, right| {
                const tuple_items = try self.gpa.alloc(Value, 2);
                const tuple_kinds = try self.gpa.alloc(Value.Kind, 2);
                tuple_items[0] = Heap.retain(left);
                tuple_items[1] = Heap.retain(right);
                tuple_kinds[0] = list.element;
                tuple_kinds[1] = list.element;
                result.items.appendAssumeCapacity(.{ .data = .{ .tuple = try self.heap.createTuple(tuple_items, tuple_kinds) } });
            }
            break :blk value;
        },
        .take, .drop => blk: {
            const requested = arguments[0].data.int;
            if (requested < 0) return self.raiseFmt(
                span,
                "`{s}` cannot use count {d}",
                .{ name, requested },
                "Pass 0 or more items to take or drop.",
            );
            // A count larger than the machine can address still means "all"
            // here, so this stays independent of the interpreter's word size.
            const boundary = if (std.math.cast(usize, requested)) |count| @min(count, items.len) else items.len;
            break :blk if (std.mem.eql(u8, name, "take"))
                self.copyList(list.element, items[0..boundary])
            else
                self.copyList(list.element, items[boundary..]);
        },
        .reverse => blk: {
            const result = try self.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            var index = items.len;
            while (index > 0) {
                index -= 1;
                result.items.appendAssumeCapacity(Heap.retain(items[index]));
            }
            break :blk value;
        },
        .unique => blk: {
            const result = try self.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            outer: for (items) |item| {
                for (result.items.items) |previous| {
                    if (try Value.equals(self.gpa, item, previous)) continue :outer;
                }
                result.items.appendAssumeCapacity(Heap.retain(item));
            }
            break :blk value;
        },
        .zip => blk: {
            const other = arguments[0];
            if (other.kind() != .list) return self.raise(
                span,
                "`zip` needs a List, but this is not a List",
                "Pass another List to pair the items up.",
            );
            const right = other.data.list;
            const limit = @min(items.len, right.items.items.len);
            const result = try self.heap.createList(.tuple, limit);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            for (items[0..limit], right.items.items[0..limit]) |left, right_item| {
                const tuple_items = try self.gpa.alloc(Value, 2);
                const tuple_kinds = try self.gpa.alloc(Value.Kind, 2);
                tuple_items[0] = Heap.retain(left);
                tuple_items[1] = Heap.retain(right_item);
                tuple_kinds[0] = list.element;
                tuple_kinds[1] = right.element;
                result.items.appendAssumeCapacity(.{ .data = .{ .tuple = try self.heap.createTuple(tuple_items, tuple_kinds) } });
            }
            break :blk value;
        },
        .sum => self.sumList(span, list),
        .average => averageList(list),
        .min, .max => self.listExtreme(span, list, std.mem.eql(u8, name, "min")),
        .sort => blk: {
            if (list.element == .float and items.len > 0 and std.math.isNan(items[0].data.float)) return self.raiseExtremeNaN(span, .sort);
            const result = try self.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            try self.sortItemsByKeys(span, list.element, result.items.items, null, .sort);
            break :blk value;
        },
        .shuffle => blk: {
            const result = try self.heap.createList(list.element, items.len);
            const value: Value = .{ .data = .{ .list = result } };
            errdefer self.heap.release(value);
            for (items) |item| result.items.appendAssumeCapacity(Heap.retain(item));
            self.random().shuffle(Value, result.items.items);
            break :blk value;
        },
        .random => if (items.len == 0) Value.nothing else Heap.retain(items[self.random().uintLessThan(usize, items.len)]),
    };
}

/// Section 8.6's first aggregation. Empty numeric Lists have the additive
/// identity, and Int accumulation uses the same checked arithmetic as `+`.
fn sumList(self: *Interpreter, span: Source.Span, list: *const Heap.List) Error!Value {
    return switch (list.element) {
        .int => blk: {
            var total: i64 = 0;
            for (list.items.items) |item| {
                const added = @addWithOverflow(total, item.data.int);
                if (added[1] != 0) return self.raiseFmt(
                    span,
                    "`sum` overflows Int while adding {d} and {d}",
                    .{ total, item.data.int },
                    integer_range_help,
                );
                total = added[0];
            }
            break :blk .initInt(total);
        },
        .float => blk: {
            var total: f64 = 0.0;
            for (list.items.items) |item| total += item.data.float;
            break :blk .initFloat(total);
        },
        else => unreachable, // The checker permits `sum` only on numeric Lists.
    };
}

/// Section 8.6's numeric average. Its result is always Float so a fractional
/// answer from an Int List stays visible; no items have no average. Each item
/// widens as an ordinary Float operation would, then Float arithmetic supplies
/// the established Infinity and NaN behavior.
fn averageList(list: *const Heap.List) Error!Value {
    if (list.items.items.len == 0) return Value.nothing;
    var total: f64 = 0.0;
    switch (list.element) {
        .int => {
            for (list.items.items) |item| total += @floatFromInt(item.data.int);
        },
        .float => {
            for (list.items.items) |item| total += item.data.float;
        },
        else => unreachable, // The checker permits `average` only on numeric Lists.
    }
    return .initFloat(total / @as(f64, @floatFromInt(list.items.items.len)));
}

/// Section 8.6's extrema. Ties retain the first item, and an empty List has no
/// result. The checker has already limited this to the same orderable types as
/// ordinary comparisons; NaN is the one numeric value with no order at all.
fn listExtreme(self: *Interpreter, span: Source.Span, list: *const Heap.List, minimum: bool) Error!Value {
    const items = list.items.items;
    if (items.len == 0) return Value.nothing;
    if (list.element == .float and std.math.isNan(items[0].data.float)) return self.raise(
        span,
        "`min` and `max` cannot order a List containing NaN",
        "Check values with `nan?()` before choosing a minimum or maximum.",
    );

    var chosen = Heap.retain(items[0]);
    errdefer self.heap.release(chosen);
    for (items[1..]) |item| {
        const ordering = try self.orderListItems(span, chosen.data, chosen, item, .ordinary);
        const replace = if (minimum) ordering == .gt else ordering == .lt;
        if (!replace) continue;
        self.heap.release(chosen);
        chosen = Heap.retain(item);
    }
    return chosen;
}

const ExtremeKind = enum { ordinary, keyed, pair, sort, sort_by };

fn raiseExtremeNaN(self: *Interpreter, span: Source.Span, kind: ExtremeKind) Error {
    return self.raise(
        span,
        switch (kind) {
            .ordinary => "`min` and `max` cannot order a List containing NaN",
            .keyed => "`min_by` and `max_by` cannot order a key of NaN",
            .pair => "`min_max` cannot order a List containing NaN",
            .sort => "`sort` cannot order a List containing NaN",
            .sort_by => "`sort_by` cannot order a key of NaN",
        },
        switch (kind) {
            .ordinary, .keyed, .pair => "Check values with `nan?()` before choosing a minimum or maximum.",
            .sort => "Check values with `nan?()` before sorting the List.",
            .sort_by => "Return a key that is not NaN, checking it with `nan?()` when needed.",
        },
    );
}

fn orderListItems(self: *Interpreter, span: Source.Span, kind: Value.Kind, left: Value, right: Value, extreme: ExtremeKind) Error!std.math.Order {
    return switch (kind) {
        .int => std.math.order(left.data.int, right.data.int),
        .float => {
            if (std.math.isNan(left.data.float) or std.math.isNan(right.data.float)) return self.raiseExtremeNaN(span, extreme);
            return std.math.order(left.data.float, right.data.float);
        },
        .string => unicode.order(self.gpa, left.data.string.bytes, right.data.string.bytes),
        .struct_value => blk: {
            const compared = try self.callOperator(span, Ast.OperatorContract.ordered.method, left, right);
            defer self.heap.release(compared);
            break :blk std.math.order(compared.data.int, 0);
        },
        else => unreachable, // The checker permits ordering only Ints, Floats, Strings, and `Ordered` structs.
    };
}

/// A stable insertion sort for `sort`, `sort!`, and `sort_by`, whose
/// comparisons may themselves fail — a `NaN` float, or a user
/// `Ordered.compare` that raises. `keys`, when given, is reordered in lock
/// step with `items`, so `sort_by`'s already-computed keys stay lined up with
/// the items they came from; without one, `items` is compared directly.
/// Insertion sort is stable, so items whose keys tie keep their input order,
/// matching every other List traversal (8.6).
fn sortItemsByKeys(
    self: *Interpreter,
    span: Source.Span,
    kind: Value.Kind,
    items: []Value,
    keys: ?[]Value,
    extreme: ExtremeKind,
) Error!void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0) {
            const left = if (keys) |k| k[j - 1] else items[j - 1];
            const right = if (keys) |k| k[j] else items[j];
            if (try self.orderListItems(span, kind, left, right, extreme) != .gt) break;
            std.mem.swap(Value, &items[j - 1], &items[j]);
            if (keys) |k| std.mem.swap(Value, &k[j - 1], &k[j]);
            j -= 1;
        }
    }
}

fn listMinMax(self: *Interpreter, span: Source.Span, list: *const Heap.List) Error!Value {
    const items = list.items.items;
    if (items.len == 0) return self.extremePair(.nothing, .nothing, .nothing);
    if (list.element == .float and std.math.isNan(items[0].data.float)) return self.raiseExtremeNaN(span, .pair);

    var minimum = Heap.retain(items[0]);
    errdefer self.heap.release(minimum);
    var maximum = Heap.retain(items[0]);
    errdefer self.heap.release(maximum);
    for (items[1..]) |item| {
        if ((try self.orderListItems(span, minimum.data, minimum, item, .pair)) == .gt) {
            self.heap.release(minimum);
            minimum = Heap.retain(item);
        }
        if ((try self.orderListItems(span, maximum.data, maximum, item, .pair)) == .lt) {
            self.heap.release(maximum);
            maximum = Heap.retain(item);
        }
    }
    return self.extremePair(list.element, minimum, maximum);
}

/// Builds the immutable `(minimum, maximum)` result, taking ownership of both
/// values. Their stored kinds are the List's element kind even when both are
/// `nothing`, because the checker recorded their optional element type.
fn extremePair(self: *Interpreter, kind: Value.Kind, minimum: Value, maximum: Value) Error!Value {
    const items = try self.gpa.alloc(Value, 2);
    const kinds = self.gpa.alloc(Value.Kind, 2) catch |err| {
        self.gpa.free(items);
        return err;
    };
    items[0] = minimum;
    items[1] = maximum;
    kinds[0] = kind;
    kinds[1] = kind;
    const tuple = self.heap.createTuple(items, kinds) catch |err| {
        self.heap.release(minimum);
        self.heap.release(maximum);
        return err;
    };
    return .{ .data = .{ .tuple = tuple } };
}

/// A new list containing one held copy of each value in `items`.
fn copyList(self: *Interpreter, element: Value.Kind, items: []const Value) Error!Value {
    const list = try self.heap.createList(element, items.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (items) |item| list.items.appendAssumeCapacity(Heap.retain(item));
    return result;
}

/// A method that changes its receiver. Section 4.3 and 7.1 let the checker
/// allow this only on a name, possibly reached through indices and struct
/// fields, which is exactly what makes the slot holding it reachable. A tuple
/// position never appears on this path: the checker's `walkToPlaceRoot`
/// rejects one before this runs, since a tuple can never be written through.
/// A receiver written as a name reached through indices and fields, with every
/// index evaluated, left to right. The caller owns `steps`; see `freeSteps`.
const ReceiverPath = struct {
    root: *const Ast.Expression,
    steps: []PlaceStep,
};

fn evaluateReceiverPath(self: *Interpreter, base: *const Ast.Expression) Error!ReceiverPath {
    var path: std.ArrayList(Ast.Step) = .empty;
    defer path.deinit(self.gpa);
    var receiver = base;
    while (true) {
        switch (receiver.data) {
            .index => |index| {
                try path.append(self.gpa, .{ .index = index.index });
                receiver = index.base;
            },
            .member => |inner| {
                // `Registry.names`: a type-level field is the root itself.
                if (self.facts.qualified.contains(receiver)) break;
                try path.append(self.gpa, .{ .field = .{ .name = inner.name, .span = inner.name_span } });
                receiver = inner.base;
            },
            else => break,
        }
    }
    std.mem.reverse(Ast.Step, path.items);

    const steps = try self.gpa.alloc(PlaceStep, path.items.len);
    var built: usize = 0;
    errdefer {
        for (steps[0..built]) |step| switch (step) {
            .index => |index| self.heap.release(index.value),
            .field => {},
        };
        self.gpa.free(steps);
    }
    while (built < steps.len) : (built += 1) {
        steps[built] = switch (path.items[built]) {
            .index => |index_expression| .{ .index = .{ .value = try self.evaluate(index_expression), .span = index_expression.span } },
            .field => |field| .{ .field = field.name },
        };
    }
    return .{ .root = receiver, .steps = steps };
}

/// The name a receiver path's binding is found by: a plain name, or the key of
/// a type-level field (10.4).
fn rootName(self: *Interpreter, root: *const Ast.Expression) []const u8 {
    return switch (root.data) {
        .name => |name| name,
        else => self.facts.qualified.get(root).?,
    };
}

/// A receiver path's root when it is a temporary rather than a binding, which
/// only a path through an object can change (10.1).
fn temporaryRoot(self: *Interpreter, root: *const Ast.Expression) Error!?Value {
    if (root.data == .name or self.facts.qualified.contains(root)) return null;
    return try self.evaluate(root);
}

fn freeSteps(self: *Interpreter, steps: []PlaceStep) void {
    for (steps) |step| switch (step) {
        .index => |index| self.heap.release(index.value),
        .field => {},
    };
    self.gpa.free(steps);
}

/// The binding a place starts from, once section 14.1's lazy initialization
/// has had its turn. A binding a changing method has taken is not available.
fn placeBinding(self: *Interpreter, name: []const u8, span: Source.Span) Error!*Binding {
    try self.reach(self.keyOf(name), span);
    const binding = self.find(name).?;
    if (binding.changing) |method| return self.raiseChanging(span, name, method);
    return binding;
}

fn raiseChanging(self: *Interpreter, span: Source.Span, name: []const u8, change: Heap.Binding.Change) Error {
    const shown = try Resolver.displayKey(self.arena, name);
    if (change.setter) return self.raiseFmt(
        span,
        "`{s}` is being changed by setting `{s}`, so it cannot be used until the setter finishes",
        .{ shown, change.name },
        "A setter has the value it changes to itself while it runs, as a changing method does. Have the setter change only `self`, and read anything else it needs before the assignment.",
    );
    return self.raiseFmt(
        span,
        "`{s}` is being changed by `{s}`, so it cannot be used until that call finishes",
        .{ shown, change.name },
        "A method that changes a value has it to itself while it runs. Pass what the method needs as an argument instead of reaching for it another way.",
    );
}

fn callChangingMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Value {
    const path = try self.evaluateReceiverPath(member.base);
    const receiver = path.root;
    const steps = path.steps;
    defer self.freeSteps(steps);
    // Section 10.1: a temporary can hold an object, and a list in the object
    // is where the change lands.
    var temporary = try self.temporaryRoot(receiver);
    defer if (temporary) |value| self.heap.release(value);

    const arguments = try self.evaluateArguments(call.arguments);
    defer self.gpa.free(arguments);

    // Section 14.1: a non-entry file initializes on first use, which this is,
    // exactly as a plain assignment already reaches before finding its slot.
    const binding: ?*Binding = if (temporary != null) null else self.placeBinding(self.rootName(receiver), receiver.span) catch |err| {
        for (arguments) |argument| self.heap.release(argument);
        return err;
    };
    var object: Value = Value.nothing;
    defer self.heap.release(object);
    var slot = if (binding) |found| &found.value.? else &temporary.?;
    if (objectOnPath(slot.*, steps)) |in_object| {
        object = Heap.retain(in_object.object);
        slot = try self.containerSlot(expression.span, &object, in_object.rest);
    } else if (steps.len > 0) slot = try self.containerSlot(expression.span, slot, steps);

    if (slot.data == .map) {
        defer for (arguments) |argument| self.heap.release(argument);
        return self.changeMap(call, member, try self.heap.uniqueMap(slot), arguments);
    }
    const list = try self.heap.unique(slot);
    return self.mutateList(expression.span, list, member.name, arguments);
}

/// Section 10's instance method on a struct.
///
/// One that only reads `self` gets its receiver as a value, like any argument.
/// One that changes `self` (4.3) takes the receiver out of the place it is
/// reached through, runs, and puts back whatever `self` holds at the end.
/// Taking it out rather than sharing it is what lets `self.items.append(x)`
/// change the list where it lives instead of copying it on every call; while
/// the call runs, the binding the place starts from is marked as taken, so a
/// block or function reaching for it sees an error rather than a half-changed
/// value.
fn callStructMethod(
    self: *Interpreter,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    key: []const u8,
) Error!Value {
    var callable = self.namedCallable(key);
    if (!self.changing_methods.contains(key)) {
        const receiver = try self.evaluate(member.base);
        // Section 10.7: an object runs its own class's version, unless
        // `super` asked for the base class's. The parameters, and so their
        // defaults, are the ones the call was checked against.
        if (!isSuper(member.base)) {
            const version = self.dispatch(expression.span, receiver, key) catch |err| {
                self.heap.release(receiver);
                return err;
            };
            if (version.ptr != key.ptr) callable = self.namedCallable(version);
        }
        const bound = self.evaluateBoundParameters(call, callable.written) catch |err| {
            self.heap.release(receiver);
            return err;
        };
        defer self.gpa.free(bound.values);
        defer if (bound.omitted) |omitted| self.gpa.free(omitted);
        callable.self_value = receiver;
        callable.omitted = bound.omitted;
        return self.invoke(expression.span, callable, bound.values);
    }

    const path = try self.evaluateReceiverPath(member.base);
    defer self.freeSteps(path.steps);
    const temporary = try self.temporaryRoot(path.root);
    defer if (temporary) |value| self.heap.release(value);
    // Section 11.2: through a trait, the version the value's own type has.
    // Only a trait's method can change a value and have another version.
    if (self.trait_infos.contains(key[0..std.mem.lastIndexOf(u8, key, Resolver.method_separator).?])) {
        var root = if (temporary) |value| Heap.retain(value) else Heap.retain((try self.placeBinding(self.rootName(path.root), path.root.span)).value.?);
        defer self.heap.release(root);
        const receiver = try self.elementValue(path.root.span, &root, path.steps);
        defer self.heap.release(receiver);
        const version = try self.dispatch(expression.span, receiver, key);
        if (version.ptr != key.ptr) callable = self.namedCallable(version);
    }
    const bound = try self.evaluateBoundParameters(call, callable.written);
    defer self.gpa.free(bound.values);
    defer if (bound.omitted) |omitted| self.gpa.free(omitted);
    callable.omitted = bound.omitted;
    const arguments = bound.values;

    // Section 10.1: a struct inside an object is taken out of the object's
    // field while it changes, and stored back.
    const start: Value = if (temporary) |value| value else (self.placeBinding(self.rootName(path.root), path.root.span) catch |err| {
        for (arguments) |argument| self.heap.release(argument);
        return err;
    }).value.?;
    if (objectOnPath(start, path.steps)) |in_object| {
        const object = Heap.retain(in_object.object);
        defer self.heap.release(object);
        return self.changeInObject(expression.span, object.data.struct_value, in_object.rest, callable, arguments, .{ .name = member.name });
    }
    const root_name = self.rootName(path.root);

    // A default can read `self`, so it sees the receiver as it is now, before
    // the receiver is taken. The checker has proved no default changes it.
    if (bound.omitted != null) {
        const binding = self.placeBinding(root_name, path.root.span) catch |err| {
            for (arguments) |argument| self.heap.release(argument);
            return err;
        };
        callable.self_value = self.elementValue(path.root.span, &binding.value.?, path.steps) catch |err| {
            for (arguments) |argument| self.heap.release(argument);
            return err;
        };
    }

    var take: Take = .{ .root = path.root, .steps = path.steps, .method = member.name };
    var changed: Value = Value.nothing;
    callable.take = &take;
    callable.self_out = &changed;
    const result = self.invoke(expression.span, callable, arguments);

    // Found again rather than kept: the call may have initialized another
    // file, which can move module bindings.
    if (take.slot) |slot| {
        const restored = self.find(root_name).?;
        restored.changing = null;
        slot.* = changed;
        restored.value = take.root_value;
    } else {
        self.heap.release(changed);
    }
    return result;
}

/// Takes a changing method's receiver out of its place and binds it as the
/// callee's `self`, the moment `invoke` has finished evaluating defaults. The
/// place is found as the caller sees it, and a failure here, such as an index
/// out of range, is the caller's, so the callee's scopes, file, and stack frame
/// are set aside meanwhile.
fn takeReceiver(
    self: *Interpreter,
    take: *Take,
    frame: *Environment,
    caller_scopes: std.ArrayList(*Environment),
    caller_file: u32,
) Error!void {
    const callee_scopes = self.scopes;
    const callee_file = self.file;
    const callee_frame = self.call_stack.pop().?;
    self.scopes = caller_scopes;
    self.file = caller_file;
    defer {
        self.scopes = callee_scopes;
        self.file = callee_file;
        self.call_stack.appendAssumeCapacity(callee_frame);
    }

    const root_name = self.rootName(take.root);
    const binding = try self.placeBinding(root_name, take.root.span);
    // The slot lives inside the root's own objects, which `containerSlot` has
    // made unique and nothing else can reach while the binding is taken, so it
    // stays valid for the whole call. A root with no steps is its own slot.
    take.root_value = binding.value.?;
    binding.value = null;
    const slot: *Value = if (take.steps.len == 0) &take.root_value else self.containerSlot(take.root.span, &take.root_value, take.steps) catch |err| {
        binding.value = take.root_value;
        return err;
    };
    const receiver = slot.*;
    slot.* = Value.nothing;
    binding.changing = .{ .name = take.method };
    take.slot = slot;

    // In place of the copy the defaults read, if there was one.
    if (frame.bindings.getPtr("self")) |bound| {
        self.heap.release(bound.value.?);
        bound.value = receiver;
    } else {
        frame.bindings.put(self.gpa, "self", .{ .kind = .struct_value, .value = receiver }) catch |err| {
            slot.* = receiver;
            take.slot = null;
            binding.changing = null;
            binding.value = take.root_value;
            return err;
        };
    }
}

/// Section 8.2's `["red", "green"].to_set()`. Repeats collapse, and the first
/// of each keeps its position, which is what `put` already does.
fn callToSet(self: *Interpreter, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);

    const items = receiver.data.list.items.items;
    const map = try self.heap.createMap(receiver.data.list.element, .nothing, true);
    const result: Value = .{ .data = .{ .map = map } };
    errdefer self.heap.release(result);

    for (items) |item| {
        const hash = try self.hashKey(member.base.span, item);
        try self.heap.put(map, hash, Heap.retain(item), Value.nothing);
    }
    return result;
}

/// A method on an immutable scalar value. None changes its receiver.
fn callValueMethod(self: *Interpreter, span: Source.Span, call: Ast.Expression.Call, member: Ast.Expression.Member) Error!Value {
    const receiver = try self.evaluate(member.base);
    defer self.heap.release(receiver);
    const arguments = try self.evaluateArguments(call.arguments);
    defer {
        for (arguments) |argument| self.heap.release(argument);
        self.gpa.free(arguments);
    }

    if (receiver.data == .range) return self.rangeMethod(span, receiver.data.range, member.name, arguments);
    if (receiver.data == .string) return self.stringMethod(span, receiver.data.string.bytes, member.name, arguments);
    if (receiver.data == .int and !std.mem.eql(u8, member.name, "to_string")) {
        return self.intMethod(span, receiver.data.int, member.name, arguments);
    }
    if (receiver.data == .float and !std.mem.eql(u8, member.name, "to_string")) {
        return self.floatMethod(span, receiver.data.float, member.name, arguments);
    }

    // `to_string` on an `Int`, a `Float`, or a `Bool`: its display.
    var built: std.Io.Writer.Allocating = .init(self.gpa);
    defer built.deinit();
    try receiver.display(&built.writer);
    return .{ .data = .{ .string = try self.heap.createText(try built.toOwnedSlice()) } };
}

fn rangeMethod(self: *Interpreter, span: Source.Span, range: Range, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        @"empty?",
        step,
        reverse,
        to_list,
    };

    return switch (std.meta.stringToEnum(Method, name).?) {
        .@"empty?" => .initBool(range.empty()),
        .step => blk: {
            const distance = arguments[0].data.int;
            if (distance < 1) return self.raiseFmt(
                span,
                "a step must be at least 1, but this is {d}",
                .{distance},
                "The range says which way to count; the step says only how far, as in `10.down_to(0).step(2)`.",
            );
            break :blk .{ .data = .{ .range = range.step(distance) } };
        },
        .reverse => .{ .data = .{ .range = range.reverse() } },
        .to_list => blk: {
            const items = try range.toList(self.gpa);
            const list = try self.heap.createList(.int, items.len);
            const result: Value = .{ .data = .{ .list = list } };
            errdefer self.heap.release(result);
            for (items) |item| list.items.appendAssumeCapacity(.initInt(item));
            break :blk result;
        },
    };
}

/// Section 9.3's integer vocabulary. The checker has proved each argument is
/// an `Int`, leaving only value-dependent failures for the runtime to explain.
fn intMethod(self: *Interpreter, span: Source.Span, value: i64, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        abs,
        clamp,
        @"between?",
        @"zero?",
        @"positive?",
        @"negative?",
        @"even?",
        @"odd?",
        @"multiple_of?",
        digits,
        gcd,
        lcm,
        factorial,
        to_float,
    };

    return switch (std.meta.stringToEnum(Method, name).?) {
        .abs => if (value == std.math.minInt(i64))
            self.raiseFmt(span, "the absolute value of {d} does not fit in Int", .{value}, integer_range_help)
        else
            .initInt(if (value < 0) -value else value),
        .clamp => blk: {
            const minimum = arguments[0].data.int;
            const maximum = arguments[1].data.int;
            try self.requireOrderedBounds(span, "clamp", minimum, maximum);
            break :blk .initInt(@max(minimum, @min(maximum, value)));
        },
        .@"between?" => blk: {
            const minimum = arguments[0].data.int;
            const maximum = arguments[1].data.int;
            try self.requireOrderedBounds(span, "between?", minimum, maximum);
            break :blk .initBool(value >= minimum and value <= maximum);
        },
        .@"zero?" => .initBool(value == 0),
        .@"positive?" => .initBool(value > 0),
        .@"negative?" => .initBool(value < 0),
        .@"even?" => .initBool(@mod(value, 2) == 0),
        .@"odd?" => .initBool(@mod(value, 2) != 0),
        .@"multiple_of?" => blk: {
            const divisor = arguments[0].data.int;
            if (divisor == 0) return self.raise(
                span,
                "`multiple_of?` cannot use zero as its divisor",
                "Pass a nonzero Int. Zero itself is a multiple of every nonzero Int.",
            );
            // Every Int is divisible by -1, including the asymmetric minimum.
            break :blk .initBool(divisor == -1 or @mod(value, divisor) == 0);
        },
        .digits => self.integerDigits(value),
        .gcd => self.integerGcd(span, value, arguments[0].data.int),
        .lcm => self.integerLcm(span, value, arguments[0].data.int),
        .factorial => self.integerFactorial(span, value),
        .to_float => .initFloat(@floatFromInt(value)),
    };
}

fn requireOrderedBounds(self: *Interpreter, span: Source.Span, name: []const u8, minimum: i64, maximum: i64) Error!void {
    if (minimum <= maximum) return;
    return self.raiseFmt(
        span,
        "`{s}` has a minimum of {d}, greater than its maximum of {d}",
        .{ name, minimum, maximum },
        "Put the lower bound first and the upper bound second.",
    );
}

/// The unsigned magnitude avoids overflowing on the one `Int` whose positive
/// counterpart cannot be represented.
fn integerMagnitude(value: i64) u64 {
    if (value >= 0) return @intCast(value);
    return @as(u64, @intCast(-(value + 1))) + 1;
}

fn integerDigits(self: *Interpreter, value: i64) Error!Value {
    var magnitude = integerMagnitude(value);
    var reversed: [20]i64 = undefined;
    var count: usize = 0;
    if (magnitude == 0) {
        reversed[0] = 0;
        count = 1;
    } else {
        while (magnitude != 0) : (magnitude /= 10) {
            reversed[count] = @intCast(magnitude % 10);
            count += 1;
        }
    }

    const list = try self.heap.createList(.int, count);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    while (count > 0) {
        count -= 1;
        list.items.appendAssumeCapacity(.initInt(reversed[count]));
    }
    return result;
}

fn unsignedGcd(a_value: u64, b_value: u64) u64 {
    var a = a_value;
    var b = b_value;
    while (b != 0) {
        const remainder = a % b;
        a = b;
        b = remainder;
    }
    return a;
}

fn checkedMagnitude(self: *Interpreter, span: Source.Span, operation: []const u8, magnitude: u64) Error!Value {
    if (magnitude > std.math.maxInt(i64)) return self.raiseFmt(
        span,
        "the result of `{s}` does not fit in Int",
        .{operation},
        integer_range_help,
    );
    return .initInt(@intCast(magnitude));
}

fn integerGcd(self: *Interpreter, span: Source.Span, left: i64, right: i64) Error!Value {
    return self.checkedMagnitude(span, "gcd", unsignedGcd(integerMagnitude(left), integerMagnitude(right)));
}

fn integerLcm(self: *Interpreter, span: Source.Span, left: i64, right: i64) Error!Value {
    const a = integerMagnitude(left);
    const b = integerMagnitude(right);
    if (a == 0 or b == 0) return .initInt(0);
    const divided = a / unsignedGcd(a, b);
    const result = @mulWithOverflow(divided, b);
    if (result[1] != 0 or result[0] > std.math.maxInt(i64)) return self.raiseFmt(
        span,
        "the least common multiple of {d} and {d} does not fit in Int",
        .{ left, right },
        integer_range_help,
    );
    return .initInt(@intCast(result[0]));
}

fn integerFactorial(self: *Interpreter, span: Source.Span, value: i64) Error!Value {
    if (value < 0) return self.raiseFmt(
        span,
        "a negative Int has no factorial, but this is {d}",
        .{value},
        "Call `factorial()` on 0 or a positive Int.",
    );

    var result: i64 = 1;
    var factor: i64 = 2;
    while (factor <= value) : (factor += 1) {
        const multiplied = @mulWithOverflow(result, factor);
        if (multiplied[1] != 0) return self.raiseFmt(
            span,
            "{d}! does not fit in Int",
            .{value},
            "The largest factorial an Int can hold is 20!.",
        );
        result = multiplied[0];
    }
    return .initInt(result);
}

/// Section 9.3's floating-point vocabulary. Rounding operations that return an
/// `Int` all pass through one range and finiteness check before host conversion.
fn floatMethod(self: *Interpreter, span: Source.Span, value: f64, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        abs,
        clamp,
        @"between?",
        @"zero?",
        @"positive?",
        @"negative?",
        square_root,
        to_radians,
        to_degrees,
        floor,
        ceil,
        round,
        round_to,
        truncate,
        @"finite?",
        @"infinite?",
        @"nan?",
        to_int,
    };

    return switch (std.meta.stringToEnum(Method, name).?) {
        .abs => .initFloat(@abs(value)),
        .clamp => blk: {
            const minimum = toFloat(arguments[0]);
            const maximum = toFloat(arguments[1]);
            try self.requireFloatBounds(span, "clamp", minimum, maximum);
            break :blk .initFloat(if (value < minimum) minimum else if (value > maximum) maximum else value);
        },
        .@"between?" => blk: {
            const minimum = toFloat(arguments[0]);
            const maximum = toFloat(arguments[1]);
            try self.requireFloatBounds(span, "between?", minimum, maximum);
            break :blk .initBool(value >= minimum and value <= maximum);
        },
        .@"zero?" => .initBool(value == 0),
        .@"positive?" => .initBool(value > 0),
        .@"negative?" => .initBool(value < 0),
        .square_root => .initFloat(std.math.sqrt(value)),
        .to_radians => .initFloat(value * std.math.pi / 180.0),
        .to_degrees => .initFloat(value * 180.0 / std.math.pi),
        .floor => self.floatResultToInt(span, "floor", @floor(value)),
        .ceil => self.floatResultToInt(span, "ceil", @ceil(value)),
        .round => self.floatResultToInt(span, "round", @round(value)),
        .round_to => .initFloat(roundFloatTo(value, arguments[0].data.int)),
        .truncate, .to_int => self.floatResultToInt(span, name, @trunc(value)),
        .@"finite?" => .initBool(std.math.isFinite(value)),
        .@"infinite?" => .initBool(std.math.isInf(value)),
        .@"nan?" => .initBool(std.math.isNan(value)),
    };
}

fn requireFloatBounds(self: *Interpreter, span: Source.Span, name: []const u8, minimum: f64, maximum: f64) Error!void {
    if (std.math.isNan(minimum) or std.math.isNan(maximum)) return self.raiseFmt(
        span,
        "`{s}` cannot use NaN as a bound",
        .{name},
        "Use ordered Float bounds. NaN is not less than, equal to, or greater than any value.",
    );
    if (minimum <= maximum) return;

    var minimum_text: std.Io.Writer.Allocating = .init(self.gpa);
    defer minimum_text.deinit();
    try Value.initFloat(minimum).display(&minimum_text.writer);
    var maximum_text: std.Io.Writer.Allocating = .init(self.gpa);
    defer maximum_text.deinit();
    try Value.initFloat(maximum).display(&maximum_text.writer);
    return self.raiseFmt(
        span,
        "`{s}` has a minimum of {s}, greater than its maximum of {s}",
        .{ name, minimum_text.written(), maximum_text.written() },
        "Put the lower bound first and the upper bound second.",
    );
}

/// Converts an already-rounded Float only after proving Zig's `@intFromFloat`
/// is defined. The upper comparison is inclusive because 2^63 is exactly
/// representable as a Float but is one beyond the greatest `Int`.
fn floatResultToInt(self: *Interpreter, span: Source.Span, operation: []const u8, value: f64) Error!Value {
    if (!std.math.isFinite(value)) return self.raiseFmt(
        span,
        "`{s}` cannot produce an Int from a non-finite Float",
        .{operation},
        "Check `finite?()` first. NaN and infinity cannot be represented by Int.",
    );
    if (value >= 9223372036854775808.0 or value < -9223372036854775808.0) return self.raiseFmt(
        span,
        "the result of `{s}` is outside the range of Int",
        .{operation},
        integer_range_help,
    );
    return .initInt(@intFromFloat(value));
}

/// Decimal-place rounding over binary64. Scaling that would overflow on the
/// right of the decimal point means the requested precision cannot change the
/// stored value, while a place beyond the left edge rounds a finite value to
/// signed zero.
fn roundFloatTo(value: f64, places: i64) f64 {
    if (!std.math.isFinite(value) or value == 0) return value;
    if (places > 308) return value;
    if (places < -308) return std.math.copysign(@as(f64, 0), value);

    if (places >= 0) {
        const scale = std.math.pow(f64, 10, @as(f64, @floatFromInt(places)));
        const scaled = value * scale;
        if (!std.math.isFinite(scaled)) return value;
        return @round(scaled) / scale;
    }

    const scale = std.math.pow(f64, 10, @as(f64, @floatFromInt(-places)));
    return @round(value / scale) * scale;
}

/// Section 9.2's string methods, on the receiver's bytes. The checker has
/// proved the method exists and the arguments fit it.
fn stringMethod(self: *Interpreter, span: Source.Span, bytes: []const u8, name: []const u8, arguments: []const Value) Error!Value {
    const Method = enum {
        @"empty?",
        @"blank?",
        @"contains?",
        @"starts_with?",
        @"ends_with?",
        trim,
        trim_start,
        trim_end,
        upper,
        lower,
        capitalize,
        reverse,
        repeat,
        replace,
        insert_at,
        substring,
        remove_prefix,
        remove_suffix,
        collapse_repeats,
        pad_start,
        pad_end,
        pad_center,
        split,
        partition,
        lines,
        chars,
        code_points,
        bytes,
        index_of,
        to_int,
        to_int_or,
        to_int_maybe,
        to_float,
        to_float_or,
        to_float_maybe,
    };
    const gpa = self.gpa;
    return switch (std.meta.stringToEnum(Method, name).?) {
        .@"empty?" => .initBool(bytes.len == 0),
        .@"blank?" => .initBool(strings.isBlank(bytes)),
        .@"contains?" => .initBool(try strings.contains(gpa, bytes, arguments[0].data.string.bytes)),
        .@"starts_with?" => .initBool(try strings.startsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .@"ends_with?" => .initBool(try strings.endsWith(gpa, bytes, arguments[0].data.string.bytes)),
        .trim => self.heap.copyText(strings.trim(bytes, .both)),
        .trim_start => self.heap.copyText(strings.trim(bytes, .start)),
        .trim_end => self.heap.copyText(strings.trim(bytes, .end)),
        .upper => self.ownedText(try unicode.mapCase(gpa, bytes, .upper)),
        .lower => self.ownedText(try unicode.mapCase(gpa, bytes, .lower)),
        .capitalize => self.ownedText(try strings.capitalize(gpa, bytes)),
        .reverse => self.ownedText(try strings.reverse(gpa, bytes)),
        .repeat => blk: {
            const times = arguments[0].data.int;
            if (times < 0) return self.raiseFmt(
                span,
                "a String cannot be repeated {d} times",
                .{times},
                "Repeat it 0 or more times; 0 gives an empty String.",
            );
            // A result too large to address is as unrepresentable as one too
            // large to allocate.
            const size = std.math.mul(usize, bytes.len, @intCast(times)) catch return error.OutOfMemory;
            const result = try gpa.alloc(u8, size);
            for (0..@intCast(times)) |copy| @memcpy(result[copy * bytes.len ..][0..bytes.len], bytes);
            break :blk self.ownedText(result);
        },
        .replace => blk: {
            const old = arguments[0].data.string.bytes;
            if (old.len == 0) return self.raise(
                span,
                "`replace` needs something to replace, but this is an empty String",
                "Pass the text to find as the first argument.",
            );
            break :blk self.ownedText(try strings.replace(gpa, bytes, old, arguments[1].data.string.bytes));
        },
        .insert_at => blk: {
            const index = arguments[0].data.int;
            const result = strings.insertAt(gpa, bytes, index, arguments[1].data.string.bytes) catch |err| {
                if (err == error.NegativeIndex or err == error.IndexPastEnd) return self.raiseInsert(span, bytes, index, @errorCast(err));
                return error.OutOfMemory;
            };
            break :blk self.ownedText(result);
        },
        .substring => blk: {
            const start = arguments[0].data.int;
            const count: ?i64 = if (arguments.len == 2) arguments[1].data.int else null;
            const slice = strings.substring(bytes, start, count) catch |err| return self.raiseSubstring(span, bytes, start, count, err);
            break :blk self.heap.copyText(slice);
        },
        .remove_prefix => self.heap.copyText(try strings.removePrefix(gpa, bytes, arguments[0].data.string.bytes)),
        .remove_suffix => self.heap.copyText(try strings.removeSuffix(gpa, bytes, arguments[0].data.string.bytes)),
        .collapse_repeats => self.ownedText(try strings.collapseRepeats(gpa, bytes)),
        .pad_start, .pad_end, .pad_center => blk: {
            const width = arguments[0].data.int;
            const fill = if (arguments.len == 2) arguments[1].data.string.bytes else " ";
            const side: strings.PadSide = switch (std.meta.stringToEnum(Method, name).?) {
                .pad_start => .start,
                .pad_end => .end,
                .pad_center => .center,
                else => unreachable,
            };
            const result = strings.pad(gpa, bytes, width, fill, side) catch |err| {
                if (err == error.NegativeWidth or err == error.EmptyFill or err == error.MultipleCharacterFill) return self.raisePadding(span, width, fill, @errorCast(err));
                return error.OutOfMemory;
            };
            break :blk self.ownedText(result);
        },
        .split => blk: {
            const separator = arguments[0].data.string.bytes;
            if (separator.len == 0) return self.raise(
                span,
                "`split` needs a separator, but this is an empty String",
                "Use `chars()` to split a String into its characters.",
            );
            break :blk self.stringList(try strings.split(gpa, bytes, separator));
        },
        .partition => blk: {
            const separator = arguments[0].data.string.bytes;
            if (separator.len == 0) return self.raise(
                span,
                "`partition` needs a separator, but this is an empty String",
                "Pass the text to find as the separator.",
            );
            const parts = try strings.partition(gpa, bytes, separator);
            break :blk self.stringTuple(parts);
        },
        .lines => self.stringList(try strings.lines(gpa, bytes)),
        .chars => blk: {
            const pieces = try strings.characters(gpa, bytes);
            defer gpa.free(pieces);
            const list = try self.heap.createList(.string, pieces.len);
            const result: Value = .{ .data = .{ .list = list } };
            errdefer self.heap.release(result);
            for (pieces) |piece| list.items.appendAssumeCapacity(try self.heap.copyText(piece));
            break :blk result;
        },
        // These deliberately expose the exact stored representation rather
        // than graphemes. `chars()` remains the beginner-facing operation.
        .code_points => self.stringCodePoints(bytes),
        .bytes => self.stringBytes(bytes),
        // Section 9.2: the answer counts characters, so it indexes directly.
        .index_of => blk: {
            const found = try strings.indexOf(gpa, bytes, arguments[0].data.string.bytes);
            break :blk if (found) |index| Value.initInt(index) else Value.nothing;
        },
        // Section 4.4's three forms differ only in what they do when the text
        // does not parse: raise, use the fallback, or report absence.
        .to_int => blk: {
            const parsed = strings.parseInt(bytes);
            if (parsed == .value) break :blk .initInt(parsed.value);
            break :blk self.raiseConversion(span, bytes, "Int", parsed == .out_of_range);
        },
        .to_int_or => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else arguments[0];
        },
        .to_int_maybe => blk: {
            const parsed = strings.parseInt(bytes);
            break :blk if (parsed == .value) Value.initInt(parsed.value) else Value.nothing;
        },
        .to_float => blk: {
            const parsed = strings.parseFloat(bytes);
            if (parsed == .value) break :blk .initFloat(parsed.value);
            break :blk self.raiseConversion(span, bytes, "Float", parsed == .out_of_range);
        },
        .to_float_or => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else widen(arguments[0], .float);
        },
        .to_float_maybe => blk: {
            const parsed = strings.parseFloat(bytes);
            break :blk if (parsed == .value) Value.initFloat(parsed.value) else Value.nothing;
        },
    };
}

/// Section 9.1's advanced conversions. A String is always valid UTF-8, so
/// each call to `unicode.decode` is safe. Code points retain the original
/// spelling: a decomposed character therefore gives its separate scalars.
fn stringCodePoints(self: *Interpreter, bytes: []const u8) Error!Value {
    const list = try self.heap.createList(.int, bytes.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);

    var index: usize = 0;
    while (index < bytes.len) {
        const point, const length = unicode.decode(bytes, index);
        list.items.appendAssumeCapacity(.initInt(point));
        index += length;
    }
    return result;
}

/// UTF-8 bytes are represented as non-negative Ints until Emerald gains a
/// purpose-built binary-data type. This keeps `bytes()` honest without making
/// beginners learn an implementation-only `Byte` type.
fn stringBytes(self: *Interpreter, bytes: []const u8) Error!Value {
    const list = try self.heap.createList(.int, bytes.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (bytes) |byte| list.items.appendAssumeCapacity(.initInt(byte));
    return result;
}

fn ownedText(self: *Interpreter, bytes: []u8) Error!Value {
    return .{ .data = .{ .string = try self.heap.createText(bytes) } };
}

/// A list of strings from pieces the caller allocated, which the strings take.
fn stringList(self: *Interpreter, pieces: [][]u8) Error!Value {
    defer self.gpa.free(pieces);
    var taken: usize = 0;
    errdefer for (pieces[taken..]) |piece| self.gpa.free(piece);

    const list = try self.heap.createList(.string, pieces.len);
    const result: Value = .{ .data = .{ .list = list } };
    errdefer self.heap.release(result);
    for (pieces) |piece| {
        taken += 1;
        list.items.appendAssumeCapacity(.{ .data = .{ .string = try self.heap.createText(piece) } });
    }
    return result;
}

/// A three-part String tuple. The pieces borrow their receiver until copied.
fn stringTuple(self: *Interpreter, parts: struct { []const u8, []const u8, []const u8 }) Error!Value {
    const items = try self.gpa.alloc(Value, 3);
    const kinds = self.gpa.alloc(Value.Kind, 3) catch |err| {
        self.gpa.free(items);
        return err;
    };
    kinds[0] = .string;
    kinds[1] = .string;
    kinds[2] = .string;
    var built: usize = 0;
    errdefer {
        for (items[0..built]) |item| self.heap.release(item);
        self.gpa.free(items);
        self.gpa.free(kinds);
    }
    inline for (parts) |part| {
        items[built] = try self.heap.copyText(part);
        built += 1;
    }
    return .{ .data = .{ .tuple = try self.heap.createTuple(items, kinds) } };
}

/// Section 9.4's strict parsing, which raises a conversion error. Catching it
/// arrives with section 13; until then `to_int_or` is the way to recover.
fn raiseConversion(self: *Interpreter, span: Source.Span, bytes: []const u8, comptime type_name: []const u8, out_of_range: bool) Error {
    const excerpt = if (bytes.len > 40) "the text" else try std.fmt.allocPrint(self.arena, "\"{s}\"", .{bytes});
    if (out_of_range) return self.raiseFmt(
        span,
        "{s} is outside the range of " ++ type_name,
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807. `to_int_or(0)` gives a fallback instead of an error."
        else
            "The number is too large for a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
    return self.raiseFmt(
        span,
        "{s} is not " ++ (if (std.mem.eql(u8, type_name, "Int")) "a whole number" else "a number"),
        .{excerpt},
        if (std.mem.eql(u8, type_name, "Int"))
            "Only digits, with an optional sign and surrounding spaces, convert to an Int. `to_int_or(0)` gives a fallback instead of an error."
        else
            "Only a number such as `2.5` or `3`, with an optional sign and surrounding spaces, converts to a Float. `to_float_or(0.0)` gives a fallback instead of an error.",
    );
}

/// Section 9.1: substring bounds are errors rather than being clamped.
fn raiseSubstring(self: *Interpreter, span: Source.Span, bytes: []const u8, start: i64, count: ?i64, err: strings.SubstringError) Error {
    const total = unicode.graphemeCount(bytes);
    return switch (err) {
        error.NegativeStart => self.raiseFmt(span, "a substring cannot start at {d}", .{start}, "Start at 0 or later."),
        error.NegativeCount => self.raiseFmt(span, "a substring cannot have {d} characters", .{count.?}, "Ask for 0 or more characters."),
        error.StartPastEnd => self.raiseFmt(
            span,
            "a substring cannot start at {d} in a String of {d} character{s}",
            .{ start, total, if (total == 1) "" else "s" },
            "Start at most at the String's `count`, which gives an empty String.",
        ),
        error.CountPastEnd => self.raiseFmt(
            span,
            "a substring of {d} character{s} from {d} runs past the end of a String of {d}",
            .{ count.?, if (count.? == 1) "" else "s", start, total },
            "Ask for fewer characters, or leave the count out to take the rest of the String.",
        ),
    };
}

fn raiseInsert(self: *Interpreter, span: Source.Span, bytes: []const u8, index: i64, err: strings.InsertError) Error {
    const total = unicode.graphemeCount(bytes);
    return switch (err) {
        error.NegativeIndex => self.raiseFmt(span, "a String insertion cannot use index {d}", .{index}, "Insert at 0 or later."),
        error.IndexPastEnd => self.raiseFmt(
            span,
            "cannot insert at index {d} in a String of {d} character{s}",
            .{ index, total, if (total == 1) "" else "s" },
            "Insert at 0 through the String's `count`; inserting at `count` adds to the end.",
        ),
    };
}

fn raisePadding(self: *Interpreter, span: Source.Span, width: i64, fill: []const u8, err: strings.PadError) Error {
    return switch (err) {
        error.NegativeWidth => self.raiseFmt(span, "a padded String cannot have width {d}", .{width}, "Choose a width of 0 or more characters."),
        error.EmptyFill => self.raise(span, "padding needs a fill character, but this is an empty String", "Pass one character, such as `\"-\"` or `\" \"`."),
        error.MultipleCharacterFill => self.raiseFmt(span, "padding needs one fill character, but \"{s}\" has {d}", .{ fill, unicode.graphemeCount(fill) }, "Pass exactly one character, such as `\"-\"` or `\" \"`."),
    };
}

/// Runs one mutating list method. Arguments are owned: one that is stored is
/// taken by the list, and the rest are released here.
fn mutateList(self: *Interpreter, span: Source.Span, list: *Heap.List, name: []const u8, arguments: []const Value) Error!Value {
    const items = &list.items;
    const Method = enum { append, insert, remove, remove_all, remove_at, remove_first, remove_last, clear, @"reverse!", @"unique!", @"sort!", @"shuffle!" };
    switch (std.meta.stringToEnum(Method, name).?) {
        .append => try items.append(self.gpa, widen(arguments[0], list.element)),
        .insert => {
            const index = arguments[0].data.int;
            if (index < 0 or index > items.items.len) {
                const count = items.items.len;
                const help = try std.fmt.allocPrint(
                    self.arena,
                    "Insert at 0 through {d}. Inserting at {d} adds to the end.",
                    .{ count, count },
                );
                return self.raiseFmt(
                    span,
                    "cannot insert at index {d} in a list of {d} element{s}",
                    .{ index, count, if (count == 1) "" else "s" },
                    help,
                );
            }
            try items.insert(self.gpa, @intCast(index), widen(arguments[1], list.element));
        },
        .remove => {
            defer self.heap.release(arguments[0]);
            for (items.items, 0..) |item, position| {
                if (!try Value.equals(self.gpa, item, arguments[0])) continue;
                self.heap.release(items.orderedRemove(position));
                break;
            }
        },
        .remove_all => {
            defer self.heap.release(arguments[0]);
            var kept: usize = 0;
            for (items.items) |item| {
                if (try Value.equals(self.gpa, item, arguments[0])) {
                    self.heap.release(item);
                } else {
                    items.items[kept] = item;
                    kept += 1;
                }
            }
            items.shrinkRetainingCapacity(kept);
        },
        .remove_at => {
            const position = try self.checkIndex(list, arguments[0].data.int, span);
            return items.orderedRemove(position);
        },
        .remove_first, .remove_last => {
            if (items.items.len == 0) return self.raise(
                span,
                "cannot remove an element from an empty list",
                "Check `empty?()` first.",
            );
            return if (std.mem.eql(u8, name, "remove_first")) items.orderedRemove(0) else items.pop().?;
        },
        .clear => {
            for (items.items) |item| self.heap.release(item);
            items.clearRetainingCapacity();
        },
        .@"reverse!" => std.mem.reverse(Value, items.items),
        .@"unique!" => {
            var kept: usize = 0;
            outer: for (items.items) |item| {
                for (items.items[0..kept]) |previous| {
                    if (try Value.equals(self.gpa, item, previous)) {
                        self.heap.release(item);
                        continue :outer;
                    }
                }
                items.items[kept] = item;
                kept += 1;
            }
            items.shrinkRetainingCapacity(kept);
        },
        .@"sort!" => {
            if (list.element == .float and items.items.len > 0 and std.math.isNan(items.items[0].data.float)) return self.raiseExtremeNaN(span, .sort);
            try self.sortItemsByKeys(span, list.element, items.items, null, .sort);
        },
        .@"shuffle!" => self.random().shuffle(Value, items.items),
    }
    return Value.nothing;
}

/// Section 5.2: arguments evaluate left to right, every one of them before the
/// call itself happens. The caller frees the result.
fn evaluateArguments(self: *Interpreter, expressions: []const *const Ast.Expression) Error![]Value {
    const values = try self.gpa.alloc(Value, expressions.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| self.heap.release(value);
        self.gpa.free(values);
    }
    for (expressions, values) |expression, *value| {
        value.* = try self.evaluate(expression);
        initialized += 1;
    }
    return values;
}

// Raising.

const integer_range_help =
    "`Int` holds whole numbers from -9223372036854775808 through 9223372036854775807.";

/// Every runtime error carries the calls active when it was raised, innermost
/// first, which is section 13.2's stack trace.
fn raise(self: *Interpreter, span: Source.Span, message: []const u8, help: []const u8) Error {
    self.raised_value = try self.makeError(Resolver.preludeKey("RuntimeError"), message);
    return self.raiseTyped(span, "", message, help);
}

fn makeError(self: *Interpreter, key: []const u8, message: []const u8) RunError!Value {
    const text = try self.heap.copyText(message);
    const fields = try self.gpa.alloc(Value, 1);
    fields[0] = text;
    return .{ .data = .{ .struct_value = try self.heap.createStruct(self.structs.get(key).?, fields) } };
}

fn raiseTyped(self: *Interpreter, span: Source.Span, type_name: []const u8, message: []const u8, help: []const u8) Error {
    const trace = try self.arena.alloc(Diagnostic.Frame, self.call_stack.items.len);
    for (trace, 0..) |*frame, index| {
        frame.* = self.call_stack.items[self.call_stack.items.len - 1 - index];
    }
    self.failure = .{
        .message = if (type_name.len == 0) try self.arena.dupe(u8, message) else try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ type_name, message }),
        .span = span,
        .help = try self.arena.dupe(u8, help),
        .trace = trace,
        .file = self.file,
    };
    return error.Raised;
}

fn raiseFmt(
    self: *Interpreter,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error {
    const message = try std.fmt.allocPrint(self.arena, message_format, message_args);
    return self.raise(span, message, help);
}

fn raiseUnassigned(self: *Interpreter, span: Source.Span, name: []const u8) Error {
    const help = try std.fmt.allocPrint(self.arena, "Assign `{s}` before reading it.", .{name});
    return self.raise(span, try std.fmt.allocPrint(self.arena, "`{s}` is not assigned yet", .{name}), help);
}

fn raiseDivisionByZero(
    self: *Interpreter,
    span: Source.Span,
    operator: Ast.BinaryOperator,
) Error {
    return self.raiseFmt(
        span,
        "{s} by zero",
        .{operator.describe()},
        "Check the divisor before dividing. Division by zero has no result for either numeric type.",
    );
}

/// Section 7.2: crossing the limit raises rather than exhausting the host
/// stack, and the trace attached by `raise` summarizes the repeating frames.
/// `at_limit` distinguishes reaching the 1,000-call guarantee from running out
/// of stack before it, which only a pathologically nested body can do.
fn raiseTooMuchRecursion(self: *Interpreter, span: Source.Span, name: []const u8, at_limit: bool) Error {
    // A program's own names never hold a space; a description such as "the
    // constructor of `Node`" or "a block" already reads as prose.
    const quote = if (std.mem.indexOfScalar(u8, name, ' ') == null) "`" else "";
    return self.raiseFmt(
        span,
        "too much recursion calling {s}{s}{s}",
        .{ quote, name, quote },
        if (at_limit)
            "Emerald supports at least 1,000 active calls. Check that the recursion has a case that stops it."
        else
            "These calls nest too deeply for the stack available. Check that the recursion has a case that stops it.",
    );
}

/// Callers check `isNumber` first, so a `Bool` never reaches here.
fn toFloat(value: Value) f64 {
    return switch (value.data) {
        .int => |number| @floatFromInt(number),
        .float => |number| number,
        .range => unreachable,
        .nothing, .bool, .string, .list, .tuple, .map, .closure, .struct_value => unreachable,
    };
}

test "a NaN nested in a struct is detected for key rejection" {
    const testing = std.testing;
    var heap: Heap = .init(testing.allocator);
    defer heap.deinit();

    const metadata = [_]Value.StructType.Field{.{ .name = "x", .kind = .float }};
    const descriptor: Value.StructType = .{
        .name = "Point",
        .display_name = "Point",
        .fields = &metadata,
    };
    const fields = try testing.allocator.alloc(Value, 1);
    fields[0] = .initFloat(std.math.nan(f64));
    const point: Value = .{
        .data = .{ .struct_value = try heap.createStruct(&descriptor, fields) },
    };
    defer heap.release(point);

    try testing.expect(holdsNan(point));
}
