//! Static type checking and flow analysis.
//!
//! Section 4.1 requires every expression to have a type before execution, locals
//! to be inferred from their initializers, an uninitialized variable to carry an
//! explicit type, and definite assignment to be proved through control flow
//! rather than papered over with a default value.
//!
//! This runs after name resolution, so every name is known to reach a binding
//! and the work here is only about types and assignment state.
//!
//! Errors do not cascade. An expression whose type could not be determined gets
//! `Type.invalid`, which is compatible with everything, so one mistake produces
//! one diagnostic rather than one per enclosing expression. Section 17.2 asks
//! for exactly that.
//!
//! # Functions
//!
//! The top level is checked in the order it is written, since that order is
//! what definite assignment follows. Function bodies are checked afterwards,
//! each against a view of the module scope in which every variable counts as
//! assigned. A function may run at any point after the top level begins —
//! declarations are hoisted — so nothing about the state at the point where it
//! happens to be written can apply inside it.
//!
//! What the view gives up, the call sites take back. Section 7.1 says hoisting
//! "never permits reading an uninitialized captured variable", so each call made
//! from top-level code checks that every module variable the callee reads,
//! directly or through the functions it calls, is already assigned there.
//!
//! A call can need a function's return type before that function's body has been
//! checked. With an annotation, or with no value-returning `return` at all, the
//! type is known without looking inside. Otherwise it is inferred on the spot,
//! which section 7.2 permits only for a function that is not recursive.

const std = @import("std");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Project = @import("Project.zig");
const Resolver = @import("Resolver.zig");
const Source = @import("Source.zig");
const Type = @import("Type.zig");
const call_arguments = @import("arguments.zig");

const Checker = @This();

pub const Checked = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    /// Every function's checked signature, for the interpreter.
    signatures: Type.Signatures,
    /// The type of every list literal. A literal can be built as a `[Float]`
    /// from whole numbers when that is what is expected, and the interpreter
    /// needs to know so that it can widen them as it stores them.
    literal_types: LiteralTypes,
    /// Checked user-defined struct metadata, also used to build runtime
    /// descriptors without resolving source annotations a second time.
    structs: Structs,
    /// Every instance method that changes `self`, which the interpreter calls
    /// by taking the receiver out of its place and putting it back (4.3).
    changing_methods: Resolver.NameSet,
    /// For every call that reaches an instance method, keyed by its callee
    /// expression, the method's key. Only types can tell `bag.append(1)` on a
    /// struct from the list method of the same name. A method captured as a
    /// value (7.5) is keyed by its member expression the same way.
    method_calls: MethodCalls,
    /// Every `super.name` that reads or sets a base class's property (10.7):
    /// a read by its member expression, mapped to the getter's key, and an
    /// assignment by its value, mapped to the setter's. Unlike `value.name`, which runs whatever
    /// property the object's own class has, these always run this one.
    super_members: MethodCalls,
    /// Section 4.4's `value is Type`, by expression: the value's static type
    /// and the type it is tested for. Only an object's class, and a tuple's
    /// positions holding objects, are not known before the program runs.
    type_tests: TypeTests,
    /// Every `value.type_name`, by member expression, mapped to the value's
    /// static type, which spells everything but the class of an object in it.
    type_names: LiteralTypes,
    /// Every `Trait.method(value, ...)` (11.2), mapped to the default it runs.
    trait_calls: MethodCalls,

    pub fn ok(self: Checked) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Checked) void {
        self.arena_state.deinit();
        self.* = undefined;
    }
};

const Binding = struct {
    /// What the name holds right here, which section 4.5's narrowing can make
    /// more specific than `declared` for as long as the proof holds.
    type: Type,
    /// The type the declaration gave it, which is what an assignment must fit
    /// and what narrowing falls back to.
    declared: Type,
    /// Section 4.1: a variable declared without an initializer stays unassigned
    /// until control flow proves otherwise, and reading it before then is an
    /// error.
    assigned: bool,
    /// A function's name. Its `type` is unused; a call goes through
    /// `signatureFor` instead.
    is_function: bool = false,
    /// A nested function's key (7.1), which is how `signatureFor` knows it.
    /// Null for a program function, whose key is its module key.
    function_key: ?[]const u8 = null,
    /// A user-defined type name. It can be called to construct a value, but it
    /// is not itself a runtime value.
    is_type: bool = false,
    /// Assigned inside a loop and not before it, so unassigned after the loop
    /// only because the loop might not run. Changes the correction a read
    /// before assignment offers, since "every branch" would not describe it.
    assigned_in_loop: bool = false,
    /// Section 4.3 and 7.1: a `const`, a parameter, and a loop variable can
    /// be neither replaced nor, when they hold a list, changed in place.
    mutability: Mutability = .variable,
};

pub const LiteralTypes = std.AutoHashMapUnmanaged(*const Ast.Expression, Type);
pub const Structs = std.StringHashMapUnmanaged(Type);
pub const MethodCalls = std.AutoHashMapUnmanaged(*const Ast.Expression, []const u8);
pub const TypeTest = struct { value: Type, target: Type };
pub const TypeTests = std.AutoHashMapUnmanaged(*const Ast.Expression, TypeTest);

/// Why a binding may or may not change. Each reason gets its own correction,
/// because the fix for a `const` is not the fix for a parameter.
const Mutability = enum { variable, constant, parameter, loop_variable };

const Scope = std.StringHashMapUnmanaged(Binding);

const Signature = Type.Signature;

/// Stated rather than inferred: the walk functions are mutually recursive.
const Error = std.mem.Allocator.Error;

arena: std.mem.Allocator,
/// The scopes in force, innermost last. Pointers rather than values, so the
/// prelude and module scopes keep a stable address while a function body is
/// checked against a different list.
scopes: std.ArrayList(*Scope) = .empty,
prelude: *Scope,
module: *Scope,
diagnostics: std.ArrayList(Diagnostic) = .empty,

facts: Resolver.Facts,
declarations: std.StringHashMapUnmanaged(Ast.FunctionDeclaration) = .empty,
/// User-defined structs, keyed by the same resolved names as module bindings.
structs: Structs = .empty,
/// Every struct declaration, by the same keys.
struct_declarations: std.StringHashMapUnmanaged(Ast.StructDeclaration) = .empty,
/// Where each struct is declared, by the same keys, so section 10.5 can tell
/// whether a private member is reached from inside its braces. The file is
/// the one `facts.owner` records.
type_spans: std.StringHashMapUnmanaged(Source.Span) = .empty,
/// Every struct that declares its own constructor, by the same keys.
constructors: std.StringHashMapUnmanaged(Ast.StructDeclaration) = .empty,
/// For every instance method, keyed like `declarations`, the type it belongs to.
receivers: Structs = .empty,
/// Every computed property's getter key, mapped to whether it has a setter.
properties: std.StringHashMapUnmanaged(bool) = .empty,
/// Memoized by `methodChanges`. Only settled answers are stored.
changes: std.StringHashMapUnmanaged(bool) = .empty,
/// Methods `methodChanges` is working out, so a cycle of calls ends.
changes_in_progress: Resolver.NameSet = .empty,
method_calls: MethodCalls = .empty,
super_members: MethodCalls = .empty,
type_tests: TypeTests = .empty,
type_names: LiteralTypes = .empty,
trait_calls: MethodCalls = .empty,
/// Structs and classes whose fields have been resolved, so a subclass can make
/// sure its base class's come first (10.7).
structs_checked: Resolver.NameSet = .empty,
/// Every nested function (7.1) whose name has been hoisted, mapped to how
/// many scopes were in force where it is declared: the ones its body sees.
nested: std.StringHashMapUnmanaged(usize) = .empty,
/// Section 10.4's type-level fields, by key.
type_fields: std.StringHashMapUnmanaged(TypeField) = .empty,
/// Whether a parameter's default is being checked. Inside a constructor it
/// runs before the body, so it is told what it may read rather than to set a
/// field first.
in_parameter_default: bool = false,
/// The struct whose constructor body is being checked, if any. Section 10.2's
/// rules about `self` apply only here.
constructing: ?Constructing = null,
/// Memoized by `signatureFor`.
signatures: Type.Signatures = .empty,
/// Functions whose return type is being inferred right now. Reaching one of
/// these again can only happen through a type-level field's value (10.4),
/// since the call graph has already ruled out recursion.
inferring: Resolver.NameSet = .empty,
/// Bodies already checked, so each is checked exactly once whichever of
/// inference or the deferred pass reaches it first.
bodies_checked: Resolver.NameSet = .empty,
/// Memoized by `capturesOf`.
captures: std.StringHashMapUnmanaged(Resolver.NameSet) = .empty,
/// The enclosing function's return type while checking its body. Null means a
/// return type is still being inferred, and `return expr` records its value's
/// type in `pending_return_types` instead of checking it.
current_return_type: ?Type = null,
/// Whether `return` is legal here. Section 14.1's top-level `return`, which
/// ends the program, is deferred, so it is rejected outside a function.
in_function: bool = false,
pending_return_types: std.ArrayList(Type) = .empty,
literal_types: LiteralTypes = .empty,
/// Field metadata is completed for every struct before recursive key
/// eligibility is judged, so declaration order cannot change the answer.
resolving_struct_fields: bool = false,
/// What `Self` means in the types being resolved: the type whose method's
/// parameters and result they are (11.4), or null where `Self` means nothing.
written_self: ?Type = null,
/// Section 6.3's cases whose arms cover every value their subject can have,
/// with or without `else`. A statement `case` among them cannot finish without
/// running an arm, which is what `stmtCompletes` needs to know.
exhaustive_cases: std.AutoHashMapUnmanaged(*const Ast.Case, void) = .empty,
/// The loops enclosing the statement being checked, innermost last. Empty at
/// the start of every function body, since a `break` cannot leave a function.
loops: std.ArrayList(Loop) = .empty,
/// Which of the program's files is being checked, stamped onto everything
/// reported here and used to turn a bare module-level name into the one key
/// the whole program knows it by.
file: u32 = 0,

/// The constructor being checked. Whether each field has been set is kept as
/// bindings in the constructor's own scope (see `fieldSetKey`), so branches,
/// loops, and early returns merge it exactly as they merge definite assignment.
const Constructing = struct {
    type: Type,
    keyword_span: Source.Span,
    declaration: Ast.StructDeclaration,
    /// What is being checked: the constructor's body, which starts with every
    /// defaulted field set (defaults run first), or the default of one of the
    /// type's own fields, counted among its own.
    part: union(enum) {
        body,
        default_of: usize,
    } = .body,
    /// Section 10.7's `super(...)` at the start of the body, which is the one
    /// call to it allowed. Until it has run, no inherited field is set.
    super_call: ?*const Ast.Expression = null,

    /// Whether a field, counted among every field the value has, is certainly
    /// set when this part begins. A base class's part of the value is built
    /// first, by `super(...)` or, without one, before anything else. A default
    /// runs after the fields before it: under the generated constructor every
    /// one of them has its value by then, from an argument or its own default,
    /// but under a custom constructor only the defaulted ones do.
    fn setAtStart(self: Constructing, field: usize) bool {
        const inherited = self.type.user.?.inherited;
        if (field < inherited) return self.part == .default_of or self.super_call == null;
        const own = field - inherited;
        const fields = self.declaration.fields;
        return switch (self.part) {
            .body => fields[own].default != null,
            .default_of => |current| own < current and
                (self.declaration.constructor == null or fields[own].default != null),
        };
    }
};

/// A type-level field. Its binding in the module scope holds its type; this
/// holds how far working that type out has got.
const TypeField = struct {
    field: Ast.StructDeclaration.TypeField,
    type_key: []const u8,
    /// An annotated field's type is known from the start. An unannotated one's
    /// is inferred from its value on first need, as a function's return type is.
    state: enum { unknown, inferring, known } = .unknown,
    value_checked: bool = false,
};

/// What the checker tracks about one enclosing loop.
const Loop = struct {
    /// How many scopes were in force outside the loop. A `break` records the
    /// assignment state of exactly these, the ones that outlive the loop.
    depth: usize,
    /// `while true`, which only a `break` can end. What is assigned after it is
    /// what every `break` saw assigned, rather than what was assigned before it.
    infinite: bool,
    /// For an infinite loop, the intersection of the state at every `break`
    /// so far; null until the first.
    exits: ?Snapshot = null,
};

pub fn check(
    gpa: std.mem.Allocator,
    files: []const Project.File,
    programs: []const Ast.Program,
    facts: Resolver.Facts,
) !Checked {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const prelude = try arena.create(Scope);
    prelude.* = .empty;
    for (Resolver.prelude) |name| {
        try prelude.put(arena, name, .{ .type = .invalid, .declared = .invalid, .assigned = true, .is_function = true });
    }
    const module = try arena.create(Scope);
    module.* = .empty;

    var checker: Checker = .{ .arena = arena, .prelude = prelude, .module = module, .facts = facts };
    try checker.scopes.append(arena, prelude);
    try checker.scopes.append(arena, module);

    // Hoisted, as in the resolver. The resolver has rejected duplicate names,
    // so every declaration here is the only one with its key.
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data == .struct_declaration) {
                const declaration = statement.data.struct_declaration;
                const key = checker.keyOf(declaration.name);
                const user = try arena.create(Type.User);
                user.* = .{ .name = key, .display_name = declaration.name, .class = declaration.class, .trait = declaration.trait, .enumeration = declaration.enumeration };
                const struct_type = Type.structOf(user);
                try checker.structs.put(arena, key, struct_type);
                try checker.struct_declarations.put(arena, key, declaration);
                try checker.type_spans.put(arena, key, statement.span);
                if (declaration.constructor != null) try checker.constructors.put(arena, key, declaration);
                for (declaration.methods) |method| {
                    const method_key = try Resolver.methodKey(arena, key, method.name);
                    // A repeated name is reported with the struct; the first
                    // declaration is the one calls reach.
                    if (checker.declarations.contains(method_key)) continue;
                    try checker.declarations.put(arena, method_key, method);
                    try checker.receivers.put(arena, method_key, struct_type);
                }
                for (declaration.properties) |property| {
                    const getter_key = try Resolver.methodKey(arena, key, property.name);
                    if (checker.declarations.contains(getter_key)) continue;
                    try checker.declarations.put(arena, getter_key, property.getter);
                    try checker.receivers.put(arena, getter_key, struct_type);
                    try checker.properties.put(arena, getter_key, property.setter != null);
                    if (property.setter) |setter| {
                        const setter_key = try Resolver.setterKey(arena, key, property.name);
                        try checker.declarations.put(arena, setter_key, setter);
                        try checker.receivers.put(arena, setter_key, struct_type);
                    }
                }
                // Section 10.4. A name shared with an instance member is
                // reported with the struct; the member keeps the key.
                for (declaration.type_functions) |function| {
                    const member_key = try Resolver.methodKey(arena, key, function.member);
                    if (checker.declarations.contains(member_key) or module.contains(member_key)) continue;
                    try checker.declarations.put(arena, member_key, function.declaration);
                    try module.put(arena, member_key, .{ .type = .invalid, .declared = .invalid, .assigned = true, .is_function = true });
                }
                for (declaration.type_fields) |field| {
                    const member_key = try Resolver.methodKey(arena, key, field.name);
                    if (checker.declarations.contains(member_key) or module.contains(member_key)) continue;
                    try checker.type_fields.put(arena, member_key, .{ .field = field, .type_key = key });
                    // Always assigned: the type sets up its fields before
                    // anything can reach one.
                    try module.put(arena, member_key, .{
                        .type = .invalid,
                        .declared = .invalid,
                        .assigned = true,
                        .mutability = if (field.mutable) .variable else .constant,
                    });
                }
                try module.put(arena, key, .{
                    .type = struct_type,
                    .declared = struct_type,
                    .assigned = true,
                    .is_type = true,
                });
                continue;
            }
            const function = switch (statement.data) {
                .function_declaration => |f| f,
                else => continue,
            };
            const key = checker.keyOf(function.name);
            try checker.declarations.put(arena, key, function);
            try module.put(arena, key, .{ .type = .invalid, .declared = .invalid, .assigned = true, .is_function = true });
        }
    }

    // Section 10.7: every base class is known before any field is resolved,
    // since a subclass's fields begin with its base class's.
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data != .struct_declaration) continue;
            try checker.resolveBase(statement.data.struct_declaration);
        }
    }
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data != .struct_declaration) continue;
            try checker.breakBaseCycle(statement.data.struct_declaration);
            try checker.resolveTraits(statement.data.struct_declaration);
        }
    }
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data != .struct_declaration) continue;
            try checker.breakTraitCycle(statement.data.struct_declaration);
        }
    }

    // Every type identity exists before any field annotation is resolved, so
    // fields may name a type declared later or in another file.
    checker.resolving_struct_fields = true;
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data != .struct_declaration) continue;
            try checker.ensureStructChecked(checker.keyOf(statement.data.struct_declaration.name));
        }
    }
    checker.resolving_struct_fields = false;

    // A field may refer to a struct whose fields are declared later. Validate
    // dictionary keys only after all of that metadata is complete.
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            if (statement.data != .struct_declaration) continue;
            const declaration = statement.data.struct_declaration;
            const user = checker.structs.get(checker.keyOf(declaration.name)).?.user.?;
            for (declaration.fields, user.fields[user.inherited..]) |field, checked_field| {
                try checker.validateKeyAnnotations(field.annotation, checked_field.type);
            }
        }
    }

    // An annotated type-level field's type is known before anything reads it.
    {
        var fields = checker.type_fields.iterator();
        while (fields.next()) |entry| {
            const annotation = entry.value_ptr.field.annotation orelse continue;
            checker.file = checker.facts.owner.get(entry.key_ptr.*).?;
            const declared = try checker.resolveTypeExpression(annotation);
            const binding = checker.module.getPtr(entry.key_ptr.*).?;
            binding.type = declared;
            binding.declared = declared;
            entry.value_ptr.state = .known;
        }
    }

    // Section 14.1: a file that is not the entry has no statements that run,
    // and its bindings are initialized before anything can reach them, so they
    // are in place and assigned before the entry file is looked at.
    for (files, programs, 0..) |file, program, index| {
        if (file.entry) continue;
        checker.file = @intCast(index);
        try checker.checkStatements(program.statements);
        try checker.markModuleAssigned(program.statements);
    }

    checker.file = 0;
    for (files, programs, 0..) |file, program, index| {
        if (!file.entry) continue;
        checker.file = @intCast(index);
        try checker.checkStatements(program.statements);
    }

    // Every body, in the order written. Most were not needed during the walk
    // above; those that were have already been checked and are skipped.
    for (programs, 0..) |program, index| {
        checker.file = @intCast(index);
        for (program.statements) |statement| {
            switch (statement.data) {
                .function_declaration => |function| try checker.ensureBodyChecked(checker.keyOf(function.name)),
                .struct_declaration => |declaration| {
                    const type_key = checker.keyOf(declaration.name);
                    try checker.checkInheritance(type_key);
                    try checker.checkFieldDefaults(type_key);
                    if (declaration.constructor != null) try checker.checkConstructorBody(type_key);
                    for (declaration.methods) |method| {
                        const method_key = try Resolver.methodKey(arena, type_key, method.name);
                        // An abstract method has no body to check (10.7).
                        if (method.abstract_span != null) {
                            if (checker.declarations.get(method_key)) |declared| {
                                if (declared.abstract_span != null) _ = try checker.signatureFor(method_key);
                            }
                            continue;
                        }
                        try checker.ensureBodyChecked(method_key);
                    }
                    for (declaration.type_functions) |function| {
                        try checker.ensureBodyChecked(try Resolver.methodKey(arena, type_key, function.member));
                    }
                    for (declaration.type_fields) |field| {
                        try checker.checkTypeFieldValue(try Resolver.methodKey(arena, type_key, field.name));
                    }
                    for (declaration.properties) |property| {
                        // A trait's requirement has no body (11.1), but its
                        // type is written all the same.
                        if (property.getter.abstract_span != null) {
                            _ = try checker.signatureFor(try Resolver.methodKey(arena, type_key, property.name));
                            continue;
                        }
                        const getter_key = try Resolver.methodKey(arena, type_key, property.name);
                        if (checker.properties.contains(getter_key)) {
                            try checker.ensureBodyChecked(getter_key);
                            // Section 10.3: "Properties should have no
                            // surprising observable side effects." Changing
                            // the value being read is the one the language
                            // can see, and it would make reading a `const`
                            // impossible to allow.
                            if (try checker.methodChanges(getter_key)) {
                                try checker.report(
                                    property.name_span,
                                    "reading `{s}` would change `self`",
                                    .{property.name},
                                    "Reading a property should never change the value it is read from. Make this a method instead.",
                                );
                            }
                            if (property.setter != null) {
                                const setter_key = try Resolver.setterKey(arena, type_key, property.name);
                                if (checker.declarations.contains(setter_key)) {
                                    try checker.ensureBodyChecked(setter_key);
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Bodies are checked after the top level and inference can check one early,
    // so diagnostics are collected out of order. The reader wants them in the
    // order of the file.
    var changing: Resolver.NameSet = .empty;
    var receivers = checker.receivers.keyIterator();
    while (receivers.next()) |method_key| {
        if (try checker.methodChanges(method_key.*)) try changing.put(arena, method_key.*, {});
    }

    const owned = try checker.diagnostics.toOwnedSlice(arena);
    std.mem.sort(Diagnostic, owned, {}, earlierInSource);
    return .{
        .arena_state = arena_state,
        .diagnostics = owned,
        .signatures = checker.signatures,
        .literal_types = checker.literal_types,
        .structs = checker.structs,
        .changing_methods = changing,
        .method_calls = checker.method_calls,
        .super_members = checker.super_members,
        .type_tests = checker.type_tests,
        .type_names = checker.type_names,
        .trait_calls = checker.trait_calls,
    };
}

/// What a member of a type is, for the diagnostics that compare two.
const MemberKind = enum {
    field,
    property,
    method,
    type_function,
    type_field,
    /// Section 12's enum value, which is a `const` type-level field.
    enum_value,

    fn noun(kind: MemberKind) []const u8 {
        return switch (kind) {
            .field => "field",
            .property => "property",
            .method => "method",
            .type_function => "type-level function",
            .type_field => "type-level field",
            .enum_value => "value",
        };
    }
};

/// One member as written, with the `@override` in front of it, if any.
const Member = struct {
    name: []const u8,
    span: Source.Span,
    kind: MemberKind,
    override_span: ?Source.Span = null,

    fn noun(member: Member) []const u8 {
        return member.kind.noun();
    }

    fn earlier(_: void, a: Member, b: Member) bool {
        return a.span.start < b.span.start;
    }
};

/// Every member a declaration writes, in the order written.
fn membersOf(self: *Checker, declaration: Ast.StructDeclaration) Error![]Member {
    var members: std.ArrayList(Member) = .empty;
    for (declaration.fields) |field| try members.append(self.arena, .{ .name = field.name, .span = field.name_span, .kind = .field });
    for (declaration.properties) |property| try members.append(self.arena, .{ .name = property.name, .span = property.name_span, .kind = .property, .override_span = property.override_span });
    for (declaration.methods) |method| try members.append(self.arena, .{ .name = method.name, .span = method.name_span, .kind = .method, .override_span = method.override_span });
    for (declaration.type_functions) |function| try members.append(self.arena, .{ .name = function.member, .span = function.member_span, .kind = .type_function });
    for (declaration.type_fields) |field| try members.append(self.arena, .{ .name = field.name, .span = field.name_span, .kind = if (field.enum_value != null) .enum_value else .type_field });
    std.mem.sort(Member, members.items, {}, Member.earlier);
    return members.items;
}

/// Section 10.7's `extends`, which has to name a class.
fn resolveBase(self: *Checker, declaration: Ast.StructDeclaration) Error!void {
    const written = declaration.base orelse return;
    const user = @constCast(self.structs.get(self.keyOf(declaration.name)).?.user.?);
    if (Type.fromName(written.name) == null and !self.structs.contains(try self.typeKeyOf(written.name))) {
        try self.reportWithHelp(
            written.span,
            "`{s}` is not a class",
            .{written.name},
            "Check the spelling, or declare `class {s}` in this project.",
            .{written.name},
        );
        return;
    }
    const base = try self.resolveTypeExpression(written);
    if (base.kind == .invalid) return;
    if (base.kind != .struct_value) {
        try self.reportWithHelp(
            written.span,
            "`{s}` can only extend a class, and {f} is not one",
            .{ declaration.name, base },
            "Name a class declared with `class`, as in `class {s} extends Animal`.",
            .{declaration.name},
        );
        return;
    }
    if (base.user.?.enumeration) {
        try self.reportWithHelp(
            written.span,
            "`{s}` is an enum, so it cannot be extended",
            .{base.user.?.display_name},
            "An enum's values are exactly the ones it lists. Give `{s}` a property holding one instead.",
            .{declaration.name},
        );
        return;
    }
    if (!base.user.?.class) {
        try self.reportWithHelp(
            written.span,
            "`{s}` is a struct, so it cannot be extended",
            .{base.user.?.display_name},
            "Structs do not inherit. Declare `{s}` with `class` to use it as a base class.",
            .{base.user.?.display_name},
        );
        return;
    }
    user.base = base.user.?;
}

/// Section 11.2's `with` list, which has to name traits, each once.
fn resolveTraits(self: *Checker, declaration: Ast.StructDeclaration) Error!void {
    if (declaration.traits.len == 0) return;
    const user = @constCast(self.structs.get(self.keyOf(declaration.name)).?.user.?);
    var resolved: std.ArrayList(*const Type.User) = .empty;
    for (declaration.traits) |written| {
        if (Type.fromName(written.name) == null and !self.structs.contains(try self.typeKeyOf(written.name))) {
            try self.reportWithHelp(
                written.span,
                "`{s}` is not a trait",
                .{written.name},
                "Check the spelling, or declare `trait {s}` in this project.",
                .{written.name},
            );
            continue;
        }
        const adopted = try self.resolveTypeExpression(written);
        if (adopted.kind == .invalid) continue;
        if (adopted.kind != .struct_value or !adopted.user.?.trait) {
            try self.reportWithHelp(
                written.span,
                "{f} is not a trait, so it cannot follow `with`",
                .{adopted},
                "{s}",
                .{if (adopted.kind == .struct_value and adopted.user.?.class)
                    try std.fmt.allocPrint(self.arena, "A class is extended, with `extends {s}`, and only by a class.", .{written.name})
                else
                    "Only a trait, declared with `trait`, can be adopted with `with`."},
            );
            continue;
        }
        if (std.mem.indexOfScalar(*const Type.User, resolved.items, adopted.user.?) != null) {
            try self.reportWithHelp(
                written.span,
                "`{s}` is already adopted here",
                .{adopted.user.?.display_name},
                "Name each trait once.",
                .{},
            );
            continue;
        }
        try resolved.append(self.arena, adopted.user.?);
    }
    user.traits = resolved.items;
}

/// A trait that builds on itself, directly or through others, is reported on
/// the `with` entry that closes the loop, which is then dropped.
fn breakTraitCycle(self: *Checker, declaration: Ast.StructDeclaration) Error!void {
    if (!declaration.trait) return;
    const user = @constCast(self.structs.get(self.keyOf(declaration.name)).?.user.?);
    for (user.traits, 0..) |adopted, position| {
        if (!self.traitReaches(adopted, user, 0)) continue;
        const written = for (declaration.traits) |entry| {
            if (std.mem.eql(u8, try self.typeKeyOf(entry.name), adopted.name)) break entry;
        } else declaration.traits[0];
        if (adopted == user) {
            try self.reportWithHelp(
                written.span,
                "`{s}` cannot build on itself",
                .{declaration.name},
                "Name a different trait after `with`, or remove it.",
                .{},
            );
        } else try self.reportWithHelp(
            written.span,
            "`{s}` cannot build on `{s}`, because `{s}` already builds on `{s}`",
            .{ declaration.name, adopted.display_name, adopted.display_name, declaration.name },
            "A trait's traits can never lead back to it. Remove one of the `with` entries.",
            .{},
        );
        const kept = try self.arena.alloc(*const Type.User, user.traits.len - 1);
        @memcpy(kept[0..position], user.traits[0..position]);
        @memcpy(kept[position..], user.traits[position + 1 ..]);
        user.traits = kept;
        return self.breakTraitCycle(declaration);
    }
}

fn traitReaches(self: *Checker, from: *const Type.User, target: *const Type.User, depth: usize) bool {
    if (from == target) return true;
    if (depth > self.structs.count()) return false;
    for (from.traits) |next| {
        if (self.traitReaches(next, target, depth + 1)) return true;
    }
    return false;
}

/// Every trait a type adopts, directly, through the traits those build on,
/// and through its base classes, each once, nearest first.
fn traitClosure(self: *Checker, user: *const Type.User) Error![]const *const Type.User {
    var found: std.ArrayList(*const Type.User) = .empty;
    var at: ?*const Type.User = user;
    while (at) |current| : (at = current.base) {
        for (current.traits) |trait| try self.collectTraits(trait, &found);
    }
    return found.items;
}

fn collectTraits(self: *Checker, trait: *const Type.User, found: *std.ArrayList(*const Type.User)) Error!void {
    if (std.mem.indexOfScalar(*const Type.User, found.items, trait) != null) return;
    try found.append(self.arena, trait);
    for (trait.traits) |next| try self.collectTraits(next, found);
}

/// A class that extends itself, directly or through others, has no base class
/// to start from. Reported once, on the class whose `extends` closes the loop
/// first in the order written, which then has no base.
fn breakBaseCycle(self: *Checker, declaration: Ast.StructDeclaration) Error!void {
    const user = @constCast(self.structs.get(self.keyOf(declaration.name)).?.user.?);
    const base = user.base orelse return;
    var at: ?*const Type.User = base;
    var steps: usize = 0;
    while (at) |current| : (at = current.base) {
        if (current == user) break;
        steps += 1;
        if (steps > self.structs.count()) return;
    } else return;
    if (base == user) {
        try self.reportWithHelp(
            declaration.base.?.span,
            "`{s}` cannot extend itself",
            .{declaration.name},
            "Name a different class after `extends`, or remove `extends`.",
            .{},
        );
    } else {
        try self.reportWithHelp(
            declaration.base.?.span,
            "`{s}` cannot extend `{s}`, because `{s}` already extends `{s}`",
            .{ declaration.name, base.display_name, base.display_name, declaration.name },
            "A class's base classes can never lead back to it. Remove one of the `extends`.",
            .{},
        );
    }
    user.base = null;
}

/// Resolves a type's fields once, a base class's before its subclasses'.
fn ensureStructChecked(self: *Checker, key: []const u8) Error!void {
    if (self.structs_checked.contains(key)) return;
    try self.structs_checked.put(self.arena, key, {});
    const outer_file = self.file;
    defer self.file = outer_file;
    self.file = self.facts.owner.get(key).?;
    try self.checkStructDeclaration(self.struct_declarations.get(key).?);
}

fn checkStructDeclaration(self: *Checker, declaration: Ast.StructDeclaration) Error!void {
    const key = self.keyOf(declaration.name);
    const struct_type = self.structs.get(key).?;
    const user = @constCast(struct_type.user.?);
    const inherited: []const Type.User.Field = if (user.base) |base| blk: {
        try self.ensureStructChecked(base.name);
        break :blk base.fields;
    } else &.{};
    const fields = try self.arena.alloc(Type.User.Field, inherited.len + declaration.fields.len);
    @memcpy(fields[0..inherited.len], inherited);

    for (declaration.fields, fields[inherited.len..]) |field, *checked| {
        checked.* = .{
            .name = field.name,
            .type = try self.resolveTypeExpression(field.annotation),
            .mutable = field.mutable,
            .owner = key,
        };
    }
    user.fields = fields;
    user.inherited = inherited.len;

    // Every member shares one name space, since `value.name` has to mean one
    // of them. They are compared in the order they are written, so the one
    // reported is always the later one.
    const members = try self.membersOf(declaration);

    var seen: std.StringHashMapUnmanaged(Member) = .empty;
    for (members) |member| {
        if (std.mem.eql(u8, member.name, "type_name")) {
            try self.report(
                member.span,
                "`type_name` is already a property of every value",
                .{},
                "It gives the name of the value's type, and cannot be declared again. Give this member another name.",
            );
            continue;
        }
        const first = seen.get(member.name) orelse {
            try seen.put(self.arena, member.name, member);
            continue;
        };
        if (first.kind == .field and member.kind == .field) {
            try self.report(
                member.span,
                "`{s}` is already a field of `{s}`",
                .{ member.name, declaration.name },
                "Give each stored field a different name.",
            );
        } else if (first.kind == .method and member.kind == .method) {
            try self.report(
                member.span,
                "`{s}` is already a method of `{s}`",
                .{ member.name, declaration.name },
                "Emerald has no overloading. Give each method a name of its own.",
            );
        } else if (first.kind == .enum_value or member.kind == .enum_value) {
            try self.reportWithHelp(
                member.span,
                "`{s}` is already a {s} of `{s}`",
                .{ member.name, first.noun(), declaration.name },
                "{s}",
                .{if (first.kind == member.kind)
                    "Each of an enum's values has a name of its own."
                else
                    "An enum's values share one set of names with its members, so that a name means one thing wherever it is written. Rename one."},
            );
        } else {
            const type_level = first.kind == .type_function or first.kind == .type_field or
                member.kind == .type_function or member.kind == .type_field;
            try self.reportWithHelp(
                member.span,
                "`{s}` is already a {s} of `{s}`",
                .{ member.name, first.noun(), declaration.name },
                "{s}",
                .{if (type_level)
                    "A type's members share one set of names, whether they belong to each value or to the type, so that a name means one thing wherever it is written. Rename one."
                else
                    "A field, a property, and a method cannot share a name, since `value.name` has to mean one of them. Rename one."},
            );
        }
    }

    // Section 10.7: a class shares its names with the classes it extends,
    // and section 11.2 with the traits it adopts.
    if (user.base != null or user.traits.len > 0) {
        for (members) |member| {
            if (seen.get(member.name)) |first| if (first.span.start != member.span.start) continue;
            try self.checkInheritedName(member, user);
        }
    } else if (declaration.base == null and declaration.traits.len == 0) {
        for (members) |member| {
            if (member.override_span == null) continue;
            try self.reportWithHelp(
                member.span,
                "`{s}` does not override anything",
                .{member.name},
                "`{s}` does not extend another class. Remove `@override`, or give `{s}` a base class with `extends`.",
                .{ declaration.name, declaration.name },
            );
        }
    }
}

/// A member of a class's base classes, the nearest one first.
const Inherited = struct {
    kind: MemberKind,
    /// The class or trait that declares it.
    owner: *const Type.User,
    /// Its method key, for a method or a property's getter.
    key: ?[]const u8 = null,
};

/// A member `user` has from a class it extends, or else from a trait it or one
/// of those classes adopts. A trait's private members belong to the trait
/// alone, so they are never found here (11.2).
fn inheritedMember(self: *Checker, user: *const Type.User, name: []const u8) Error!?Inherited {
    if (try self.declaredMember(user.base, name, true)) |found| return found;
    for (try self.traitClosure(user)) |trait| {
        if (Resolver.isPrivate(name)) break;
        if (try self.declaredMember(trait, name, false)) |found| return found;
    }
    return null;
}

/// A member declared by `start` or, when `through_bases`, by a class it
/// extends.
fn declaredMember(self: *Checker, start: ?*const Type.User, name: []const u8, through_bases: bool) Error!?Inherited {
    var at: ?*const Type.User = start;
    while (at) |user| : (at = if (through_bases) user.base else null) {
        const declaration = self.struct_declarations.get(user.name).?;
        for (declaration.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return .{ .kind = .field, .owner = user };
        }
        for (declaration.properties) |property| {
            if (std.mem.eql(u8, property.name, name)) return .{ .kind = .property, .owner = user, .key = try Resolver.methodKey(self.arena, user.name, name) };
        }
        for (declaration.methods) |method| {
            if (std.mem.eql(u8, method.name, name)) return .{ .kind = .method, .owner = user, .key = try Resolver.methodKey(self.arena, user.name, name) };
        }
        for (declaration.type_functions) |function| {
            if (std.mem.eql(u8, function.member, name)) return .{ .kind = .type_function, .owner = user };
        }
        for (declaration.type_fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return .{ .kind = .type_field, .owner = user };
        }
    }
    return null;
}

/// One member of a subclass against the names its base classes already use:
/// replacing one takes `@override`, and only a public method or property can
/// be replaced, by one of its own kind.
fn checkInheritedName(self: *Checker, member: Member, user: *const Type.User) Error!void {
    const found = try self.inheritedMember(user, member.name) orelse {
        if (member.override_span != null) {
            try self.reportWithHelp(
                member.span,
                "`{s}` does not override anything",
                .{member.name},
                "Nothing `{s}` extends or adopts has a {s} named `{s}` to replace. Check the name, or remove `@override`.",
                .{ user.display_name, member.noun(), member.name },
            );
        }
        return;
    };
    const owner = found.owner.display_name;
    // Section 11.2: a trait's member is supplied or replaced by a field or a
    // property without `@override`, and by a method with it.
    if (found.owner.trait) {
        if (found.kind == .property and (member.kind == .field or member.kind == .property)) return;
        if (found.kind == .method and member.kind == .method) {
            if (member.override_span != null) return;
            try self.reportWithHelp(
                member.span,
                "`{s}` is a method of the trait `{s}`",
                .{ member.name, owner },
                "Write `@override` on the line before it to supply `{s}`'s method, or give this one a name of its own.",
                .{owner},
            );
            return;
        }
        try self.reportWithHelp(
            member.span,
            "`{s}` is a {s} of the trait `{s}`, so this {s} cannot supply it",
            .{ member.name, found.kind.noun(), owner, member.noun() },
            "{s}",
            .{if (found.kind == .method)
                "A trait's method is supplied by a method. Give this member a name of its own."
            else
                "A trait's property is supplied by a field or a property. Give this member a name of its own."},
        );
        return;
    }
    const replaceable = found.kind == .method or found.kind == .property;
    if (member.override_span != null) {
        if (replaceable and found.kind == member.kind and !Resolver.isPrivate(member.name)) return;
        if (replaceable and found.kind == member.kind) {
            try self.reportWithHelp(
                member.span,
                "`{s}` is private to `{s}`, so it cannot be overridden",
                .{ member.name, owner },
                "Only code inside `{s}`'s braces can reach it. Give this {s} a name of its own.",
                .{ owner, member.noun() },
            );
        } else {
            try self.reportWithHelp(
                member.span,
                "`{s}` is a {s} of `{s}`, so this {s} cannot override it",
                .{ member.name, found.kind.noun(), owner, member.noun() },
                "A method can override only a method, and a property only a property. Give this {s} a name of its own.",
                .{member.noun()},
            );
        }
        return;
    }
    if (replaceable and found.kind == member.kind and !Resolver.isPrivate(member.name)) {
        try self.reportWithHelp(
            member.span,
            "`{s}` is already a {s} of `{s}`",
            .{ member.name, found.kind.noun(), owner },
            "Write `@override` on the line before it to replace `{s}`'s version, or give it a name of its own.",
            .{owner},
        );
        return;
    }
    try self.reportWithHelp(
        member.span,
        "`{s}` is already a {s} of `{s}`",
        .{ member.name, found.kind.noun(), owner },
        "A class shares one set of names with the classes it extends, private names included, so that a name means one thing. Rename this one.",
        .{},
    );
}

/// Section 10.7's rules that need signatures: an override matches what it
/// replaces, an abstract method lives in an abstract class, a class that can be
/// constructed supplies every abstract method it inherits, and a subclass with
/// no constructor of its own can be built without arguments.
fn checkInheritance(self: *Checker, key: []const u8) Error!void {
    const outer_file = self.file;
    defer self.file = outer_file;
    self.file = self.facts.owner.get(key).?;

    const declaration = self.struct_declarations.get(key).?;
    const user = self.structs.get(key).?.user.?;
    for (declaration.methods) |method| {
        const span = method.abstract_span orelse continue;
        if (declaration.abstract_span != null or declaration.trait) continue;
        try self.reportWithHelp(
            span,
            "`{s}` is abstract, so `{s}` has to be `@abstract` too",
            .{ method.name, declaration.name },
            "Write `@abstract` on the line before `class {s}`, or give `{s}` a body.",
            .{ declaration.name, method.name },
        );
    }
    if (user.base == null and user.traits.len == 0) return;

    for (declaration.methods) |method| {
        if (method.override_span == null or Resolver.isPrivate(method.name)) continue;
        const found = try self.inheritedMember(user, method.name) orelse continue;
        if (found.kind != .method) continue;
        const own_key = try Resolver.methodKey(self.arena, key, method.name);
        if (self.declarations.get(own_key)) |declared| if (declared.name_span.start != method.name_span.start) continue;
        try self.checkOverride(method, own_key, found);
    }
    for (declaration.properties) |property| {
        if (property.override_span == null or Resolver.isPrivate(property.name)) continue;
        const found = try self.inheritedMember(user, property.name) orelse continue;
        if (found.kind != .property or found.owner.trait) continue;
        const own_key = try Resolver.methodKey(self.arena, key, property.name);
        if (self.declarations.get(own_key)) |declared| if (declared.name_span.start != property.name_span.start) continue;
        try self.checkPropertyOverride(property, own_key, found);
    }

    if (declaration.abstract_span == null and !declaration.trait) try self.checkImplemented(declaration, user);
    try self.checkTraits(declaration, user);

    const base = user.base orelse return;
    if (declaration.constructor == null) {
        for (declaration.fields) |field| {
            if (field.default != null) continue;
            try self.reportWithHelp(
                declaration.name_span,
                "`{s}` needs a constructor, because its field `{s}` has no default",
                .{ declaration.name, field.name },
                "A class that extends another is built with no arguments unless it has a constructor of its own. Give `{s}` a default, or add a constructor that starts with `super(...)` and sets it.",
                .{field.name},
            );
            return;
        }
        if (try self.constructionNeedsArguments(base.name)) {
            try self.reportWithHelp(
                declaration.name_span,
                "`{s}` needs a constructor, because building `{s}` takes arguments",
                .{ declaration.name, base.display_name },
                "Add a constructor to `{s}` that starts with `super(...)`, passing what `{s}` needs.",
                .{ declaration.name, base.display_name },
            );
        }
    }
}

/// One trait's member of a given name (11.2).
const TraitEntry = struct {
    trait: *const Type.User,
    kind: MemberKind,
    /// Written without a body, so something else has to supply it.
    requirement: bool,
    mutable: bool = false,
    key: []const u8,
};

/// Section 11.1 and 11.2: a type supplies everything its traits require, and
/// the traits it combines agree with each other. Checked eagerly, for every
/// declaration, and reported where the problem is introduced: where a trait
/// is adopted, not again in every subclass or trait built on top.
fn checkTraits(self: *Checker, declaration: Ast.StructDeclaration, user: *const Type.User) Error!void {
    const closure = try self.traitClosure(user);
    if (closure.len == 0) return;
    const inherited: []const *const Type.User = if (user.base) |base| try self.traitClosure(base) else &.{};
    const base_supplies = if (user.base) |base| self.struct_declarations.get(base.name).?.abstract_span == null else false;

    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (closure) |trait| {
        const written = self.struct_declarations.get(trait.name).?;
        for (written.properties) |property| {
            if (!Resolver.isPrivate(property.name)) try names.put(self.arena, property.name, {});
        }
        for (written.methods) |method| {
            if (!Resolver.isPrivate(method.name)) try names.put(self.arena, method.name, {});
        }
    }

    for (names.keys()) |name| {
        var entries: std.ArrayList(TraitEntry) = .empty;
        for (closure) |trait| {
            const written = self.struct_declarations.get(trait.name).?;
            const key = try Resolver.methodKey(self.arena, trait.name, name);
            for (written.properties) |property| {
                if (!std.mem.eql(u8, property.name, name)) continue;
                try entries.append(self.arena, .{ .trait = trait, .kind = .property, .requirement = property.getter.abstract_span != null, .mutable = property.mutable, .key = key });
            }
            for (written.methods) |method| {
                if (!std.mem.eql(u8, method.name, name)) continue;
                try entries.append(self.arena, .{ .trait = trait, .kind = .method, .requirement = method.abstract_span != null, .key = key });
            }
        }
        // Already judged where the base class adopted every one of these.
        const all_inherited = for (entries.items) |entry| {
            if (std.mem.indexOfScalar(*const Type.User, inherited, entry.trait) == null) break false;
        } else user.base != null;
        // Or within one trait this declaration adopts, which judged them.
        const within_one = for (user.traits) |adopted| {
            const reach = try self.traitClosure(&.{ .name = "", .display_name = "", .traits = &.{adopted} });
            const all = for (entries.items) |entry| {
                if (std.mem.indexOfScalar(*const Type.User, reach, entry.trait) == null) break false;
            } else true;
            if (all) break true;
        } else false;
        const introduced = !all_inherited and !within_one;

        const own = try self.declaredMember(user, name, true);
        const first = entries.items[0];

        // The traits have to agree with each other.
        if (introduced) {
            for (entries.items[1..]) |entry| {
                if (entry.trait == first.trait) continue;
                const agree = entry.kind == first.kind and try self.sameTraitMember(user, first, entry);
                if (agree) continue;
                try self.reportWithHelp(
                    declaration.name_span,
                    "`{s}` and `{s}` both have `{s}`, but they do not agree on it",
                    .{ first.trait.display_name, entry.trait.display_name, name },
                    "`{s}` can adopt both only if their `{s}` has the same kind and type. Rename it in one of them.",
                    .{ declaration.name, name },
                );
                break;
            }
            var default: ?TraitEntry = null;
            for (entries.items) |entry| {
                if (entry.requirement) continue;
                const earlier = default orelse {
                    default = entry;
                    continue;
                };
                if (earlier.trait == entry.trait or own != null) continue;
                try self.reportWithHelp(
                    declaration.name_span,
                    "`{s}` gets `{s}` from both `{s}` and `{s}`, and trait order does not choose",
                    .{ declaration.name, name, earlier.trait.display_name, entry.trait.display_name },
                    "Give `{s}` its own `{s}` marked `@override`. It can run either version, as in `{s}.{s}(self)`.",
                    .{ declaration.name, name, earlier.trait.display_name, name },
                );
                break;
            }
        }

        if (declaration.trait) continue;
        const has_default = for (entries.items) |entry| {
            if (!entry.requirement) break true;
        } else false;
        if (own) |supplied| {
            if (first.kind == .property) {
                try self.checkSuppliedProperty(declaration, user, name, supplied, entries.items);
            } else if (supplied.kind == .method and supplied.owner != user) {
                // A base class's method supplies it, which the base class
                // never promised with `@override`, so the shapes are compared.
                const mine = try self.signatureFor(supplied.key.?);
                const theirs = try self.signatureOn(try self.signatureFor(first.key), Type.structOf(user));
                if (!try self.sameSignature(mine, theirs)) {
                    try self.reportWithHelp(
                        declaration.name_span,
                        "the `{s}` `{s}` has from `{s}` does not match the one the trait `{s}` requires",
                        .{ name, declaration.name, supplied.owner.display_name, first.trait.display_name },
                        "A method supplying a trait's takes the same parameters, with the same names and types, and gives the same type.",
                        .{},
                    );
                }
            }
            continue;
        }
        if (has_default or declaration.abstract_span != null) continue;
        if (all_inherited and base_supplies) continue;
        if (first.kind == .property) {
            const any_var = for (entries.items) |entry| {
                if (entry.mutable) break true;
            } else false;
            try self.reportWithHelp(
                declaration.name_span,
                "`{s}` does not supply `{s}`, which the trait `{s}` requires",
                .{ declaration.name, name, first.trait.display_name },
                "Add `{s} {s}: {f}` to `{s}`, as a field or a property.",
                .{ if (any_var) "var" else "const", name, (try self.signatureFor(first.key)).return_type, declaration.name },
            );
        } else {
            try self.reportWithHelp(
                declaration.name_span,
                "`{s}` does not supply `{s}`, which the trait `{s}` requires",
                .{ declaration.name, name, first.trait.display_name },
                "Add `@override func {s}(...)` with a body to `{s}`{s}.",
                .{ name, declaration.name, if (declaration.class) try std.fmt.allocPrint(self.arena, ", or mark `{s}` `@abstract`", .{declaration.name}) else "" },
            );
        }
    }
}

/// Whether two traits' members of one name and kind can be supplied by one
/// member: the same method shape, or properties of the same type, where a
/// writable one subsumes a read-only one (11.2).
fn sameTraitMember(self: *Checker, user: *const Type.User, a: TraitEntry, b: TraitEntry) Error!bool {
    const mine = try self.signatureOn(try self.signatureFor(a.key), ownSelf(user));
    const theirs = try self.signatureOn(try self.signatureFor(b.key), ownSelf(user));
    if (a.kind == .property) return mine.return_type.same(theirs.return_type);
    return self.sameSignature(mine, theirs);
}

fn sameSignature(_: *Checker, mine: Signature, theirs: Signature) Error!bool {
    if (mine.parameters.len != theirs.parameters.len) return false;
    for (mine.parameters, theirs.parameters, mine.parameter_names, theirs.parameter_names) |a, b, a_name, b_name| {
        if (!a.same(b) or !std.mem.eql(u8, a_name, b_name)) return false;
    }
    return mine.return_type.same(theirs.return_type);
}

/// Section 11.1: "A `const` requirement ... may be satisfied by a public
/// `const` or `var` field or readable computed property. A `var` requirement
/// ... needs a public writable field or get/set property."
fn checkSuppliedProperty(
    self: *Checker,
    declaration: Ast.StructDeclaration,
    user: *const Type.User,
    name: []const u8,
    supplied: Inherited,
    entries: []const TraitEntry,
) Error!void {
    const required = for (entries) |entry| {
        if (entry.mutable) break entry;
    } else entries[0];
    const wanted = (try self.signatureFor(required.key)).return_type;
    const actual: Type, const writable: bool = switch (supplied.kind) {
        .field => for (user.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) break .{ field.type, field.mutable };
        } else return,
        .property => .{ (try self.signatureFor(supplied.key.?)).return_type, self.properties.get(supplied.key.?) orelse false },
        else => return,
    };
    const at = if (supplied.owner == user) self.memberSpan(declaration, name) orelse declaration.name_span else declaration.name_span;
    if (!actual.same(wanted)) {
        try self.reportWithHelp(
            at,
            "`{s}` holds {f}, but the trait `{s}` requires {f}",
            .{ name, actual, required.trait.display_name, wanted },
            "Give `{s}` the type the trait requires: `{f}`.",
            .{ name, wanted },
        );
        return;
    }
    if (required.mutable and !writable) {
        try self.reportWithHelp(
            at,
            "`{s}` has to be writable, because the trait `{s}` requires `var {s}`",
            .{ name, required.trait.display_name, name },
            "Declare it with `var`, or give the property a `set` block.",
            .{},
        );
    }
}

fn memberSpan(_: *Checker, declaration: Ast.StructDeclaration, name: []const u8) ?Source.Span {
    for (declaration.fields) |field| if (std.mem.eql(u8, field.name, name)) return field.name_span;
    for (declaration.properties) |property| if (std.mem.eql(u8, property.name, name)) return property.name_span;
    return null;
}

/// Whether building a type needs arguments: its constructor has a parameter
/// without a default, or it has no constructor and a field without one. A
/// class that extends another and has no constructor takes none (10.2).
fn constructionNeedsArguments(self: *Checker, key: []const u8) Error!bool {
    const declaration = self.struct_declarations.get(key).?;
    if (declaration.constructor) |constructor| {
        for (constructor.parameters) |parameter| {
            if (parameter.default == null) return true;
        }
        return false;
    }
    if (self.structs.get(key).?.user.?.base != null) return false;
    for (declaration.fields) |field| {
        if (field.default == null) return true;
    }
    return false;
}

/// Section 7.3 and 10.7: "The parameter name is part of public override ...
/// contracts", and "an override inherits the original declaration's default
/// and cannot replace it."
fn checkOverride(self: *Checker, method: Ast.FunctionDeclaration, own_key: []const u8, found: Inherited) Error!void {
    const mine = try self.signatureFor(own_key);
    // A trait's `Self` is this type's (11.4).
    const theirs = try self.signatureOn(try self.signatureFor(found.key.?), ownSelf(self.receivers.get(own_key).?.user.?));
    const owner = found.owner.display_name;

    var matches = mine.parameters.len == theirs.parameters.len;
    if (matches) {
        for (mine.parameters, theirs.parameters, mine.parameter_names, theirs.parameter_names) |a, b, a_name, b_name| {
            if (!a.same(b) or !std.mem.eql(u8, a_name, b_name)) matches = false;
        }
    }
    if (!matches) {
        var written: std.Io.Writer.Allocating = .init(self.arena);
        for (theirs.parameters, theirs.parameter_names, 0..) |parameter, name, position| {
            if (position != 0) written.writer.writeAll(", ") catch return error.OutOfMemory;
            written.writer.print("{s}: {f}", .{ name, parameter }) catch return error.OutOfMemory;
        }
        try self.reportWithHelp(
            method.name_span,
            "`{s}` takes different parameters from the `{s}` of `{s}` it overrides",
            .{ method.name, method.name, owner },
            "An override takes exactly the parameters it replaces, with the same names and types, since a call through `{s}` passes them: `({s})`.",
            .{ owner, written.written() },
        );
    }
    for (method.parameters) |parameter| {
        const default = parameter.default orelse continue;
        try self.reportWithHelp(
            default.span,
            "an override cannot give `{s}` a default",
            .{parameter.name},
            "It uses whatever `{s}` declares for it, whichever version runs. Remove the default here.",
            .{owner},
        );
    }
    if (!returnsReplace(mine.return_type, theirs.return_type)) {
        try self.reportWithHelp(
            if (method.return_annotation) |annotation| annotation.span else method.name_span,
            "`{s}` gives {f}, but the `{s}` of `{s}` it overrides gives {f}",
            .{ method.name, mine.return_type, method.name, owner, theirs.return_type },
            "An override gives what it replaces, a subclass of a class it gives, or a value that is always there where it gives an optional. Write `: {f}`.",
            .{theirs.return_type},
        );
    }
}

/// Whether an override's result can stand in for the one it replaces: the
/// same type, an object of a subclass where an object of a class is given, or
/// a value that is always present where an optional is given. None of these
/// needs anything done to the value at runtime.
fn returnsReplace(mine: Type, theirs: Type) bool {
    if (mine.same(theirs)) return true;
    if (theirs.optional and !mine.optional) return returnsReplace(mine, theirs.payload());
    if (mine.optional != theirs.optional) return false;
    if (mine.kind != .struct_value or theirs.kind != .struct_value) return false;
    return mine.user.?.class and mine.user.?.extends(theirs.user.?);
}

fn checkPropertyOverride(self: *Checker, property: Ast.StructDeclaration.Property, own_key: []const u8, found: Inherited) Error!void {
    const owner = found.owner.display_name;
    const replaced = for (self.struct_declarations.get(found.owner.name).?.properties) |candidate| {
        if (std.mem.eql(u8, candidate.name, property.name)) break candidate;
    } else unreachable;
    if (replaced.mutable != property.mutable) {
        try self.reportWithHelp(
            property.name_span,
            "`{s}` has to be a `{s}` property, as it is in `{s}`",
            .{ property.name, if (replaced.mutable) "var" else "const", owner },
            "{s}",
            .{if (replaced.mutable)
                "Code that uses the property through the base class can set it, so the override needs `get` and `set` blocks."
            else
                "The override replaces a read-only property, so it gives its value directly, as in `const name: Type { ... }`."},
        );
        return;
    }
    const mine = (try self.signatureFor(own_key)).return_type;
    const theirs = (try self.signatureFor(found.key.?)).return_type;
    if (!mine.same(theirs)) {
        try self.reportWithHelp(
            property.annotation.span,
            "`{s}` holds {f}, but the `{s}` of `{s}` it overrides holds {f}",
            .{ property.name, mine, property.name, owner, theirs },
            "An overriding property holds the same type as the one it replaces. Write `: {f}`.",
            .{theirs},
        );
    }
}

/// Every abstract method a class inherits has to be supplied by it or by a
/// class between it and the one that declares it.
fn checkImplemented(self: *Checker, declaration: Ast.StructDeclaration, user: *const Type.User) Error!void {
    var reported: Resolver.NameSet = .empty;
    var at = user.base;
    while (at) |ancestor| : (at = ancestor.base) {
        for (self.struct_declarations.get(ancestor.name).?.methods) |method| {
            if (method.abstract_span == null or reported.contains(method.name)) continue;
            const nearest = try self.memberKey(Type.structOf(user), method.name) orelse continue;
            if (self.declarations.get(nearest).?.abstract_span == null) continue;
            try reported.put(self.arena, method.name, {});
            try self.reportWithHelp(
                declaration.name_span,
                "`{s}` does not supply the abstract method `{s}` of `{s}`",
                .{ declaration.name, method.name, ancestor.display_name },
                "Add `@override func {s}(...)` with a body to `{s}`, or mark `{s}` `@abstract`.",
                .{ method.name, declaration.name, declaration.name },
            );
        }
    }
}

/// The key of the method or property getter `name` reaches on a value of
/// `owner`: its own class's, or else the nearest base class's (10.7).
fn memberKey(self: *Checker, owner: Type, name: []const u8) Error!?[]const u8 {
    if (owner.kind != .struct_value) return null;
    var at: ?*const Type.User = owner.user;
    while (at) |user| : (at = user.base) {
        const key = try Resolver.methodKey(self.arena, user.name, name);
        if (self.receivers.contains(key)) return key;
    }
    // Section 11.2: class methods, inherited ones included, outrank a trait's.
    // A trait's private members are its own.
    if (Resolver.isPrivate(name)) return null;
    for (try self.traitClosure(owner.user.?)) |trait| {
        const key = try Resolver.methodKey(self.arena, trait.name, name);
        if (self.receivers.contains(key)) return key;
    }
    return null;
}

/// The key of the type that declares the instance member `name` of `owner`,
/// which is where section 10.5's privacy is judged: a field, a property, or a
/// method, its own or inherited.
fn memberOwner(self: *Checker, owner: Type, name: []const u8) Error!?[]const u8 {
    if (owner.kind != .struct_value) return null;
    for (owner.user.?.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.owner;
    }
    const key = try self.memberKey(owner, name) orelse return null;
    return self.receivers.get(key).?.user.?.name;
}

/// The declaration whose parameter defaults a method uses: its own, or for an
/// override, those of the declaration it ultimately replaces (7.3).
fn declarationWithDefaults(self: *Checker, key: []const u8) Error!Ast.FunctionDeclaration {
    var current = key;
    while (true) {
        const declaration = self.declarations.get(current).?;
        if (declaration.override_span == null) return declaration;
        const receiver = self.receivers.get(current) orelse return declaration;
        const base = receiver.user.?.base orelse return declaration;
        current = try self.memberKey(Type.structOf(base), declaration.name) orelse return declaration;
    }
}

/// Section 10.2: "Calls to overridable methods through `self` are forbidden
/// throughout construction." Every public method and property of a class is
/// overridable. Returns whether it reported.
fn reportOverridable(self: *Checker, name: []const u8, span: Source.Span, comptime verb: []const u8) Error!bool {
    const building = self.constructing orelse return false;
    if (!building.type.user.?.class or Resolver.isPrivate(name)) return false;
    if (try self.memberKey(building.type, name) == null) return false;
    try self.reportWithHelp(
        span,
        "a subclass could override `{s}`, so construction cannot " ++ verb ++ " it through `self`",
        .{name},
        "A subclass's version would run before that subclass has set its own fields. Move what it does into a private method, such as `_{s}`, and use that instead.",
        .{name},
    );
    return true;
}

fn validateKeyAnnotations(self: *Checker, annotation: Ast.TypeExpression, resolved: Type) Error!void {
    if (annotation.key) |key| {
        try self.requireEligibleKey(resolved.key.?.*, key.span);
        try self.validateKeyAnnotations(key.*, resolved.key.?.*);
        try self.validateKeyAnnotations(annotation.element.?.*, resolved.element.?.*);
    } else if (annotation.element) |element| {
        try self.validateKeyAnnotations(element.*, resolved.element.?.*);
    } else if (annotation.positions) |positions| {
        for (positions, resolved.elements) |position, checked| {
            try self.validateKeyAnnotations(position, checked);
        }
    } else if (annotation.signature) |signature| {
        for (signature.parameters, resolved.signature.?.parameters) |parameter, checked| {
            try self.validateKeyAnnotations(parameter, checked);
        }
        if (signature.result) |result| {
            try self.validateKeyAnnotations(result.*, resolved.signature.?.return_type);
        }
    }
}

fn earlierInSource(_: void, a: Diagnostic, b: Diagnostic) bool {
    if (a.file != b.file) return a.file < b.file;
    return a.span.start < b.span.start;
}

/// Section 14.1 initializes a module file before anything can read it, so its
/// bindings are assigned wherever they are seen from.
fn markModuleAssigned(self: *Checker, statements: []const Ast.Statement) Error!void {
    for (statements) |statement| switch (statement.data) {
        .declaration => |declaration| {
            const binding = self.module.getPtr(self.keyOf(declaration.name)) orelse continue;
            binding.assigned = true;
        },
        .destructuring => |destructuring| for (destructuring.pattern.names) |name| {
            const binding = self.module.getPtr(self.keyOf(name.text)) orelse continue;
            binding.assigned = true;
        },
        else => {},
    };
}

/// The one name the whole program knows a module-level declaration by, as the
/// resolver worked it out for the file being checked. A name that is not a
/// module-level declaration is its own key, which is every local.
fn keyOf(self: *Checker, name: []const u8) []const u8 {
    return self.facts.keyFor(self.file, name) orelse name;
}

/// Resolves both a bare imported type and a namespace alias at the front of a
/// qualified type, such as `using L = Left` followed by `L.Marker`.
fn typeKeyOf(self: *Checker, name: []const u8) Error![]const u8 {
    if (self.facts.keyFor(self.file, name)) |key| return key;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    const namespace = self.facts.namespaceAliasFor(self.file, name[0..dot]) orelse return name;
    return std.fmt.allocPrint(self.arena, "{s}{s}", .{ namespace, name[dot..] });
}

/// A module-level declaration reached either way: `area` inside `shapes/`, or
/// `Shapes.area` from anywhere. The resolver decided which member expressions
/// are qualified references; this only reads the answer.
const Reference = struct {
    key: []const u8,
    /// How the reader wrote it, which is what a diagnostic should echo back.
    display: []const u8,
};

fn referenceOf(self: *Checker, expression: *const Ast.Expression) Error!?Reference {
    return switch (expression.data) {
        .name => |name| .{ .key = self.keyOf(name), .display = name },
        .member => if (self.facts.qualified.get(expression)) |key|
            .{ .key = key, .display = try Resolver.displayKey(self.arena, key) }
        else
            null,
        else => null,
    };
}

/// Local scopes are keyed by the bare name and only the module scope is keyed
/// program-wide, so both spellings are tried at each level. A local always wins,
/// because it is found in an inner scope first.
fn find(self: *Checker, name: []const u8) ?*Binding {
    const key = self.facts.keyFor(self.file, name);
    // A type-level field has one binding, the module scope's, whose type may
    // have been inferred after a function body copied the scope.
    if (key) |qualified| {
        if (self.type_fields.contains(qualified)) {
            // Never narrowed, so its type is its declared type. Restoring the
            // flow state after a block can put back a type saved before the
            // field's type was inferred inside that block, so it is set again.
            const binding = self.module.getPtr(qualified).?;
            binding.type = binding.declared;
            return binding;
        }
    }
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].getPtr(name)) |binding| return binding;
        if (key) |qualified| {
            if (self.scopes.items[index].getPtr(qualified)) |binding| return binding;
        }
    }
    return null;
}

fn findKey(self: *Checker, key: []const u8) ?*Binding {
    var index = self.scopes.items.len;
    while (index > 0) {
        index -= 1;
        if (self.scopes.items[index].getPtr(key)) |binding| return binding;
    }
    return null;
}

fn report(
    self: *Checker,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    help: []const u8,
) Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = help,
        .file = self.file,
    });
}

/// Like `report`, but for a correction that names something from the program.
fn reportWithHelp(
    self: *Checker,
    span: Source.Span,
    comptime message_format: []const u8,
    message_args: anytype,
    comptime help_format: []const u8,
    help_args: anytype,
) Error!void {
    try self.diagnostics.append(self.arena, .{
        .message = try std.fmt.allocPrint(self.arena, message_format, message_args),
        .span = span,
        .help = try std.fmt.allocPrint(self.arena, help_format, help_args),
        .file = self.file,
    });
}

fn pushScope(self: *Checker) Error!void {
    const scope = try self.arena.create(Scope);
    scope.* = .empty;
    try self.scopes.append(self.arena, scope);
}

// Statements.

fn checkStatements(self: *Checker, statements: []const Ast.Statement) Error!void {
    if (self.scopes.items[self.scopes.items.len - 1] != self.module) try self.hoistNestedFunctions(statements);
    for (statements) |statement| try self.checkStatement(statement);
}

/// Section 7.1's nested functions, callable anywhere in the block that
/// declares them. The resolver has already reported a name that is taken.
fn hoistNestedFunctions(self: *Checker, statements: []const Ast.Statement) Error!void {
    const current = self.scopes.items[self.scopes.items.len - 1];
    for (statements) |statement| {
        const function = switch (statement.data) {
            .function_declaration => |f| f,
            else => continue,
        };
        const key = self.nestedKey(function) orelse continue;
        try self.declarations.put(self.arena, key, function);
        try self.nested.put(self.arena, key, self.scopes.items.len);
        try current.put(self.arena, function.name, .{
            .type = .invalid,
            .declared = .invalid,
            .assigned = true,
            .is_function = true,
            .function_key = key,
        });
    }
}

fn nestedKey(self: *Checker, function: Ast.FunctionDeclaration) ?[]const u8 {
    return self.facts.nested_keys.get(.{ .file = self.file, .start = function.name_span.start });
}

/// Section 7.1: "Hoisting never permits reading an uninitialized captured
/// variable." The resolver has listed what a use of a nested function can
/// read, and proved each is declared above it.
fn checkNestedUse(self: *Checker, expression: *const Ast.Expression) Error!void {
    const names = self.facts.nested_uses.get(expression) orelse return;
    for (names) |name| {
        const binding = self.find(name) orelse continue;
        if (binding.assigned) continue;
        try self.reportWithHelp(
            expression.span,
            "`{s}` reads `{s}`, which is not assigned yet here",
            .{ expression.data.name, name },
            "Assign `{s}` before this line.",
            .{name},
        );
        return;
    }
}

fn checkBlock(self: *Checker, block: Ast.Block) Error!void {
    try self.pushScope();
    defer _ = self.scopes.pop();
    try self.checkStatements(block.statements);
}

fn checkStatement(self: *Checker, statement: Ast.Statement) Error!void {
    switch (statement.data) {
        .expression => |expression| _ = try self.typeOf(expression),
        .declaration => |declaration| try self.checkDeclaration(declaration),
        .assignment => |assignment| try self.checkAssignment(assignment),
        .conditional => |conditional| try self.checkConditional(conditional),
        .while_loop => |loop| try self.checkWhile(loop),
        .for_loop => |loop| try self.checkFor(loop),
        .break_statement => |span| try self.checkBreak(span),
        .continue_statement => |span| _ = try self.enclosingLoop(span, "continue"),
        // A program function is checked after the top level; see the module
        // comment. A nested one is checked where it is written, unless a use
        // above it needed it first.
        .function_declaration => |function| if (self.nestedKey(function)) |key| {
            if (self.nested.contains(key)) try self.ensureBodyChecked(key);
        },
        .struct_declaration => {},
        .return_statement => |return_statement| try self.checkReturn(return_statement),
        .destructuring => |destructuring| try self.checkDestructuring(destructuring),
        .destructuring_assignment => |assignment| try self.checkDestructuringAssignment(assignment),
        .case_statement => |case| _ = try self.checkCase(case, null),
    }
}

/// Section 8.2's `var (name, age) = entry`. The names take the position types,
/// so the tuple's arity has to match the pattern's before anything is bound.
fn checkDestructuring(self: *Checker, destructuring: Ast.Destructuring) Error!void {
    const expected: ?Type = if (destructuring.annotation) |annotation|
        try self.resolveTypeExpression(annotation)
    else
        null;

    const actual = try self.typeOfExpected(destructuring.initializer, expected);
    if (expected) |declared| {
        if (!actual.assignableTo(declared)) {
            try self.report(
                destructuring.initializer.span,
                "this is {f}, but it was declared as {f}",
                .{ actual, declared },
                mismatchHelp(actual, declared, "Give the declaration the type of its value, or convert the value to match."),
            );
        }
    }

    try self.bindPattern(
        destructuring.pattern,
        expected orelse actual,
        destructuring.initializer.span,
        if (destructuring.mutable) .variable else .constant,
    );
}

/// The position types a pattern unpacks, or an empty slice once the mismatch
/// has been reported. `invalid` unpacks to as many invalid positions as the
/// pattern asks for, so one mistake produces one report.
fn positionsFor(
    self: *Checker,
    unpacked: Type,
    pattern: Ast.Pattern,
    span: Source.Span,
) Error![]const Type {
    if (unpacked.isInvalid()) return &.{};
    if (unpacked.optional) {
        try self.report(
            span,
            "this is {f}, which may be absent, so it cannot be unpacked",
            .{unpacked},
            "Check it against `nothing` first, or give it a fallback with `.or(...)`.",
        );
        return &.{};
    }
    if (unpacked.kind != .tuple) {
        try self.report(
            span,
            "this is {f}, which is not a tuple",
            .{unpacked},
            "Only a tuple can be unpacked into names. Write one name for anything else.",
        );
        return &.{};
    }
    if (unpacked.elements.len != pattern.positions.len) {
        try self.reportWithHelp(
            pattern.span,
            "this unpacks {d} {s}, but {f} has {d} positions",
            .{
                pattern.positions.len,
                if (pattern.names.len == pattern.positions.len) "names" else "positions",
                unpacked,
                unpacked.elements.len,
            },
            "Write one name for each position. Use `_` for a position you do not need.",
            .{},
        );
        return &.{};
    }
    return unpacked.elements;
}

fn bindPatternName(
    self: *Checker,
    name: Ast.Pattern.Name,
    position: Type,
    mutability: Mutability,
) Error!void {
    // Section 8.2: `_` discards its position and binds nothing.
    if (std.mem.eql(u8, name.text, "_")) return;

    const current = self.scopes.items[self.scopes.items.len - 1];
    const key = if (current == self.module) self.keyOf(name.text) else name.text;
    try current.put(self.arena, key, .{
        .type = position,
        .declared = position,
        .assigned = true,
        .mutability = mutability,
    });
}

/// Unpacks one value into the names of a pattern, reporting a shape that cannot
/// be unpacked once rather than once per name.
fn bindPattern(
    self: *Checker,
    pattern: Ast.Pattern,
    unpacked: Type,
    span: Source.Span,
    mutability: Mutability,
) Error!void {
    const positions = try self.positionsFor(unpacked, pattern, span);
    for (pattern.positions, 0..) |written, index| {
        const position: Type = if (index < positions.len) positions[index] else .invalid;
        switch (written) {
            .name => |name| try self.bindPatternName(name, position, mutability),
            .nested => |nested| try self.bindPattern(nested.*, position, nested.span, mutability),
        }
    }
}

/// Section 8.2's `(left, right) = (right, left)`, which assigns to names that
/// already exist. The whole right side is checked first, as it is evaluated.
fn checkDestructuringAssignment(self: *Checker, assignment: Ast.DestructuringAssignment) Error!void {
    const actual = try self.typeOf(assignment.value);
    try self.assignPattern(assignment.pattern, actual, assignment.value.span);
}

fn assignPattern(self: *Checker, pattern: Ast.Pattern, unpacked: Type, span: Source.Span) Error!void {
    const positions = try self.positionsFor(unpacked, pattern, span);
    for (pattern.positions, 0..) |written, index| {
        const position: Type = if (index < positions.len) positions[index] else .invalid;
        const name = switch (written) {
            .name => |name| name,
            .nested => |nested| {
                try self.assignPattern(nested.*, position, nested.span);
                continue;
            },
        };
        if (std.mem.eql(u8, name.text, "_")) continue;
        const binding = self.find(name.text) orelse continue;
        if (!position.assignableTo(binding.declared)) {
            try self.report(
                name.span,
                "position {d} is {f}, but `{s}` is {f}",
                .{ index, position, name.text, binding.declared },
                mismatchHelp(position, binding.declared, "Assign a value of the expected type, or convert it first."),
            );
        }
        binding.assigned = true;
        binding.type = binding.declared;
    }
}

/// Section 6.4, with section 4.1's definite assignment. The body is checked
/// from the state before the loop. That is exactly right for the first
/// iteration, and later ones only know more, since nothing becomes unassigned.
///
/// Narrowing is the exception, because a proof can be lost: a body that sets a
/// name back to `nothing` leaves it absent for the next iteration and for the
/// condition that decides whether there is one. So before either is checked,
/// every name the body assigns gives up what was proved about it (4.5), and the
/// body proves it again if it can. That is also what keeps the state restored
/// after the loop from bringing back a proof the body undid.
///
/// The body may also run zero times, so after the loop only what was assigned
/// before it is known. `while true` is the exception: it can end only through a
/// `break`, so what follows it knows whatever every `break` knew, and when it
/// has no `break` at all, nothing after it is reachable.
fn checkWhile(self: *Checker, loop: Ast.While) Error!void {
    self.forgetNarrowingAssignedIn(loop.body.statements);
    try self.requireCondition(loop.condition);
    const before = try self.snapshot();
    const infinite = isLiteralTrue(loop.condition);

    try self.loops.append(self.arena, .{ .depth = self.scopes.items.len, .infinite = infinite });
    // Section 4.5: the body runs only when the condition held, so what the
    // condition proves holds there, exactly as in an `if`. This is what makes
    // `while line != nothing` narrow `line` for the body that reads it.
    self.narrow(loop.condition, true);
    try self.checkBlock(loop.body);
    const finished = self.loops.pop().?;

    if (!infinite) return self.restoreAfterLoop(before);
    if (finished.exits) |exits| self.restore(exits) else self.markAllAssigned();
}

/// Section 6.4. The loop variable is read-only and assigned for the whole body,
/// and a range may be empty, so as with `while`, only what was assigned before
/// the loop is known after it.
fn checkFor(self: *Checker, loop: Ast.For) Error!void {
    // The iterable is evaluated once, before the body can change anything.
    const element = try self.typeOfIterable(loop.iterable);
    self.forgetNarrowingAssignedIn(loop.body.statements);
    const before = try self.snapshot();

    try self.loops.append(self.arena, .{ .depth = self.scopes.items.len, .infinite = false });
    try self.pushScope();
    if (loop.pattern) |pattern| {
        try self.bindPattern(pattern, element, loop.iterable.span, .loop_variable);
    } else if (!std.mem.eql(u8, loop.name, "_")) {
        const scope = self.scopes.items[self.scopes.items.len - 1];
        try scope.put(self.arena, loop.name, .{
            .type = element,
            .declared = element,
            .assigned = true,
            .mutability = .loop_variable,
        });
    }
    try self.checkStatements(loop.body.statements);
    _ = self.scopes.pop();
    _ = self.loops.pop();

    // After the scope is gone, so the snapshot and the scopes line up again.
    self.restoreAfterLoop(before);
}

/// Undoes section 4.5's narrowing for every name a loop body assigns anywhere
/// in its statements, nested blocks and loops included. Assignments inside a
/// lambda are not looked for: a name assigned there is never narrowed at all.
fn forgetNarrowingAssignedIn(self: *Checker, statements: []const Ast.Statement) void {
    for (statements) |statement| switch (statement.data) {
        // Assigning into a place changes what the name holds, not whether it
        // is there, and a place cannot be reached through an optional anyway.
        .assignment => |assignment| if (assignment.steps.len == 0) self.forgetNarrowing(assignment.name),
        .destructuring_assignment => |assignment| for (assignment.pattern.names) |name| {
            self.forgetNarrowing(name.text);
        },
        .conditional => |conditional| {
            self.forgetNarrowingAssignedIn(conditional.then_block.statements);
            if (conditional.otherwise) |otherwise| switch (otherwise) {
                .block => |block| self.forgetNarrowingAssignedIn(block.statements),
                .chained => |chained| self.forgetNarrowingAssignedIn(chained[0..1]),
            };
        },
        .while_loop => |inner| self.forgetNarrowingAssignedIn(inner.body.statements),
        .for_loop => |inner| self.forgetNarrowingAssignedIn(inner.body.statements),
        .expression,
        .declaration,
        .break_statement,
        .continue_statement,
        .function_declaration,
        .struct_declaration,
        .return_statement,
        .destructuring,
        => {},
        .case_statement => |case| {
            for (case.arms) |arm| self.forgetNarrowingAssignedIn(arm.body.block.statements);
            if (case.otherwise) |otherwise| self.forgetNarrowingAssignedIn(otherwise.block.statements);
        },
    };
}

fn forgetNarrowing(self: *Checker, name: []const u8) void {
    const binding = self.find(name) orelse return;
    binding.type = binding.declared;
}

/// The type of each value a `for` loop visits. Only ranges so far, and a range
/// counts whole numbers.
fn typeOfIterable(self: *Checker, iterable: *const Ast.Expression) Error!Type {
    if (isCounting(iterable)) {
        try self.checkCounting(iterable);
        return .int;
    }

    const actual = try self.typeOf(iterable);
    if (actual.kind == .invalid) return .invalid;
    if (!try self.requirePresent(actual, iterable, null)) return .invalid;
    // Section 8.4: a loop visits the collection as it was when the loop began,
    // and a dictionary or set in the order things were put into it.
    if (actual.kind == .list or actual.kind == .set or actual.kind == .dictionary) {
        return self.itemType(actual);
    }
    // Section 9.1: iterating a string yields its characters, each a String.
    if (actual.kind == .string) return .string;
    try self.report(
        iterable.span,
        "a `for` loop cannot visit {f}",
        .{actual},
        "A `for` loop visits a range, as in `for i in 1..10`, or the elements of a list, dictionary, or set.",
    );
    return .invalid;
}

/// Section 6.4's ways of counting: `a..b`, `a..<b`, `a.up_to(b)`, and
/// `a.down_to(b)`, optionally followed by `.step(n)` and `.reverse()`. Decided
/// from the shape of the expression, since none of them is a value a program
/// can hold yet; a `for` loop is the only place they are accepted.
pub fn isCounting(expression: *const Ast.Expression) bool {
    return switch (expression.data) {
        .range => true,
        .call => |call| switch (call.callee.data) {
            .member => |member| countingStart(member.name) or
                (countingAdapter(member.name) and isCounting(member.base)),
            else => false,
        },
        else => false,
    };
}

fn countingStart(name: []const u8) bool {
    return std.mem.eql(u8, name, "up_to") or std.mem.eql(u8, name, "down_to");
}

fn countingAdapter(name: []const u8) bool {
    return std.mem.eql(u8, name, "step") or std.mem.eql(u8, name, "reverse");
}

/// Types every part of a counting expression and reports what can be seen
/// from the source alone: a literal range or `down_to` that can only be empty,
/// a literal step below 1, and a second step.
fn checkCounting(self: *Checker, expression: *const Ast.Expression) Error!void {
    if (expression.data == .range) {
        const range = expression.data.range;
        try self.requireCountingInt(range.start);
        try self.requireCountingInt(range.end);
        return self.rejectDescendingLiteralRange(expression, range);
    }

    const call = expression.data.call;
    const member = call.callee.data.member;
    const wanted: usize = if (std.mem.eql(u8, member.name, "reverse")) 0 else 1;
    if (call.arguments.len != wanted) {
        try self.report(
            member.name_span,
            "`{s}` takes {d} argument{s}, but this call passes {d}",
            .{ member.name, wanted, if (wanted == 1) "" else "s", call.arguments.len },
            "Write it as in `10.down_to(1)`, `(0..10).step(2)`, or `(1..5).reverse()`.",
        );
        try self.typeArguments(call.arguments);
        if (!countingStart(member.name)) try self.checkCounting(member.base);
        return;
    }

    if (countingStart(member.name)) {
        try self.requireCountingInt(member.base);
        try self.requireCountingInt(call.arguments[0]);
        return self.rejectContradictingLiteralCount(expression, member, call.arguments[0]);
    }

    try self.checkCounting(member.base);
    if (std.mem.eql(u8, member.name, "reverse")) return;

    // `step`.
    try self.requireCountingInt(call.arguments[0]);
    if (literalInt(call.arguments[0])) |distance| {
        if (distance < 1) try self.report(
            call.arguments[0].span,
            "a step must be at least 1",
            .{},
            "The range says which way to count; the step says only how far, as in `10.down_to(0).step(2)`.",
        );
    }
    if (hasStep(member.base)) try self.report(
        member.name_span,
        "this already has a step",
        .{},
        "Give it a single `step` with the distance you want.",
    );
}

fn hasStep(expression: *const Ast.Expression) bool {
    if (expression.data != .call) return false;
    const member = expression.data.call.callee.data.member;
    if (std.mem.eql(u8, member.name, "step")) return true;
    if (std.mem.eql(u8, member.name, "reverse")) return hasStep(member.base);
    return false;
}

fn requireCountingInt(self: *Checker, expression: *const Ast.Expression) Error!void {
    const actual = try self.typeOf(expression);
    if (actual.kind == .int or actual.kind == .invalid) return;
    try self.report(
        expression.span,
        "counting works with whole numbers, but this is {f}",
        .{actual},
        "Count with Ints, as in `1..10` or `10.down_to(1)`.",
    );
}

/// Section 6.4: ranges count upward, so one written with two literal endpoints
/// in descending order can only be empty, which can only be a mistake. A
/// computed bound is never reported, since `0..count - 1` being empty for an
/// empty list is exactly what makes upward-only ranges safe.
fn rejectDescendingLiteralRange(
    self: *Checker,
    iterable: *const Ast.Expression,
    range: Ast.Expression.Range,
) Error!void {
    const start = literalInt(range.start) orelse return;
    const end = literalInt(range.end) orelse return;
    const empty = if (range.inclusive) start > end else start >= end;
    if (!empty or (!range.inclusive and start == end)) return;
    try self.reportWithHelp(
        iterable.span,
        "this range is empty, because ranges count upward",
        .{},
        "Count down with `{d}.down_to({d})`, or up with `{d}..{d}`.",
        .{ start, end, end, start },
    );
}

/// The same for `up_to` and `down_to`, which count only the way they are named.
fn rejectContradictingLiteralCount(
    self: *Checker,
    expression: *const Ast.Expression,
    member: Ast.Expression.Member,
    target: *const Ast.Expression,
) Error!void {
    const start = literalInt(member.base) orelse return;
    const end = literalInt(target) orelse return;
    const down = std.mem.eql(u8, member.name, "down_to");
    if (if (down) start >= end else start <= end) return;
    try self.reportWithHelp(
        expression.span,
        "this is empty, because `{s}` only counts {s}",
        .{ member.name, if (down) "down" else "up" },
        "Write `{d}.{s}({d})` instead.",
        .{ start, if (down) "up_to" else "down_to", end },
    );
}

/// The value of an integer literal, including a negated one such as `-3`.
fn literalInt(expression: *const Ast.Expression) ?i64 {
    return switch (expression.data) {
        .int_literal => |value| value,
        .unary => |unary| if (unary.operator == .negate and unary.operand.data == .int_literal)
            std.math.negate(unary.operand.data.int_literal) catch null
        else
            null,
        else => null,
    };
}

fn checkBreak(self: *Checker, span: Source.Span) Error!void {
    const loop = try self.enclosingLoop(span, "break") orelse return;
    if (!loop.infinite) return;

    const here = try self.snapshotOf(loop.depth);
    if (loop.exits) |exits| {
        for (exits, here) |known, now| {
            for (known, now) |*state, reached| {
                state.assigned = state.assigned and reached.assigned;
                // Narrowing survives only where every `break` proved it. The
                // types here are the declared one or a narrowing of it, so the
                // one that may still be absent is the one both paths allow.
                if (reached.type.optional) state.type = reached.type;
            }
        }
    } else {
        loop.exits = here;
    }
}

/// The innermost loop, or a report that there is none. Loops do not reach
/// across a function boundary, because `loops` starts empty in every body.
fn enclosingLoop(self: *Checker, span: Source.Span, comptime keyword: []const u8) Error!?*Loop {
    if (self.loops.items.len == 0) {
        try self.report(
            span,
            "`" ++ keyword ++ "` can only be used inside a loop",
            .{},
            // Inside a function, the likely intent is ending the caller's loop.
            if (self.in_function)
                "A function cannot end the loop that called it. Return a value the caller can check instead."
            else
                "Put it inside a `while` or `for` loop, or remove it.",
        );
        return null;
    }
    return &self.loops.items[self.loops.items.len - 1];
}

fn checkDeclaration(self: *Checker, declaration: Ast.Declaration) Error!void {
    var declared: Type = .invalid;
    var assigned = true;

    if (declaration.annotation) |annotation| {
        declared = try self.resolveTypeExpression(annotation);
    }

    if (declaration.initializer) |initializer| {
        const expected: ?Type = if (declaration.annotation != null) declared else null;
        const actual = try self.typeOfExpected(initializer, expected);
        if (declaration.annotation != null) {
            if (!actual.assignableTo(declared)) {
                try self.report(
                    initializer.span,
                    "this is {f}, but `{s}` was declared as {f}",
                    .{ actual, declaration.name, declared },
                    mismatchHelp(actual, declared, "Give the declaration the type of its value, or convert the value to match."),
                );
            }
        } else {
            // Section 4.1 infers the local's type from its initializer.
            declared = actual;
        }
    } else {
        // No initializer, so the annotation is the only source of a type and
        // the binding starts out unassigned.
        assigned = false;
        if (declaration.annotation == null) {
            try self.report(
                declaration.name_span,
                "`{s}` needs a type or a value",
                .{declaration.name},
                "Write `var name = value` to infer the type, or `var name: Type` to declare it without one.",
            );
        }
    }

    const current = self.scopes.items[self.scopes.items.len - 1];
    // Only the module scope is shared between files, so only it is keyed
    // program-wide; a local is known by the name that was written.
    const name = if (current == self.module) self.keyOf(declaration.name) else declaration.name;
    try current.put(self.arena, name, .{
        .type = declared,
        .declared = declared,
        .assigned = assigned,
        .mutability = if (declaration.mutable) .variable else .constant,
    });
}

fn checkAssignment(self: *Checker, assignment: Ast.Assignment) Error!void {
    const site: Resolver.Site = .{ .file = self.file, .start = assignment.name_span.start };
    if (self.facts.type_assignments.get(site)) |written| {
        // Section 10.4's `Player.count += 1`: `Player` and its first step are
        // one binding, which the resolver made findable as `Player.count`.
        const key = self.keyOf(written);
        try self.settleTypeField(key);
        const first = assignment.steps[0].field;
        var rewritten = assignment;
        rewritten.name = written;
        rewritten.name_span = .{ .start = assignment.name_span.start, .end = first.span.end };
        rewritten.steps = assignment.steps[1..];
        if (!self.in_function) {
            const field = self.type_fields.get(key).?;
            try self.checkCapturesOf(rewritten.name_span, try Resolver.typeSetupKey(self.arena, field.type_key), rewritten.name, "this assignment");
        }
        return self.checkAssignmentTo(rewritten);
    }
    return self.checkAssignmentTo(assignment);
}

fn checkAssignmentTo(self: *Checker, assignment: Ast.Assignment) Error!void {
    if (assignment.steps.len > 0) return self.checkPlaceAssignment(assignment);

    const binding = self.find(assignment.name) orelse {
        // The resolver reported it.
        _ = try self.typeOf(assignment.value);
        return;
    };
    if (try self.reportPrivateTypeMember(self.keyOf(assignment.name), assignment.name_span)) {
        _ = try self.typeOf(assignment.value);
        return;
    }
    // Against the declared type, not the narrowed one: an assignment is free to
    // put `nothing` back into an optional that was proved present above it.
    const value = try self.typeOfExpected(
        assignment.value,
        if (assignment.operation == null) binding.declared else null,
    );
    if (binding.is_function) return; // so did this

    if (assignment.operation) |operation| {
        // Section 5.3 lowers a compound assignment through the same operation,
        // so its result type is the operation's, not the right-hand side's.
        if (!binding.assigned) try self.reportUnassigned(assignment.name_span, assignment.name, binding.*);
        const result = try self.arithmetic(assignment.name_span, operation, binding.type, value);

        if (!result.assignableTo(binding.type)) {
            // Worth explaining rather than only reporting. `/` always produces a
            // Float, so `count /= 2` on an Int can never store its result, and
            // the reason is two sections away from the line that failed.
            try self.report(
                assignment.name_span,
                "`{s}` produces {f}, which `{s}` cannot hold because it is {f}",
                .{ operation.lexeme(), result, assignment.name, binding.type },
                if (operation == .divide)
                    "`/` always produces a Float. Use `//=` to keep whole numbers, or declare the name as a Float."
                else
                    "Declare the name with a type that can hold the result.",
            );
        }

        binding.assigned = true;
        return;
    }

    if (!value.assignableTo(binding.declared)) {
        try self.report(
            assignment.value.span,
            "this is {f}, but `{s}` holds {f}",
            .{ value, assignment.name, binding.declared },
            mismatchHelp(value, binding.declared, "Assign a value of the declared type, or convert it first."),
        );
    }

    // Section 4.5: assigning a value that is certainly there proves it is, and
    // assigning anything else ends whatever an earlier test had proved.
    binding.type = binding.declared;
    // A type-level field has one binding for the whole program, which any
    // function could set back to `nothing`, so nothing about it is narrowed.
    if (binding.declared.optional and !value.optional and value.kind != .nothing and
        !self.type_fields.contains(self.keyOf(assignment.name)))
    {
        self.narrowName(assignment.name);
    }
    binding.assigned = true;
}

/// `scores[0] = 1`, `grid[i][j] += 1`, or `point.x = 1`: a change to what a
/// name holds without replacing the name's own binding, which section 4.3
/// forbids for a `const` just as it forbids replacing the whole value.
fn checkPlaceAssignment(self: *Checker, assignment: Ast.Assignment) Error!void {
    for (assignment.steps) |step| switch (step) {
        .field => |field| if (std.mem.eql(u8, field.name, "type_name")) {
            try self.report(
                field.span,
                "`type_name` cannot be set",
                .{},
                "It always gives the name of the value's type, which no assignment can change.",
            );
            _ = try self.typeOf(assignment.value);
            return;
        },
        .index => {},
    };
    if (std.mem.eql(u8, assignment.name, "super")) return self.checkSuperAssignment(assignment);
    if (try self.checkSelfAssignment(assignment)) return;
    const binding = self.find(assignment.name) orelse {
        for (assignment.steps) |step| switch (step) {
            .index => |index| try self.requireIndex(index),
            .field => {},
        };
        _ = try self.typeOf(assignment.value);
        return;
    };
    if (try self.reportPrivateTypeMember(self.keyOf(assignment.name), assignment.name_span)) {
        _ = try self.typeOf(assignment.value);
        return;
    }
    if (binding.is_function) {
        try self.report(assignment.name_span, "`{s}` is a function, so it has no elements", .{assignment.name}, "Only a list can be indexed.");
        _ = try self.typeOf(assignment.value);
        return;
    }

    if (!binding.assigned) {
        try self.reportUnassigned(assignment.name_span, assignment.name, binding.*);
        binding.assigned = true;
    }
    // Section 10.1: what freezes a path is decided once it is walked, since
    // an object on it is shared and makes the binding and any `const` field
    // before it irrelevant. Reported at the end, in the order written.
    var root_frozen = true;
    var frozen: ?Frozen = null;

    // Walk down to the type of the place being replaced. Section 10.2: a
    // `const` field freezes what it holds exactly as a `const` binding does,
    // so a struct step fails here the same way `requireMutable` fails above.
    var element = binding.type;
    // The struct the final step was reached from, so a mismatch can say
    // whether it was assigning a field or a property.
    var last_owner: ?Type = null;
    var index: usize = 0;
    while (index < assignment.steps.len) {
        if (element.kind == .invalid) break;
        // Section 4.5: a place that may be absent has nothing to assign into.
        // At the root, `assignment.name` is the thing to check; further down
        // the path there is no name to write into the correction, since the
        // optional is a field or an element rather than a binding.
        if (element.optional) {
            if (index == 0) {
                try self.reportWithHelp(
                    assignment.target_span,
                    "this is {f}, so there may be nothing to assign into",
                    .{element},
                    "Check it first with `if {s} != nothing {{ ... }}`.",
                    .{assignment.name},
                );
            } else {
                try self.report(
                    assignment.target_span,
                    "this is {f}, so there may be nothing to assign into",
                    .{element},
                    "Read it into a `var` first, check that for `nothing`, change it, then assign it back.",
                );
            }
            element = .invalid;
            break;
        }

        switch (assignment.steps[index]) {
            .field => |field| {
                last_owner = element;
                if (isClass(element)) {
                    root_frozen = false;
                    frozen = null;
                }
                if (element.kind != .struct_value) {
                    try self.report(
                        field.span,
                        "{f} has no field named `{s}`",
                        .{ element, field.name },
                        "Only a struct or class has fields.",
                    );
                    element = .invalid;
                    break;
                }
                if (try self.memberOwner(element, field.name)) |owner| {
                    if (try self.reportPrivate(owner, field.name, field.span)) {
                        element = .invalid;
                        break;
                    }
                }
                const found = for (element.user.?.fields) |candidate| {
                    if (std.mem.eql(u8, candidate.name, field.name)) break candidate;
                } else null;
                if (found == null) {
                    if (try self.propertyOf(element, field.name)) |property| {
                        if (index + 1 < assignment.steps.len) {
                            try self.reportComputedInPlace(field.name, field.span);
                            element = .invalid;
                            break;
                        }
                        if (!property.writable) {
                            try self.reportWithHelp(
                                field.span,
                                "`{s}` is a read-only property of {f}",
                                .{ field.name, element },
                                "It is computed each time it is read. Change what it is computed from instead, or give it a `set` block as a `var` property.",
                                .{},
                            );
                            element = .invalid;
                            break;
                        }
                        if (index == 0 and try self.requireReadyForSet(assignment, field.name, field.span)) {
                            element = .invalid;
                            break;
                        }
                        const setter_key = try std.fmt.allocPrint(self.arena, "{s}" ++ Resolver.setter_suffix, .{property.getter});
                        element = (try self.signatureFor(property.getter)).return_type;
                        _ = try self.signatureFor(setter_key);
                        if (!self.in_function) {
                            try self.checkCapturesOf(field.span, setter_key, field.name, "this assignment");
                            if (assignment.operation != null) try self.checkCapturesOf(field.span, property.getter, field.name, "this assignment");
                        }
                        index += 1;
                        continue;
                    }
                }
                const stored = found orelse {
                    try self.report(
                        field.span,
                        "{f} has no field named `{s}`",
                        .{ element, field.name },
                        "Check the field name in the type's declaration.",
                    );
                    element = .invalid;
                    break;
                };
                if (!stored.mutable and frozen == null) {
                    frozen = .{ .name = field.name, .span = field.span, .owner = element, .field_type = stored.type };
                }
                element = stored.type;
                index += 1;
            },
            .index => |index_expression| {
                if (element.kind == .string) {
                    try self.report(
                        assignment.target_span,
                        "a String cannot be changed in place",
                        .{},
                        "Strings are immutable. Build a new one instead, for example with `replace` or interpolation.",
                    );
                    element = .invalid;
                    break;
                }
                // Section 8.3: bracket assignment on a dictionary inserts a
                // new entry or replaces an existing value, so the key is a
                // key rather than a position and there is no missing one.
                if (element.kind == .dictionary) {
                    try self.requireKey(index_expression, element.key.?.*);
                    element = element.element.?.*;
                    index += 1;
                    continue;
                }
                try self.requireIndex(index_expression);
                if (element.kind == .set) {
                    try self.report(
                        assignment.target_span,
                        "a set has no keys to assign to",
                        .{},
                        "Put a value in with `add(value)`.",
                    );
                    element = .invalid;
                    break;
                }
                if (element.kind != .list) {
                    try self.report(
                        assignment.target_span,
                        "{f} cannot be indexed",
                        .{element},
                        "Only a list or a dictionary has elements to assign to.",
                    );
                    element = .invalid;
                    break;
                }
                element = element.element.?.*;
                index += 1;
            },
        }
    }
    while (index < assignment.steps.len) : (index += 1) {
        switch (assignment.steps[index]) {
            .index => |index_expression| try self.requireIndex(index_expression),
            .field => {},
        }
    }
    if (root_frozen) try self.requireMutable(assignment.name, assignment.name_span, binding.*);
    if (frozen) |field| {
        try self.reportFrozenField(field);
        element = .invalid;
    }

    const last_is_property = switch (assignment.steps[assignment.steps.len - 1]) {
        .field => |field| element.kind != .invalid and last_owner != null and
            (try self.propertyOf(last_owner.?, field.name)) != null,
        .index => false,
    };
    const last_field: ?[]const u8 = switch (assignment.steps[assignment.steps.len - 1]) {
        .field => |field| field.name,
        .index => null,
    };

    if (assignment.operation) |operation| {
        const value = try self.typeOf(assignment.value);
        const result = try self.arithmetic(assignment.target_span, operation, element, value);
        if (!result.assignableTo(element)) {
            try self.report(
                assignment.target_span,
                "`{s}` produces {f}, but this {s} is {f}",
                .{ operation.lexeme(), result, if (last_field != null) "field" else "element", element },
                if (operation == .divide)
                    "`/` always produces a Float. Use `//=` to keep whole numbers."
                else
                    "Use an operation whose result the place can hold.",
            );
        }
        return;
    }

    const value = try self.typeOfExpected(assignment.value, element);
    if (!value.assignableTo(element)) {
        if (last_is_property) {
            try self.report(
                assignment.value.span,
                "this is {f}, but the property `{s}` holds {f}",
                .{ value, last_field.?, element },
                "Assign a value of the property's type, or convert it first.",
            );
        } else if (last_field) |name| {
            try self.report(
                assignment.value.span,
                "this is {f}, but `{s}` is a field holding {f}",
                .{ value, name, element },
                "Assign a value of the field's type, or convert it first.",
            );
        } else {
            try self.report(
                assignment.value.span,
                "this is {f}, but the elements of `{s}` are {f}",
                .{ value, assignment.name, element },
                "A list holds one type of value. Assign one of that type, or convert it first.",
            );
        }
    }
}

/// `super.size = 3`: section 10.7's way for an overriding property's setter to
/// run the base class's version.
fn checkSuperAssignment(self: *Checker, assignment: Ast.Assignment) Error!void {
    const base = try self.typeOfSuper(assignment.name_span);
    const field = switch (assignment.steps[0]) {
        .field => |field| field,
        .index => |index| {
            try self.report(
                assignment.target_span,
                "`super` has no elements to assign to",
                .{},
                "`super` reaches a base class's version of a method or property. Write `super.name = ...`.",
            );
            try self.requireIndex(index);
            _ = try self.typeOf(assignment.value);
            return;
        },
    };
    if (base.kind == .invalid) {
        _ = try self.typeOf(assignment.value);
        return;
    }
    if (assignment.steps.len > 1) {
        try self.reportWithHelp(
            field.span,
            "what `super.{s}` gives back cannot be changed in place",
            .{field.name},
            "`super` reaches a base class's version of a property. Read it into a `var`, change that, then assign it back with `super.{s} = ...`.",
            .{field.name},
        );
        _ = try self.typeOf(assignment.value);
        return;
    }
    if (try self.memberOwner(base, field.name)) |owner| {
        if (try self.reportPrivate(owner, field.name, field.span)) {
            _ = try self.typeOf(assignment.value);
            return;
        }
    }
    for (base.user.?.fields) |stored| {
        if (!std.mem.eql(u8, stored.name, field.name)) continue;
        try self.reportWithHelp(
            field.span,
            "`{s}` is a field, so set it through `self`",
            .{field.name},
            "`super` reaches a base class's version of a method or property. A subclass never replaces a field, so `self.{s}` is the same one.",
            .{field.name},
        );
        _ = try self.typeOf(assignment.value);
        return;
    }
    const property = try self.propertyOf(base, field.name) orelse {
        try self.report(
            field.span,
            "{f} has no property named `{s}`",
            .{ base, field.name },
            "Check the property name in the base class's declaration.",
        );
        _ = try self.typeOf(assignment.value);
        return;
    };
    if (!property.writable) {
        try self.reportWithHelp(
            field.span,
            "`{s}` is a read-only property of {f}",
            .{ field.name, base },
            "It is computed each time it is read, and has no `set` block to run.",
            .{},
        );
        _ = try self.typeOf(assignment.value);
        return;
    }
    const setter_key = try std.fmt.allocPrint(self.arena, "{s}" ++ Resolver.setter_suffix, .{property.getter});
    const element = (try self.signatureFor(property.getter)).return_type;
    _ = try self.signatureFor(setter_key);
    try self.super_members.put(self.arena, assignment.value, setter_key);

    if (assignment.operation) |operation| {
        const value = try self.typeOf(assignment.value);
        const result = try self.arithmetic(assignment.target_span, operation, element, value);
        if (!result.assignableTo(element)) {
            try self.report(
                assignment.target_span,
                "`{s}` produces {f}, but this property is {f}",
                .{ operation.lexeme(), result, element },
                "Use an operation whose result the property can hold.",
            );
        }
        return;
    }
    const value = try self.typeOfExpected(assignment.value, element);
    if (!value.assignableTo(element)) {
        try self.report(
            assignment.value.span,
            "this is {f}, but the property `{s}` holds {f}",
            .{ value, field.name, element },
            "Assign a value of the property's type, or convert it first.",
        );
    }
}

/// Section 10.3: "Nested mutation through a computed value is rejected rather
/// than silently copying and writing back."
fn reportComputedInPlace(self: *Checker, name: []const u8, span: Source.Span) Error!void {
    try self.reportWithHelp(
        span,
        "`{s}` is a computed property, so what it gives back cannot be changed in place",
        .{name},
        "Read it into a `var`, change that, then assign it back with `.{s} = ...`.",
        .{name},
    );
}

fn requireReadyForSet(self: *Checker, assignment: Ast.Assignment, name: []const u8, span: Source.Span) Error!bool {
    if (self.constructing == null or !std.mem.eql(u8, assignment.name, "self")) return false;
    if (try self.reportOverridable(name, span, "set")) return true;
    const field = try self.firstUnsetField() orelse return false;
    try self.reportWithHelp(
        span,
        "`{s}` cannot be set until every field of `self` is set",
        .{name},
        "Set `self.{s}` first. A property may read any field, so it has to wait for all of them.",
        .{field},
    );
    return true;
}

/// The correction for a value that does not fit where it is used. Two list
/// types get their own, because section 4.4's invariance is a surprise to
/// anyone used to a language where an `[Int]` can pass for a `[Float]`.
fn mismatchHelp(actual: Type, expected: Type, general: []const u8) []const u8 {
    if (actual.kind == .list and expected.kind == .list) {
        return "A list keeps the element type it was built with, so one list type cannot stand in for another. Build the list with the type it needs, as in `var rates: [Float] = [1, 2]`.";
    }
    // Section 8.2: only a literal takes its kind from the expected type, so a
    // list already in a binding needs the conversion 8.2 names.
    if (actual.kind == .list and expected.kind == .set) {
        return "Only a bracketed literal becomes a set from the type expected around it. Convert it with `.to_set()`.";
    }
    if (actual.kind == .set and expected.kind == .list) {
        return "A set records what is in it, with no positions to index. Build a list from it, or keep a list instead if the order matters.";
    }
    return general;
}

/// Section 4.3 and 7.1: only a `var` may change. Each other reason for a
/// binding to be fixed gets the correction that fits it.
fn requireMutable(self: *Checker, name: []const u8, span: Source.Span, binding: Binding) Error!void {
    switch (binding.mutability) {
        .variable => {},
        .constant => try self.reportWithHelp(
            span,
            "`{s}` is a `const`, so its contents cannot change",
            .{name},
            "Declare `{s}` with `var` if it needs to change.",
            .{name},
        ),
        .parameter => try self.reportWithHelp(
            span,
            "`{s}` is a parameter, so a change to it would be lost when the function returns",
            .{name},
            "Copy it into a `var`, change the copy, and return it, as in `var changed = {s}`.",
            .{name},
        ),
        .loop_variable => try self.report(
            span,
            "`{s}` is a loop variable, so a change to it would be lost",
            .{name},
            "It holds a copy of one element. To change the list itself, loop over its indices and assign through them.",
        ),
    }
}

/// Section 4.1 proves definite assignment through control flow. A name counts as
/// assigned after an `if` only when every path assigns it, which means both a
/// `then` and an `else` that each assign it. Without an `else` there is a path
/// that skips the block entirely, so nothing is proved.
///
/// A branch that cannot fall through — it returns, breaks, or continues — is
/// left out of the merge rather than intersected into it. Otherwise a guard
/// clause like
///
///     var x: Int
///     if cond { x = 1 } else { return }
///     print(x)
///
/// would be rejected, even though the only way to reach `print(x)` is through
/// the branch that assigns it.
fn checkConditional(self: *Checker, conditional: Ast.If) Error!void {
    try self.requireCondition(conditional.condition);

    const before = try self.snapshot();
    // Section 4.5: inside the block, the condition held.
    self.narrow(conditional.condition, true);
    try self.checkBlock(conditional.then_block);
    const after_then = try self.snapshot();
    const then_returns = !self.blockCompletes(conditional.then_block.statements);

    const otherwise = conditional.otherwise orelse {
        // No else: the block may not have run at all, so what follows is the
        // merge of running it and skipping it. A block that always returns
        // is left out, since reaching past it means it did not run. Restoring
        // alone is not a merge: it would keep a narrowing the block undid by
        // assigning `nothing`, and a constructor's record that a `const`
        // field is still unset after a block that set it.
        self.restore(before);
        if (!then_returns) self.intersect(after_then);
        // Unless it always returns, in which case getting here proves the
        // condition failed. That is what makes a guard — `return if
        // name == nothing` — narrow the whole rest of the block.
        if (then_returns) self.narrow(conditional.condition, false);
        return;
    };

    self.restore(before);
    self.narrow(conditional.condition, false);
    const otherwise_returns = switch (otherwise) {
        .block => |block| blk: {
            try self.checkBlock(block);
            break :blk !self.blockCompletes(block.statements);
        },
        .chained => |chained| blk: {
            try self.checkStatement(chained.*);
            break :blk !self.stmtCompletes(chained.*);
        },
    };

    if (then_returns and otherwise_returns) {
        // Nothing after the `if` is reachable. Section 14.1's warning for
        // unreachable code is deferred (diagnostics have no severity yet), so
        // rather than report "may not have been assigned" in code that can
        // never run, every binding counts as assigned from here.
        self.markAllAssigned();
    } else if (then_returns) {
        // Only the else branch continues, and checking it left its state in
        // place.
    } else if (otherwise_returns) {
        self.restore(after_then);
    } else {
        self.intersect(after_then);
    }
}

fn checkReturn(self: *Checker, return_statement: Ast.Return) Error!void {
    if (!self.in_function) {
        try self.report(
            return_statement.keyword_span,
            "`return` can only be used inside a function",
            .{},
            "Remove it, or move this code into a function.",
        );
        return;
    }

    if (self.constructing != null) {
        if (return_statement.value) |value| {
            _ = try self.typeOf(value);
            try self.report(
                value.span,
                "a constructor cannot return a value",
                .{},
                "It always produces the value being built. Use a bare `return` to finish early.",
            );
            return;
        }
        // Section 10.2: "A bare constructor `return` is allowed only after all
        // fields are initialized."
        if (try self.firstUnsetField()) |field| {
            try self.reportWithHelp(
                return_statement.keyword_span,
                "this `return` finishes the constructor without setting `{s}`",
                .{field},
                "Set `self.{s}` before returning.",
                .{field},
            );
        }
        return;
    }

    const value = return_statement.value orelse {
        if (self.current_return_type) |expected| {
            if (expected.kind != .nothing and expected.kind != .invalid) {
                try self.report(
                    return_statement.keyword_span,
                    "this function must return a value",
                    .{},
                    "Add a value, as in `return 0`.",
                );
            }
        } else {
            // While inferring, a bare return contributes Nothing, so a body
            // that returns a value on one path and nothing on another is
            // reported as ambiguous by `inferredReturnType`.
            try self.pending_return_types.append(self.arena, .nothing);
        }
        return;
    };

    const actual = try self.typeOfExpected(value, self.current_return_type);
    const expected = self.current_return_type orelse {
        try self.pending_return_types.append(self.arena, actual);
        return;
    };

    if (expected.kind == .nothing) {
        // Only reachable through an explicit `: Nothing`. Without an
        // annotation, a body with `return expr` has its type inferred from
        // that value, per section 7.2's distinction between "no result" and an
        // explicit `Nothing`.
        try self.report(
            value.span,
            "this function returns Nothing, so `return` cannot produce a value",
            .{},
            "Remove the value, or declare the function with the type of what it returns.",
        );
    } else if (expected.kind != .invalid and !actual.assignableTo(expected)) {
        try self.report(
            value.span,
            "this is {f}, but the function returns {f}",
            .{ actual, expected },
            mismatchHelp(actual, expected, "Return a value of the declared type, or convert it first."),
        );
    }
}

// Functions.

/// A function's signature, computed once on first need.
///
/// Section 7.2 requires an explicit return type on a recursive or mutually
/// recursive function "so checking does not depend on circular inference".
/// Inference only happens after that is ruled out, which is what keeps this
/// from chasing its own tail. A provisional signature is stored while inferring
/// all the same, so a re-entrant call could never recurse forever.
/// `key` names the declaration program-wide; see `Checker.keyOf`.
fn signatureFor(self: *Checker, key: []const u8) Error!Signature {
    if (self.signatures.get(key)) |signature| {
        if (self.inferring.contains(key)) {
            _ = self.inferring.remove(key);
            const declaration = self.declarations.get(key).?;
            const outer_file = self.file;
            defer self.file = outer_file;
            if (self.facts.owner.get(key)) |owner| self.file = owner;
            try self.report(
                declaration.name_span,
                "`{s}` needs an explicit return type",
                .{declaration.name},
                "Working out what it returns reaches a type-level field whose value calls it. Add a return type, or give that field a type.",
            );
        }
        return signature;
    }

    const declaration = self.declarations.get(key).?;

    // Everything below reports against the declaration, and may check its
    // body, so the file is the one that wrote it rather than the one that
    // needed its type.
    const outer_file = self.file;
    defer self.file = outer_file;
    if (self.facts.owner.get(key)) |owner| self.file = owner;

    // Only the written parameter and result types see `Self`; a body
    // inferred below does not.
    const outer_self = self.written_self;
    defer self.written_self = outer_self;
    self.written_self = self.selfInSignatureOf(key);

    const parameter_types = try self.arena.alloc(Type, declaration.parameters.len);
    const parameter_names = try self.arena.alloc([]const u8, declaration.parameters.len);
    for (declaration.parameters, 0..) |parameter, index| {
        parameter_types[index] = try self.resolveTypeExpression(parameter.annotation);
        parameter_names[index] = parameter.name;
    }

    var signature: Signature = .{
        .parameters = parameter_types,
        .parameter_names = parameter_names,
        .return_type = .invalid,
    };

    const return_annotation = if (declaration.return_annotation) |annotation|
        try self.resolveTypeExpression(annotation)
    else
        null;
    self.written_self = outer_self;

    if (return_annotation) |annotated| {
        signature.return_type = annotated;
    } else if (!self.blockHasValueReturn(declaration.body.statements)) {
        // Nothing to infer: section 7.2's "a function returning no value may
        // omit its return type".
        signature.return_type = .nothing;
    } else if (try self.isRecursive(key)) {
        try self.report(
            declaration.name_span,
            "`{s}` is recursive and needs an explicit return type",
            .{declaration.name},
            "Add a return type, so checking does not depend on inferring it from a call to itself.",
        );
    } else {
        try self.signatures.put(self.arena, key, signature); // provisional
        const saved_pending = self.pending_return_types;
        self.pending_return_types = .empty;

        try self.inferring.put(self.arena, key, {});
        try self.checkKeyedBody(key, declaration, parameter_types, null);
        _ = self.inferring.remove(key);
        try self.bodies_checked.put(self.arena, key, {});

        signature.return_type = try self.inferredReturnType(
            self.pending_return_types.items,
            declaration.name,
            declaration.name_span,
        );
        self.pending_return_types = saved_pending;
        try self.checkAllPathsReturn(declaration, signature.return_type);
    }

    try self.signatures.put(self.arena, key, signature);
    return signature;
}

/// What `Self` means in the signature of the function `key`: the type, for a
/// method or a type-level function of a struct or class, and section 11.4's
/// opaque `Self` for a trait's method. A property's type is written out, so
/// its accessors have none.
fn selfInSignatureOf(self: *Checker, key: []const u8) ?Type {
    if (self.receivers.get(key)) |receiver| {
        if (self.properties.contains(key) or std.mem.endsWith(u8, key, Resolver.setter_suffix)) return null;
        return ownSelf(receiver.user.?);
    }
    const type_key = self.facts.type_members.get(key) orelse return null;
    return self.structs.get(type_key);
}

/// The type `self` has inside a member of `user`.
fn ownSelf(user: *const Type.User) Type {
    return if (user.trait) Type.selfOf(user) else Type.structOf(user);
}

/// Section 11.4: a trait member's signature as seen on a value of `receiver`.
/// `Self` becomes the receiver's own `Self` inside a trait, the adopting type
/// on a concrete value, and the trait itself on a value seen through a trait,
/// where a parameter of type `Self` cannot be given anything (see
/// `takesSelf`).
fn signatureOn(self: *Checker, signature: Signature, receiver: Type) Error!Signature {
    var mentions = signature.return_type.mentionsSelf();
    for (signature.parameters) |parameter| mentions = mentions or parameter.mentionsSelf();
    if (!mentions) return signature;
    const parameters = try self.arena.alloc(Type, signature.parameters.len);
    for (signature.parameters, parameters) |parameter, *replaced| {
        replaced.* = try self.replaceSelf(parameter, receiver.payload());
    }
    return .{
        .parameters = parameters,
        .parameter_names = signature.parameter_names,
        .return_type = try self.replaceSelf(signature.return_type, receiver.payload()),
    };
}

/// Whether a parameter of a member reached through `receiver` is `Self`,
/// which a value seen through a trait cannot know the type of.
fn takesSelf(signature: Signature, receiver: Type) bool {
    if (receiver.kind != .struct_value or receiver.opaque_self or !receiver.user.?.trait) return false;
    for (signature.parameters) |parameter| {
        if (parameter.mentionsSelf()) return true;
    }
    return false;
}

fn reportTakesSelf(self: *Checker, span: Source.Span, name: []const u8, receiver: Type) Error!void {
    try self.reportWithHelp(
        span,
        "`{s}` takes `Self`, which a value seen as `{s}` cannot supply",
        .{ name, receiver.user.?.display_name },
        "Every type that adopts `{s}` takes a value of its own type here, and this value could be any of them. Call `{s}` on a value whose type is known.",
        .{ receiver.user.?.display_name, name },
    );
}

fn replaceSelf(self: *Checker, t: Type, receiver: Type) Error!Type {
    if (!t.mentionsSelf()) return t;
    switch (t.kind) {
        .struct_value => {
            var replaced = if (receiver.opaque_self or receiver.user.?.trait)
                receiver
            else
                Type.structOf(adopterOf(receiver.user.?, t.user.?));
            replaced.optional = t.optional;
            return replaced;
        },
        .list, .set => {
            const element = try self.arena.create(Type);
            element.* = try self.replaceSelf(t.element.?.*, receiver);
            var replaced = t;
            replaced.element = element;
            return replaced;
        },
        .dictionary => {
            const key = try self.arena.create(Type);
            key.* = try self.replaceSelf(t.key.?.*, receiver);
            const element = try self.arena.create(Type);
            element.* = try self.replaceSelf(t.element.?.*, receiver);
            var replaced = t;
            replaced.key = key;
            replaced.element = element;
            return replaced;
        },
        .tuple => {
            const elements = try self.arena.alloc(Type, t.elements.len);
            for (t.elements, elements) |element, *slot| slot.* = try self.replaceSelf(element, receiver);
            var replaced = t;
            replaced.elements = elements;
            return replaced;
        },
        .function => {
            const signature = try self.arena.create(Signature);
            signature.* = try self.signatureOn(t.signature.?.*, receiver);
            var replaced = t;
            replaced.signature = signature;
            return replaced;
        },
        .nothing, .bool, .int, .float, .string, .invalid => return t,
    }
}

/// Section 11.4: `Self` in `trait` on a value of the class `user` is the
/// class that first adopts `trait` along its chain of base classes, since a
/// subclass inherits its methods without changing their types. On a struct
/// it is the struct.
fn adopterOf(user: *const Type.User, trait: *const Type.User) *const Type.User {
    var found = user;
    var at = user.base;
    while (at) |base| : (at = base.base) {
        if (base.conformsTo(trait)) found = base;
    }
    return found;
}

fn ensureBodyChecked(self: *Checker, key: []const u8) Error!void {
    // A body belongs to the file that wrote it, whichever file the call that
    // needed its type happens to be in.
    const outer_file = self.file;
    defer self.file = outer_file;
    if (self.facts.owner.get(key)) |owner| self.file = owner;

    const signature = try self.signatureFor(key);
    if (self.bodies_checked.contains(key)) return;
    try self.bodies_checked.put(self.arena, key, {});

    const declaration = self.declarations.get(key).?;
    try self.checkKeyedBody(key, declaration, signature.parameters, signature.return_type);
    try self.checkAllPathsReturn(declaration, signature.return_type);
}

/// Checks a function body against its parameters and a view of the module and
/// prelude in which everything counts as assigned (see the module comment).
///
/// The view is a fresh copy, so nothing done inside the body — assignments,
/// merging branches — can disturb the definite-assignment state of the top level
/// that is paused while an early inference runs.
///
/// `expected_return_type` of null means the return type is being inferred.
fn checkFunctionBody(
    self: *Checker,
    declaration: Ast.FunctionDeclaration,
    parameter_types: []const Type,
    expected_return_type: ?Type,
) Error!void {
    try self.checkBody(declaration.parameters, parameter_types, declaration.body.statements, expected_return_type, null);
}

/// The prelude and module scope as a body sees them: a copy in which every
/// binding counts as assigned (see the module comment).
fn moduleView(self: *Checker) Error!*Scope {
    const view = try self.arena.create(Scope);
    view.* = .empty;
    // The module scope second, so a program function named like a prelude
    // function shadows it, as it does at the top level.
    for ([_]*const Scope{ self.prelude, self.module }) |source| {
        var entries = source.iterator();
        while (entries.next()) |entry| {
            var binding = entry.value_ptr.*;
            binding.assigned = true;
            try view.put(self.arena, entry.key_ptr.*, binding);
        }
    }
    return view;
}

/// The key a function body is known by decides whether it has a `self`.
fn checkKeyedBody(
    self: *Checker,
    key: []const u8,
    declaration: Ast.FunctionDeclaration,
    parameter_types: []const Type,
    expected_return_type: ?Type,
) Error!void {
    if (self.nested.get(key)) |depth| {
        return self.checkNestedBody(depth, declaration, parameter_types, expected_return_type);
    }
    const receiver = self.receivers.get(key) orelse
        return self.checkFunctionBody(declaration, parameter_types, expected_return_type);
    try self.checkBodyWithSelf(declaration.parameters, parameter_types, declaration.body.statements, expected_return_type, null, ownSelf(receiver.user.?));
}

/// A nested function's body, which sees the scopes in force where it is
/// declared (7.1). It may run at any point after it is hoisted, so as for a
/// program function, every variable counts as assigned and nothing proved
/// about one applies; each use of the function checks instead.
fn checkNestedBody(
    self: *Checker,
    depth: usize,
    declaration: Ast.FunctionDeclaration,
    parameter_types: []const Type,
    expected_return_type: ?Type,
) Error!void {
    const before = try self.snapshot();
    const outer_scopes = self.scopes;
    defer {
        self.scopes = outer_scopes;
        self.restore(before);
    }
    for (outer_scopes.items[0..depth]) |scope| {
        var values = scope.valueIterator();
        while (values.next()) |binding| {
            binding.assigned = true;
            binding.type = binding.declared;
        }
    }
    try self.checkBodyWithSelfIn(
        outer_scopes.items[0..depth],
        declaration.parameters,
        parameter_types,
        declaration.body.statements,
        expected_return_type,
        null,
        null,
    );
}

/// The one way a body is checked, whether a function's or a constructor's.
fn checkBody(
    self: *Checker,
    parameter_list: []const Ast.Parameter,
    parameter_types: []const Type,
    statements: []const Ast.Statement,
    expected_return_type: ?Type,
    constructing: ?Constructing,
) Error!void {
    try self.checkBodyWithSelf(parameter_list, parameter_types, statements, expected_return_type, constructing, null);
}

/// `receiver` is a method's type, whose `self` is an ordinary changeable
/// binding; whether the method changes it is worked out from the body.
fn checkBodyWithSelf(
    self: *Checker,
    parameter_list: []const Ast.Parameter,
    parameter_types: []const Type,
    statements: []const Ast.Statement,
    expected_return_type: ?Type,
    constructing: ?Constructing,
    receiver: ?Type,
) Error!void {
    const view = try self.moduleView();
    return self.checkBodyWithSelfIn(&.{view}, parameter_list, parameter_types, statements, expected_return_type, constructing, receiver);
}

/// `enclosing` is what the body sees besides its parameters: a view of the
/// module, or for a nested function the scopes around its declaration.
fn checkBodyWithSelfIn(
    self: *Checker,
    enclosing: []const *Scope,
    parameter_list: []const Ast.Parameter,
    parameter_types: []const Type,
    statements: []const Ast.Statement,
    expected_return_type: ?Type,
    constructing: ?Constructing,
    receiver: ?Type,
) Error!void {
    const parameters = try self.arena.create(Scope);
    parameters.* = .empty;
    for (parameter_list, parameter_types) |parameter, parameter_type| {
        try parameters.put(self.arena, parameter.name, .{
            .type = parameter_type,
            .declared = parameter_type,
            .assigned = true,
            .mutability = .parameter,
        });
    }
    if (receiver) |method_type| {
        try parameters.put(self.arena, "self", .{
            .type = method_type,
            .declared = method_type,
            .assigned = true,
        });
    }
    if (constructing) |building| {
        // `self` itself is always there to set fields on; whether it may be
        // used as a whole is decided from its fields (see `firstUnsetField`).
        try parameters.put(self.arena, "self", .{
            .type = building.type,
            .declared = building.type,
            .assigned = true,
        });
        for (building.type.user.?.fields, 0..) |field, position| {
            const set = building.setAtStart(position);
            try parameters.put(self.arena, try fieldSetKey(self.arena, field.name), .{
                .type = field.type,
                .declared = field.type,
                .assigned = set,
            });
            // Assigned here means "certainly not set yet", which intersects
            // the right way at a merge: a `const` field may be set only where
            // every path into this point left it unset.
            try parameters.put(self.arena, try fieldUnsetKey(self.arena, field.name), .{
                .type = field.type,
                .declared = field.type,
                .assigned = !set,
            });
        }
    }

    const outer_scopes = self.scopes;
    const outer_return_type = self.current_return_type;
    const outer_in_function = self.in_function;
    const outer_loops = self.loops;
    const outer_constructing = self.constructing;
    defer {
        self.scopes = outer_scopes;
        self.current_return_type = outer_return_type;
        self.in_function = outer_in_function;
        self.loops = outer_loops;
        self.constructing = outer_constructing;
    }

    self.scopes = .empty;
    self.loops = .empty;
    try self.scopes.appendSlice(self.arena, enclosing);
    try self.scopes.append(self.arena, parameters);
    self.current_return_type = expected_return_type;
    self.in_function = true;
    self.constructing = constructing;

    // Section 7.3's defaults, each against its parameter's type. The resolver
    // has already kept each from reading itself or a later parameter.
    for (parameter_list, parameter_types) |parameter, parameter_type| {
        const default = parameter.default orelse continue;
        // A default works out a value for the call, as the arguments before
        // it do, so like a getter (10.3) it may not change `self`. Its change
        // could otherwise be lost, or reach a `const`, depending on whether
        // the rest of the method happens to change `self` too.
        if (receiver) |method_type| if (!method_type.user.?.class) {
            if (try self.expressionChangesSelf(default, method_type)) {
                try self.report(
                    default.span,
                    "this default would change `self`",
                    .{},
                    "A default only works out a value for the call. Change `self` in the method's body instead.",
                );
            }
        };
        self.in_parameter_default = true;
        const actual = self.typeOfExpected(default, parameter_type) catch |err| {
            self.in_parameter_default = false;
            return err;
        };
        self.in_parameter_default = false;
        if (!actual.assignableTo(parameter_type)) {
            try self.report(
                default.span,
                "this default is {f}, but `{s}` is {f}",
                .{ actual, parameter.name, parameter_type },
                mismatchHelp(actual, parameter_type, "Give the parameter a default of its own type."),
            );
        }
    }

    if (constructing) |building| {
        if (building.part == .default_of) {
            const position = building.part.default_of;
            const field = building.declaration.fields[position];
            const wanted = building.type.user.?.fields[building.type.user.?.inherited + position].type;
            const actual = try self.typeOfExpected(field.default.?, wanted);
            if (!actual.assignableTo(wanted)) {
                try self.report(
                    field.default.?.span,
                    "this default is {f}, but `{s}` is a field holding {f}",
                    .{ actual, field.name, wanted },
                    mismatchHelp(actual, wanted, "Give the field a default of its own type."),
                );
            }
            return;
        }
    }

    // The body's top level shares the parameters' scope, as in the resolver.
    try self.checkStatements(statements);

    // Section 10.2: "Every remaining field must be definitely initialized
    // before construction completes." A body that cannot fall off its end has
    // had each of its `return`s checked instead.
    if (constructing) |building| {
        if (self.blockCompletes(statements)) {
            if (try self.firstUnsetField()) |field| {
                try self.reportWithHelp(
                    building.keyword_span,
                    "this constructor can finish without setting `{s}`",
                    .{field},
                    "Set `self.{s}` on every path through the constructor.",
                    .{field},
                );
            }
        }
    }
}

// Type-level fields.

/// Makes a type-level field's type known. One without an annotation takes the
/// type of its value, which is checked here on first need; needing it again
/// while that value is still being checked is a cycle, which an annotation
/// breaks, exactly as section 7.2 has a recursive function state its return
/// type.
fn settleTypeField(self: *Checker, key: []const u8) Error!void {
    const field = self.type_fields.getPtr(key) orelse return;
    switch (field.state) {
        .known => return,
        .inferring => {
            const outer_file = self.file;
            defer self.file = outer_file;
            self.file = self.facts.owner.get(key).?;
            try self.reportWithHelp(
                field.field.name_span,
                "`{s}` needs a type, because working out its value needs its type",
                .{try Resolver.displayKey(self.arena, key)},
                "Write its type, as in `var {s}: Int = ...`.",
                .{try Resolver.displayKey(self.arena, key)},
            );
            // Left invalid, so the reads inside the cycle stay quiet.
            field.state = .known;
            return;
        },
        .unknown => {},
    }
    field.state = .inferring;
    const actual = try self.typeFieldValue(key);
    // Found again: checking the value can reach other fields, though never add
    // one, so the entry has not moved, but `field` is not used past here.
    const binding = self.module.getPtr(key).?;
    binding.type = actual;
    binding.declared = actual;
    const settled = self.type_fields.getPtr(key).?;
    settled.state = .known;
    settled.value_checked = true;
}

/// Checks a type-level field's value once, whichever of inference or the pass
/// over every declaration gets there first.
fn checkTypeFieldValue(self: *Checker, key: []const u8) Error!void {
    const field = self.type_fields.get(key) orelse return;
    if (field.value_checked) return;
    if (field.field.annotation == null) return self.settleTypeField(key);
    self.type_fields.getPtr(key).?.value_checked = true;
    _ = try self.typeFieldValue(key);
}

/// The type of a type-level field's value, reported against its annotation if
/// it has one. The value runs whenever the type is first reached, so like a
/// function body it is checked against a module scope in which everything
/// counts as assigned, and section 7.1's check happens where it is reached.
fn typeFieldValue(self: *Checker, key: []const u8) Error!Type {
    const field = self.type_fields.get(key).?;
    const outer_file = self.file;
    defer self.file = outer_file;
    self.file = self.facts.owner.get(key).?;

    const view = try self.moduleView();
    const outer_scopes = self.scopes;
    const outer_return_type = self.current_return_type;
    const outer_in_function = self.in_function;
    const outer_loops = self.loops;
    const outer_constructing = self.constructing;
    defer {
        self.scopes = outer_scopes;
        self.current_return_type = outer_return_type;
        self.in_function = outer_in_function;
        self.loops = outer_loops;
        self.constructing = outer_constructing;
    }
    self.scopes = .empty;
    self.loops = .empty;
    try self.scopes.append(self.arena, view);
    self.in_function = true;
    self.constructing = null;

    const expected: ?Type = if (field.field.annotation != null) self.module.get(key).?.declared else null;
    const actual = try self.typeOfExpected(field.field.initializer, expected);
    const declared = expected orelse return actual;
    if (!actual.assignableTo(declared)) {
        try self.report(
            field.field.initializer.span,
            "this is {f}, but `{s}` was declared as {f}",
            .{ actual, try Resolver.displayKey(self.arena, key), declared },
            mismatchHelp(actual, declared, "Give the declaration the type of its value, or convert the value to match."),
        );
    }
    return declared;
}

/// Section 10.5: a member whose name starts with `_` can be reached only from
/// code written inside its own type's braces, which includes lambdas there and
/// other values of the same type. Returns whether it reported.
fn reportPrivate(self: *Checker, type_key: []const u8, name: []const u8, span: Source.Span) Error!bool {
    if (!Resolver.isPrivate(name) or self.insideType(type_key, span)) return false;
    const owner = self.structs.get(type_key).?.user.?.display_name;
    try self.reportWithHelp(
        span,
        "`{s}` is private to `{s}`",
        .{ name, owner },
        "Only code written inside `{s}`'s braces can reach a name that starts with `_`.",
        .{owner},
    );
    return true;
}

/// The same for a type-level member, known by its key. Returns whether it
/// reported.
fn reportPrivateTypeMember(self: *Checker, key: []const u8, span: Source.Span) Error!bool {
    const type_key = self.facts.type_members.get(key) orelse return false;
    const at = std.mem.lastIndexOf(u8, key, Resolver.method_separator).?;
    return self.reportPrivate(type_key, key[at + Resolver.method_separator.len ..], span);
}

fn insideType(self: *Checker, type_key: []const u8, span: Source.Span) bool {
    const extent = self.type_spans.get(type_key) orelse return true;
    return self.facts.owner.get(type_key) == self.file and
        span.start >= extent.start and span.end <= extent.end;
}

/// Whether `name` is one of a struct's instance members: a field, a property,
/// or a method.
fn isInstanceMember(self: *Checker, owner: Type, name: []const u8) Error!bool {
    return try self.memberOwner(owner, name) != null;
}

/// `value.count` where `count` is a type-level member of its type. Returns
/// whether it reported.
fn reportTypeMemberThroughValue(self: *Checker, owner: Type, name: []const u8, span: Source.Span) Error!bool {
    // Type-level members are not inherited (10.7), but one of a base class is
    // still what the reader was reaching for.
    var at: ?*const Type.User = owner.user;
    const declaring, const key = while (at) |user| : (at = user.base) {
        const candidate = try Resolver.methodKey(self.arena, user.name, name);
        if (self.facts.type_members.contains(candidate)) break .{ user, candidate };
    } else return false;
    // Section 10.5: pointing at the type would point at a path that is private
    // too.
    if (try self.reportPrivate(declaring.name, name, span)) return true;
    const written = try Resolver.displayKey(self.arena, key);
    try self.reportWithHelp(
        span,
        "`{s}` belongs to the type `{s}`, not to each value",
        .{ name, declaring.display_name },
        "Reach it through the type, as in `{s}`.",
        .{written},
    );
    return true;
}

// Constructors.

/// The binding that records whether `self.name` has certainly been set. A
/// leading `.` cannot begin any name or key, so it collides with nothing.
fn fieldSetKey(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, ".{s}", .{name});
}

/// The binding that records whether `self.name` has certainly not been set
/// yet. A leading `!` cannot begin any name either.
fn fieldUnsetKey(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(arena, "!{s}", .{name});
}

fn fieldSetBinding(self: *Checker, name: []const u8) Error!?*Binding {
    return self.find(try fieldSetKey(self.arena, name));
}

/// The first field, in declaration order, not certainly set here. Declaration
/// order keeps the report stable and matches how a reader scans the struct.
fn firstUnsetField(self: *Checker) Error!?[]const u8 {
    const building = self.constructing orelse return null;
    for (building.type.user.?.fields) |field| {
        const binding = try self.fieldSetBinding(field.name) orelse continue;
        if (!binding.assigned) return field.name;
    }
    return null;
}

/// A struct's constructor, as a signature the interpreter can widen arguments
/// through exactly as it does a function's. Stored under the type's key.
fn constructorSignature(self: *Checker, key: []const u8) Error!Signature {
    if (self.signatures.get(key)) |signature| return signature;
    const declaration = self.constructors.get(key).?;
    const constructor = declaration.constructor.?;

    const outer_file = self.file;
    defer self.file = outer_file;
    if (self.facts.owner.get(key)) |owner| self.file = owner;

    const parameter_types = try self.arena.alloc(Type, constructor.parameters.len);
    const parameter_names = try self.arena.alloc([]const u8, constructor.parameters.len);
    for (constructor.parameters, 0..) |parameter, index| {
        parameter_types[index] = try self.resolveTypeExpression(parameter.annotation);
        parameter_names[index] = parameter.name;
    }
    const signature: Signature = .{
        .parameters = parameter_types,
        .parameter_names = parameter_names,
        .return_type = self.structs.get(key).?,
    };
    try self.signatures.put(self.arena, key, signature);
    return signature;
}

fn checkConstructorBody(self: *Checker, key: []const u8) Error!void {
    const outer_file = self.file;
    defer self.file = outer_file;
    if (self.facts.owner.get(key)) |owner| self.file = owner;

    const signature = try self.constructorSignature(key);
    const constructor = self.constructors.get(key).?.constructor.?;
    const super_call = superCallOf(constructor.body.statements);
    if (self.structs.get(key).?.user.?.base) |base| {
        if (super_call == null and try self.constructionNeedsArguments(base.name)) {
            try self.reportWithHelp(
                constructor.keyword_span,
                "this constructor has to start with `super(...)`, because building `{s}` takes arguments",
                .{base.display_name},
                "Pass what `{s}` needs on the constructor's first line, as in `super(...)`, before anything else.",
                .{base.display_name},
            );
        }
    }
    try self.checkBody(
        constructor.parameters,
        signature.parameters,
        constructor.body.statements,
        .nothing,
        .{
            .type = self.structs.get(key).?,
            .keyword_span = constructor.keyword_span,
            .declaration = self.constructors.get(key).?,
            .super_call = super_call,
        },
    );
}

/// Section 10.2's field defaults, each in the state construction is in when it
/// runs, so reading a field that is not set yet is the same error it would be
/// in a constructor body.
fn checkFieldDefaults(self: *Checker, key: []const u8) Error!void {
    const outer_file = self.file;
    defer self.file = outer_file;
    if (self.facts.owner.get(key)) |owner| self.file = owner;

    const declaration = self.struct_declarations.get(key).?;
    for (declaration.fields, 0..) |field, position| {
        if (field.default == null) continue;
        try self.checkBody(&.{}, &.{}, &.{}, .nothing, .{
            .type = self.structs.get(key).?,
            .keyword_span = field.name_span,
            .declaration = declaration,
            .part = .{ .default_of = position },
        });
    }
}

/// `self.x = value` and friends inside a constructor. Returns whether the
/// assignment was fully handled here; the rest go on to the ordinary place
/// check with `self` as their root, once the field they start from is known
/// to be set.
fn checkSelfAssignment(self: *Checker, assignment: Ast.Assignment) Error!bool {
    const building = self.constructing orelse return false;
    if (!std.mem.eql(u8, assignment.name, "self")) return false;
    const field = switch (assignment.steps[0]) {
        .field => |field| field,
        // Indexing a struct is reported by the ordinary check.
        .index => return false,
    };

    const set = try self.fieldSetBinding(field.name) orelse {
        // Not a field at all, which the ordinary check reports.
        return false;
    };
    if (try self.memberOwner(building.type, field.name)) |owner| {
        if (try self.reportPrivate(owner, field.name, field.span)) {
            _ = try self.typeOf(assignment.value);
            return true;
        }
    }
    const stored = for (building.type.user.?.fields) |candidate| {
        if (std.mem.eql(u8, candidate.name, field.name)) break candidate;
    } else unreachable;

    if (assignment.steps.len > 1 or assignment.operation != null) {
        // Reaching into a field, or combining with it, reads it first.
        if (!set.assigned) {
            try self.reportWithHelp(
                field.span,
                "`self.{s}` is read here before it is set",
                .{field.name},
                "Set `self.{s}` first, as in `self.{s} = ...`.",
                .{ field.name, field.name },
            );
            set.assigned = true;
        }
        return false;
    }

    // Setting the field. Section 10.2 lets a constructor initialize a `const`
    // field; section 4.3 still means it is set exactly once.
    const unset = self.find(try fieldUnsetKey(self.arena, field.name)).?;
    if (!stored.mutable and !std.mem.eql(u8, stored.owner, building.type.user.?.name)) {
        // Section 10.7: the base class's part is built before this runs.
        const owner = self.structs.get(stored.owner).?.user.?.display_name;
        try self.reportWithHelp(
            field.span,
            "`{s}` is a `const` field that `{s}` sets",
            .{ field.name, owner },
            "A subclass cannot change it. Pass the value to `super(...)` so `{s}` sets it.",
            .{owner},
        );
    } else if (!stored.mutable) {
        if (self.loops.items.len > 0) {
            try self.reportWithHelp(
                field.span,
                "`{s}` is a `const` field, so it cannot be set inside a loop",
                .{field.name},
                "A loop can run more than once. Set `self.{s}` once, before or after the loop.",
                .{field.name},
            );
        } else if (!unset.assigned and hasDefault(building.declaration, field.name)) {
            try self.reportWithHelp(
                field.span,
                "`{s}` is a `const` field with a default, so the constructor cannot set it",
                .{field.name},
                "Its default runs before the constructor does. Remove the default if the constructor should decide `{s}`.",
                .{field.name},
            );
        } else if (!unset.assigned) {
            try self.reportWithHelp(
                field.span,
                "`{s}` is a `const` field and may already be set here",
                .{field.name},
                "A `const` field is set once. Declare it `var {s}: {f}` in {f} if it needs to change.",
                .{ field.name, stored.type, building.type },
            );
        }
    }

    const value = try self.typeOfExpected(assignment.value, stored.type);
    if (!value.assignableTo(stored.type)) {
        try self.report(
            assignment.value.span,
            "this is {f}, but `{s}` is a field holding {f}",
            .{ value, field.name, stored.type },
            mismatchHelp(value, stored.type, "Assign a value of the field's type, or convert it first."),
        );
    }
    set.assigned = true;
    unset.assigned = false;
    return true;
}

// Methods.

/// Section 4.3: "The checker determines which struct methods mutate `self` from
/// their bodies, so there is no `mutating` keyword." A method changes `self`
/// when its body assigns into `self`, calls a changing collection method on
/// something reached from `self`, or calls a method on `self` that does.
///
/// Worked out from the text, with field types to follow a path such as
/// `self.inner.items.append(x)` to the method it reaches, so the answer is
/// ready at any call site whether or not the body has been checked yet. Only
/// a path that starts at `self` counts: `var copy = self` followed by
/// `copy.x = 1` changes a copy, which is exactly what value semantics says.
fn methodChanges(self: *Checker, key: []const u8) Error!bool {
    if (self.changes.get(key)) |known| return known;
    // A cycle of methods calling each other: the one being worked out adds
    // nothing it does not already add through its own body.
    if (self.changes_in_progress.contains(key)) return false;
    try self.changes_in_progress.put(self.arena, key, {});
    defer _ = self.changes_in_progress.remove(key);

    const declaration = self.declarations.get(key).?;
    const receiver = self.receivers.get(key).?;
    // Section 10.1: an object is shared, so a class method changing it
    // changes it for everyone, and nothing about where it is called from
    // has to allow that.
    if (receiver.user.?.class) return false;
    // Section 11.1: a trait's requirement changes the value whenever a struct
    // that supplies it does, since through the trait either may be called.
    if (receiver.user.?.trait and declaration.abstract_span != null) {
        const setter = std.mem.endsWith(u8, key, Resolver.setter_suffix);
        const member = key[std.mem.lastIndexOf(u8, key, Resolver.method_separator).? + Resolver.method_separator.len ..];
        const name = if (setter) member[0 .. member.len - Resolver.setter_suffix.len] else member;
        var result = false;
        var types = self.structs.valueIterator();
        while (types.next()) |candidate| {
            const user = candidate.user.?;
            if (user.class or user.trait or !user.conformsTo(receiver.user.?)) continue;
            if (setter) {
                result = true;
                break;
            }
            const supplied = try self.memberKey(candidate.*, name) orelse continue;
            if (std.mem.eql(u8, supplied, key) or self.properties.contains(supplied)) continue;
            if (try self.methodChanges(supplied)) {
                result = true;
                break;
            }
        }
        if (result or self.changes_in_progress.count() == 1) try self.changes.put(self.arena, key, result);
        return result;
    }
    const result = try self.statementsChangeSelf(declaration.body.statements, receiver);
    // `true` is final whatever else is in progress. `false` is final only when
    // nothing else is, since it may have leaned on a cycle's provisional answer.
    if (result or self.changes_in_progress.count() == 1) try self.changes.put(self.arena, key, result);
    return result;
}

fn statementsChangeSelf(self: *Checker, statements: []const Ast.Statement, receiver: Type) Error!bool {
    for (statements) |statement| {
        if (try self.statementChangesSelf(statement, receiver)) return true;
    }
    return false;
}

fn statementChangesSelf(self: *Checker, statement: Ast.Statement, receiver: Type) Error!bool {
    return switch (statement.data) {
        .expression => |expression| self.expressionChangesSelf(expression, receiver),
        .declaration => |declaration| if (declaration.initializer) |initializer|
            self.expressionChangesSelf(initializer, receiver)
        else
            false,
        .assignment => |assignment| blk: {
            if (assignment.steps.len > 0 and std.mem.eql(u8, assignment.name, "self") and
                !stepsReachObject(assignment.steps, receiver)) break :blk true;
            for (assignment.steps) |step| switch (step) {
                .index => |index| if (try self.expressionChangesSelf(index, receiver)) break :blk true,
                .field => {},
            };
            break :blk self.expressionChangesSelf(assignment.value, receiver);
        },
        .conditional => |conditional| blk: {
            if (try self.expressionChangesSelf(conditional.condition, receiver)) break :blk true;
            if (try self.statementsChangeSelf(conditional.then_block.statements, receiver)) break :blk true;
            const otherwise = conditional.otherwise orelse break :blk false;
            break :blk switch (otherwise) {
                .block => |block| self.statementsChangeSelf(block.statements, receiver),
                .chained => |chained| self.statementChangesSelf(chained.*, receiver),
            };
        },
        .while_loop => |loop| try self.expressionChangesSelf(loop.condition, receiver) or
            try self.statementsChangeSelf(loop.body.statements, receiver),
        .for_loop => |loop| try self.expressionChangesSelf(loop.iterable, receiver) or
            try self.statementsChangeSelf(loop.body.statements, receiver),
        .return_statement => |return_statement| if (return_statement.value) |value|
            self.expressionChangesSelf(value, receiver)
        else
            false,
        .destructuring => |destructuring| self.expressionChangesSelf(destructuring.initializer, receiver),
        .destructuring_assignment => |assignment| self.expressionChangesSelf(assignment.value, receiver),
        .break_statement, .continue_statement, .function_declaration, .struct_declaration => false,
        .case_statement => |case| self.caseChangesSelf(case, receiver),
    };
}

fn caseChangesSelf(self: *Checker, case: *const Ast.Case, receiver: Type) Error!bool {
    if (case.subject) |subject| if (try self.expressionChangesSelf(subject, receiver)) return true;
    for (case.arms) |arm| {
        for (arm.alternatives) |alternative| {
            if (try self.expressionChangesSelf(alternative, receiver)) return true;
        }
        if (try self.caseBodyChangesSelf(arm.body, receiver)) return true;
    }
    const otherwise = case.otherwise orelse return false;
    return self.caseBodyChangesSelf(otherwise, receiver);
}

fn caseBodyChangesSelf(self: *Checker, body: Ast.Case.Body, receiver: Type) Error!bool {
    return switch (body) {
        .block => |block| self.statementsChangeSelf(block.statements, receiver),
        .value => |value| self.expressionChangesSelf(value, receiver),
    };
}

fn expressionChangesSelf(self: *Checker, expression: *const Ast.Expression, receiver: Type) Error!bool {
    return switch (expression.data) {
        .int_literal, .float_literal, .bool_literal, .nothing_literal, .name, .string_literal, .enum_value => false,
        .unary => |unary| self.expressionChangesSelf(unary.operand, receiver),
        .binary => |binary| try self.expressionChangesSelf(binary.left, receiver) or
            try self.expressionChangesSelf(binary.right, receiver),
        .logical => |logical| try self.expressionChangesSelf(logical.left, receiver) or
            try self.expressionChangesSelf(logical.right, receiver),
        .comparison => |comparison| blk: {
            for (comparison.operands) |operand| {
                if (try self.expressionChangesSelf(operand, receiver)) break :blk true;
            }
            break :blk false;
        },
        .call => |call| blk: {
            for (call.arguments) |argument| {
                if (try self.expressionChangesSelf(argument, receiver)) break :blk true;
            }
            if (try self.expressionChangesSelf(call.callee, receiver)) break :blk true;
            if (call.callee.data != .member) break :blk false;
            const member = call.callee.data.member;
            const reached = selfPathType(member.base, receiver) orelse break :blk false;
            break :blk switch (reached.kind) {
                .struct_value => if (self.receivers.contains(try Resolver.methodKey(self.arena, reached.user.?.name, member.name)))
                    try self.methodChanges(try Resolver.methodKey(self.arena, reached.user.?.name, member.name))
                else
                    false,
                .list => if (Type.list_methods.get(member.name)) |method| method.mutates else false,
                .dictionary, .set => Type.map_mutators.has(member.name),
                else => false,
            };
        },
        .range => |range| try self.expressionChangesSelf(range.start, receiver) or
            try self.expressionChangesSelf(range.end, receiver),
        .interpolation => |parts| blk: {
            for (parts) |part| switch (part) {
                .text => {},
                .expression => |inner| if (try self.expressionChangesSelf(inner, receiver)) break :blk true,
            };
            break :blk false;
        },
        .list_literal, .tuple_literal => |elements| blk: {
            for (elements) |element| {
                if (try self.expressionChangesSelf(element, receiver)) break :blk true;
            }
            break :blk false;
        },
        .dictionary_literal => |entries| blk: {
            for (entries) |entry| {
                if (try self.expressionChangesSelf(entry.key, receiver) or
                    try self.expressionChangesSelf(entry.value, receiver)) break :blk true;
            }
            break :blk false;
        },
        .index => |index| try self.expressionChangesSelf(index.base, receiver) or
            try self.expressionChangesSelf(index.index, receiver),
        .member => |member| self.expressionChangesSelf(member.base, receiver),
        .type_test => |test_| self.expressionChangesSelf(test_.value, receiver),
        // `self` cannot appear inside a block (see `Parser.self_allowed`).
        .lambda => false,
        .case_expression => |case| self.caseChangesSelf(case, receiver),
    };
}

/// Whether an assignment's steps from `self` pass through an object before the
/// last one, so what they change is shared rather than part of `self` (10.1).
fn stepsReachObject(steps: []const Ast.Step, receiver: Type) bool {
    var at = receiver;
    for (steps[0 .. steps.len - 1]) |step| {
        switch (step) {
            .field => |field| {
                if (at.kind != .struct_value or at.optional) return false;
                at = for (at.user.?.fields) |candidate| {
                    if (std.mem.eql(u8, candidate.name, field.name)) break candidate.type;
                } else return false;
            },
            .index => {
                if (at.optional or (at.kind != .list and at.kind != .dictionary)) return false;
                at = at.element.?.*;
            },
        }
        if (isClass(at)) return true;
    }
    return false;
}

/// The type reached by a path of fields and indices that starts at `self`, or
/// null when the expression is not such a path.
fn selfPathType(expression: *const Ast.Expression, receiver: Type) ?Type {
    switch (expression.data) {
        .name => |name| return if (std.mem.eql(u8, name, "self")) receiver else null,
        .member => |member| {
            if (member.position != null) return null;
            const base = selfPathType(member.base, receiver) orelse return null;
            // Past an object the path is in something shared, not in `self`
            // (10.1).
            if (base.kind != .struct_value or base.optional or base.user.?.class) return null;
            for (base.user.?.fields) |field| {
                if (std.mem.eql(u8, field.name, member.name)) return field.type;
            }
            return null;
        },
        .index => |index| {
            const base = selfPathType(index.base, receiver) orelse return null;
            if (base.optional) return null;
            if (base.kind == .list or base.kind == .dictionary) return base.element.?.*;
            return null;
        },
        else => return null,
    }
}

/// The getter key of a computed property of `owner` named `name`, if there is
/// one, with whether it can be set.
const PropertyInfo = struct { getter: []const u8, writable: bool };

fn propertyOf(self: *Checker, owner: Type, name: []const u8) Error!?PropertyInfo {
    const key = try self.memberKey(owner, name) orelse return null;
    const writable = self.properties.get(key) orelse return null;
    return .{ .getter = key, .writable = writable };
}

/// Section 10.2: a property runs code that may read any field, so inside a
/// constructor it waits for all of them, as a method call does. Returns
/// whether it reported.
fn requireReadyForMember(self: *Checker, base: *const Ast.Expression, name: []const u8, span: Source.Span, comptime verb: []const u8) Error!bool {
    if (self.constructing == null or base.data != .name or !std.mem.eql(u8, base.data.name, "self")) return false;
    const field = try self.firstUnsetField() orelse return false;
    if (try self.reportInDefault(span, "read a property of `self`")) return true;
    try self.reportWithHelp(
        span,
        "`{s}` cannot be " ++ verb ++ " until every field of `self` is set",
        .{name},
        "Set `self.{s}` first. A property may read any field, so it has to wait for all of them.",
        .{field},
    );
    return true;
}

/// `shape.area`, a computed property read. It runs the getter.
fn typeOfPropertyRead(self: *Checker, member: Ast.Expression.Member, property: PropertyInfo) Error!Type {
    if (try self.requireReadyForMember(member.base, member.name, member.name_span, "read")) return .invalid;
    const signature = try self.signatureFor(property.getter);
    if (!self.in_function) try self.checkCapturesOf(member.name_span, property.getter, member.name, "this");
    return signature.return_type;
}

/// `value.area()` on a struct.
fn typeOfStructMethodCall(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    base: Type,
) Error!Type {
    const key = try self.memberKey(base, member.name) orelse try Resolver.methodKey(self.arena, base.user.?.name, member.name);
    if (try self.memberOwner(base, member.name)) |owner| {
        if (try self.reportPrivate(owner, member.name, member.name_span)) {
            try self.typeArguments(call.arguments);
            return .invalid;
        }
    }
    if (!self.receivers.contains(key) or self.properties.contains(key)) {
        const is_field = self.properties.contains(key) or for (base.user.?.fields) |field| {
            if (std.mem.eql(u8, field.name, member.name)) break true;
        } else false;
        if (try self.reportTypeMemberThroughValue(base, member.name, member.name_span)) {
            // Reported.
        } else if (is_field) {
            try self.reportWithHelp(
                member.name_span,
                "`{s}` is a {s} of {f}, not a method",
                .{ member.name, if (self.properties.contains(key)) "property" else "field", base },
                "Read it without parentheses, as in `.{s}`.",
                .{member.name},
            );
        } else {
            try self.report(
                member.name_span,
                "{f} has no method named `{s}`",
                .{ base, member.name },
                try self.subclassMemberHelp(base, member, "Check the method name in the type's declaration."),
            );
        }
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    if (try self.reportAbstractThroughSuper(member, key)) {
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    try self.method_calls.put(self.arena, call.callee, key);

    const declared = try self.signatureFor(key);
    if (takesSelf(declared, base)) {
        try self.reportTakesSelf(member.name_span, member.name, base);
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    const signature = try self.signatureOn(declared, base);
    try self.checkArguments(call, member.name, try self.parametersOf(
        signature,
        (try self.declarationWithDefaults(key)).parameters,
        "Match the number of arguments to the method's parameters.",
    ));
    if (!isClass(base) and try self.methodChanges(key)) try self.requireMutableReceiver(member, member.name);
    if (!self.in_function) try self.checkCaptures(expression.span, key, member.name);
    return signature.return_type;
}

/// The same readiness rules, worded for a field default, which cannot set
/// anything and so can only be told what it may read. Returns whether it
/// reported, which it does only inside a default.
fn reportInDefault(self: *Checker, span: Source.Span, comptime what: []const u8) Error!bool {
    const building = self.constructing orelse return false;
    if (self.in_parameter_default) {
        try self.report(
            span,
            "a parameter default cannot " ++ what ++ " yet",
            .{},
            "It runs before the constructor's body, while the value is still being built, so it can read only fields that have defaults of their own, as in `self.width`.",
        );
        return true;
    }
    if (building.part != .default_of) return false;
    try self.report(
        span,
        "a field default cannot " ++ what,
        .{},
        "A default runs while the value is still being built, so it can read only the earlier fields it needs, as in `self.width`.",
    );
    return true;
}

fn hasDefault(declaration: Ast.StructDeclaration, name: []const u8) bool {
    for (declaration.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.default != null;
    }
    return false;
}

/// Section 10.2: "Before all fields are ready, `self` may not escape or be or be
/// passed elsewhere." Reading one field that is set is not escaping.
fn requireSelfReady(self: *Checker, span: Source.Span) Error!void {
    const field = try self.firstUnsetField() orelse return;
    if (try self.reportInDefault(span, "use `self` as a whole")) {
        // Nothing to do after: a default is one expression.
    } else try self.reportWithHelp(
        span,
        "`self` cannot be used as a whole until every field is set",
        .{},
        "Set `self.{s}` first. Until every field is set, only fields that are already set can be read.",
        .{field},
    );
    // Treated as set from here, so one early use is reported once rather than
    // at every later one, as an unassigned name is.
    for (self.constructing.?.type.user.?.fields) |each| {
        (try self.fieldSetBinding(each.name)).?.assigned = true;
    }
}

/// Merges the types of every `return` in a body being inferred. Section 4.4's
/// `Int`-to-`Float` widening applies, so `return 1` alongside `return 2.5`
/// infers `Float`. Kinds that cannot meet — including a bare `return`, which
/// arrives as `Nothing`, beside a valued one — make the answer ambiguous.
fn inferredReturnType(
    self: *Checker,
    types: []const Type,
    name: []const u8,
    span: Source.Span,
) Error!Type {
    if (types.len == 0) return .nothing;

    var result = types[0];
    for (types[1..]) |candidate| {
        if (candidate.assignableTo(result)) continue;
        if (result.assignableTo(candidate)) {
            result = candidate;
            continue;
        }
        try self.report(
            span,
            "the return type of `{s}` is ambiguous",
            .{name},
            "Add an explicit return type; this function returns more than one kind of value.",
        );
        return .invalid;
    }
    return result;
}

fn checkAllPathsReturn(self: *Checker, declaration: Ast.FunctionDeclaration, return_type: Type) Error!void {
    // Section 7.2: "Every reachable path in a value-producing function returns
    // a value." A function with no result has nothing to require, and one whose
    // type is already broken would only get a second report of the same
    // mistake.
    if (return_type.kind == .nothing or return_type.kind == .invalid) return;
    // A body that cannot fall off its end returns on every path, or loops
    // forever, and either way never produces a missing value.
    if (!self.blockCompletes(declaration.body.statements)) return;
    try self.report(
        declaration.name_span,
        "not every path in `{s}` returns a value",
        .{declaration.name},
        "Add a `return` on every path, or restructure so every branch returns.",
    );
}

/// Whether a function can reach itself through the calls it makes, directly or
/// through other functions. Section 7.2 treats both as recursion.
fn isRecursive(self: *Checker, name: []const u8) Error!bool {
    var visited: Resolver.NameSet = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try pending.append(self.arena, name);

    while (pending.pop()) |current| {
        const callees = self.facts.calls.get(current) orelse continue;
        var it = callees.keyIterator();
        while (it.next()) |callee| {
            // Reaching a type sets up its fields, but that is not a call
            // whose result a return type could depend on; a field that needs
            // its own type while it is inferred is reported where it is.
            if (std.mem.endsWith(u8, callee.*, Resolver.method_separator)) continue;
            if (std.mem.eql(u8, callee.*, name)) return true;
            if (visited.contains(callee.*)) continue;
            try visited.put(self.arena, callee.*, {});
            try pending.append(self.arena, callee.*);
        }
    }
    return false;
}

/// Every module variable a call to `name` can read: its own reads, and those
/// of every function reachable through its calls.
fn capturesOf(self: *Checker, name: []const u8) Error!Resolver.NameSet {
    if (self.captures.get(name)) |known| return known;

    var reads: Resolver.NameSet = .empty;
    var visited: Resolver.NameSet = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    try visited.put(self.arena, name, {});
    try pending.append(self.arena, name);

    while (pending.pop()) |current| {
        // Section 10.7: calling a class's method may run any subclass's
        // override of it instead.
        if (self.receivers.get(current)) |receiver| if (receiver.user.?.class) {
            const member = current[std.mem.lastIndexOf(u8, current, Resolver.method_separator).? + Resolver.method_separator.len ..];
            var types = self.structs.valueIterator();
            while (types.next()) |candidate| {
                if (candidate.user == receiver.user or !candidate.user.?.extends(receiver.user.?)) continue;
                const override = try Resolver.methodKey(self.arena, candidate.user.?.name, member);
                if (!self.receivers.contains(override) or visited.contains(override)) continue;
                try visited.put(self.arena, override, {});
                try pending.append(self.arena, override);
            }
        } else if (receiver.user.?.trait) {
            // Section 11.2: calling a trait's member may run whatever a type
            // adopting the trait supplies for it.
            const member = current[std.mem.lastIndexOf(u8, current, Resolver.method_separator).? + Resolver.method_separator.len ..];
            if (!std.mem.endsWith(u8, member, Resolver.setter_suffix)) {
                var types = self.structs.valueIterator();
                while (types.next()) |candidate| {
                    if (candidate.user.?.trait or !candidate.user.?.conformsTo(receiver.user.?)) continue;
                    const supplied = try self.memberKey(candidate.*, member) orelse continue;
                    if (visited.contains(supplied)) continue;
                    try visited.put(self.arena, supplied, {});
                    try pending.append(self.arena, supplied);
                }
            }
        };
        if (self.facts.module_reads.get(current)) |own| {
            var it = own.keyIterator();
            while (it.next()) |read| try reads.put(self.arena, read.*, {});
        }
        if (self.facts.calls.get(current)) |callees| {
            var it = callees.keyIterator();
            while (it.next()) |callee| {
                if (visited.contains(callee.*)) continue;
                try visited.put(self.arena, callee.*, {});
                try pending.append(self.arena, callee.*);
            }
        }
    }

    try self.captures.put(self.arena, name, reads);
    return reads;
}

/// Section 7.1: "Hoisting never permits reading an uninitialized captured
/// variable." Checked where top-level code makes a call, against the module
/// scope as it stands there. Calls made inside a function are covered by the
/// top-level call that led to them, since a caller's captures include its
/// callees'.
fn checkCaptures(
    self: *Checker,
    call_span: Source.Span,
    callee: []const u8,
    display: []const u8,
) Error!void {
    return self.checkCapturesOf(call_span, callee, display, "this call");
}

/// `checkCaptures`, for something other than a call that runs code: reaching
/// a type-level field, which can set up its type (10.4).
fn checkCapturesOf(
    self: *Checker,
    call_span: Source.Span,
    callee: []const u8,
    display: []const u8,
    comptime what: []const u8,
) Error!void {
    const reads = try self.capturesOf(callee);

    // Report the first unassigned name in alphabetical order, so the output
    // does not depend on hash order.
    var first: ?[]const u8 = null;
    var it = reads.keyIterator();
    while (it.next()) |read| {
        if (self.module.get(read.*)) |binding| {
            if (binding.assigned) continue;
        }
        if (first == null or std.mem.order(u8, read.*, first.?) == .lt) first = read.*;
    }

    const name = first orelse return;
    try self.reportWithHelp(
        call_span,
        "`{s}` reads `{s}`, which is not assigned yet here",
        .{ display, name },
        "Move " ++ what ++ " below the line that assigns `{s}`.",
        .{name},
    );
}

// Supporting checks.

fn requireCondition(self: *Checker, expression: *const Ast.Expression) Error!void {
    const actual = try self.typeOf(expression);
    if (actual.kind == .invalid or actual.kind == .bool) return;
    try self.report(
        expression.span,
        "a condition must be a Bool, but this is {f}",
        .{actual},
        "Compare it to something, as in `count > 0`. Emerald has no truthy or falsey values.",
    );
}

/// The canonical diagnostic of section 17.1, reproduced exactly, including the
/// name in its correction.
fn reportUnassigned(self: *Checker, span: Source.Span, name: []const u8, binding: Binding) Error!void {
    if (binding.assigned_in_loop) {
        return self.reportWithHelp(
            span,
            "`{s}` may not have been assigned",
            .{name},
            "The loop that assigns `{s}` might not run at all. Give it a value before the loop.",
            .{name},
        );
    }
    try self.reportWithHelp(
        span,
        "`{s}` may not have been assigned",
        .{name},
        "Assign `{s}` on every branch before reading it.",
        .{name},
    );
}

fn resolveTypeExpression(self: *Checker, annotation: Ast.TypeExpression) Error!Type {
    const written = try self.resolveWrittenType(annotation);
    const question = annotation.question_span orelse return written;

    // Section 4.2's `Nothing` is absence itself, so marking it possibly-absent
    // says nothing at all.
    if (written.kind == .nothing) {
        try self.report(
            question,
            "`Nothing?` is not a type",
            .{},
            "`Nothing` already means there is no value. Write the type of what may be there, as in `Int?`.",
        );
        return .invalid;
    }
    return written.optionalOf();
}

fn resolveWrittenType(self: *Checker, annotation: Ast.TypeExpression) Error!Type {
    // A dictionary and a set both fill in `element`, so they are asked about
    // before a bare `[T]` is.
    if (annotation.key) |written_key| {
        const key = try self.resolveTypeExpression(written_key.*);
        const value = try self.resolveTypeExpression(annotation.element.?.*);
        if (!self.resolving_struct_fields) try self.requireEligibleKey(key, written_key.span);
        return Type.dictionaryOf(self.arena, key, value);
    }

    if (annotation.set) {
        const member = try self.resolveTypeExpression(annotation.element.?.*);
        try self.requireEligibleMember(member, annotation.span);
        return Type.setOf(self.arena, member);
    }

    if (annotation.element) |element| {
        const inner = try self.resolveTypeExpression(element.*);
        return Type.listOf(self.arena, inner);
    }

    if (annotation.positions) |written| {
        const positions = try self.arena.alloc(Type, written.len);
        for (written, positions) |position, *resolved| {
            resolved.* = try self.resolveTypeExpression(position);
        }
        return Type.tupleOf(self.arena, positions);
    }

    if (annotation.signature) |written| {
        const parameters = try self.arena.alloc(Type, written.parameters.len);
        for (written.parameters, parameters) |parameter, *resolved| {
            resolved.* = try self.resolveTypeExpression(parameter);
        }
        // Section 7.1: an omitted result is `Nothing`.
        const result: Type = if (written.result) |written_result|
            try self.resolveTypeExpression(written_result.*)
        else
            .nothing;
        return Type.functionOf(self.arena, .{ .parameters = parameters, .return_type = result });
    }

    if (Type.fromName(annotation.name)) |builtin| return builtin;
    if (std.mem.eql(u8, annotation.name, "Self")) {
        if (self.written_self) |meaning| return meaning;
        try self.report(
            annotation.span,
            "`Self` can only be written in a method's parameter and result types",
            .{},
            "`Self` stands for the type a method belongs to, so it has a meaning only there. Write the type's name instead.",
        );
        return .invalid;
    }
    if (self.structs.get(try self.typeKeyOf(annotation.name))) |user_type| return user_type;
    try self.report(
        annotation.span,
        "`{s}` is not a type",
        .{annotation.name},
        "Check the spelling or declare the struct in this project.",
    );
    return .invalid;
}

/// Section 4.5's narrowing: records what a condition proves about a name that
/// may be absent, for as long as the proof holds.
///
/// Only a comparison against `nothing` proves anything, and only about a plain
/// name. `not` flips which way the proof runs; `and` proves both of its sides
/// when it holds, and `or` proves both when it fails, which is what makes
/// `if a == nothing or b == nothing { return }` narrow both afterwards.
fn narrow(self: *Checker, condition: *const Ast.Expression, when_true: bool) void {
    switch (condition.data) {
        .unary => |unary| if (unary.operator == .not) self.narrow(unary.operand, !when_true),
        .logical => |logical| {
            if ((logical.operator == .conjunction) != when_true) return;
            self.narrow(logical.left, when_true);
            self.narrow(logical.right, when_true);
        },
        .comparison => |comparison| {
            if (comparison.operators.len != 1) return;
            const operator = comparison.operators[0];
            if (!operator.isEquality()) return;
            // `x != nothing` holding, or `x == nothing` failing, proves it is
            // there. The other two prove it is absent, which narrows nothing:
            // the type is already as specific as `Nothing`.
            if ((operator == .not_equal) != when_true) return;
            self.narrowName(presenceTest(comparison) orelse return);
        },
        // Section 4.4: a type test that holds proves the name has that type.
        // One that fails proves nothing a type can say.
        .type_test => |test_| {
            if (!when_true or test_.value.data != .name) return;
            const tested = self.type_tests.get(condition) orelse return;
            const name = test_.value.data.name;
            const binding = self.find(name) orelse return;
            if (binding.is_function or !narrowsTo(tested.target, binding.type)) return;
            if (self.unprovable(name) != null) return;
            binding.type = tested.target;
        },
        else => {},
    }
}

/// Whether knowing a value has type `target` says more than `current` does:
/// the same type without the `?`, or a class that extends the one it has.
fn narrowsTo(target: Type, current: Type) bool {
    if (target.optional or target.kind == .invalid or current.kind == .invalid) return false;
    const present = current.payload();
    if (target.same(present)) return current.optional;
    if (target.kind != .struct_value or present.kind != .struct_value) return false;
    if (target.user.? == present.user.?) return false;
    // A trait says more about a value that does not already conform to it.
    if (target.user.?.trait) return !present.user.?.conformsTo(target.user.?);
    return (target.user.?.class or present.user.?.trait) and target.user.?.conformsTo(present.user.?);
}

/// Section 4.4's `value is Type`. It is always a `Bool`, even when the answer
/// is already known; the warning 4.4 gives such a test waits for diagnostics
/// with a severity.
fn typeOfTypeTest(self: *Checker, expression: *const Ast.Expression) Error!Type {
    const test_ = &expression.data.type_test;
    const value = try self.typeOf(test_.value);
    const target = try self.resolveTypeExpression(test_.target);
    try self.type_tests.put(self.arena, expression, .{ .value = value, .target = target });
    return .bool;
}

/// The name in `name == nothing`, written either way round.
fn presenceTest(comparison: Ast.Expression.Comparison) ?[]const u8 {
    const left = comparison.operands[0];
    const right = comparison.operands[1];
    if (right.data == .nothing_literal and left.data == .name) return left.data.name;
    if (left.data == .nothing_literal and right.data == .name) return right.data.name;
    return null;
}

/// Why section 4.5 will not narrow a name, or null when it will: a block
/// assigns it, or it is a module variable a function assigns, since calling
/// either between the test and the use could set it back to `nothing`. Keyed by
/// name, so a local sharing the name is refused too, which errs on the side of
/// not narrowing.
fn unprovable(self: *Checker, name: []const u8) ?[]const u8 {
    const binding = self.find(name) orelse return null;
    if (binding.mutability != .variable) return null;
    if (self.facts.assigned_in_lambda.contains(name)) return "a block or a nested function";
    if (self.facts.assigned_in_function.contains(self.keyOf(name))) return "a function";
    return null;
}

fn narrowName(self: *Checker, name: []const u8) void {
    const binding = self.find(name) orelse return;
    if (binding.is_function or !binding.type.optional) return;
    // Section 4.5: a `const` and a read-only parameter keep the proof because
    // they cannot be rebound. A `var` a block assigns to can change between the
    // test and the use, since calling the block is all it takes.
    if (self.unprovable(name) != null) return;
    binding.type = binding.type.payload();
}

// Definite-assignment state.

/// The assignment state of every binding currently in scope, innermost last.
/// What one binding knew at a point in the program: whether it was assigned
/// (4.1) and what narrowing had proved about its type (4.5). Both are facts
/// that a branch can establish and that rejoining control flow can undo.
const State = struct {
    assigned: bool,
    type: Type,
};

const Snapshot = [][]State;

fn snapshot(self: *Checker) Error!Snapshot {
    return self.snapshotOf(self.scopes.items.len);
}

/// The state of only the outermost `depth` scopes, which is what a `break`
/// carries out of a loop.
fn snapshotOf(self: *Checker, depth: usize) Error!Snapshot {
    const result = try self.arena.alloc([]State, depth);
    for (self.scopes.items[0..depth], result) |scope, *states| {
        states.* = try self.arena.alloc(State, scope.count());
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            states.*[index] = .{ .assigned = binding.assigned, .type = binding.type };
        }
    }
    return result;
}

fn restore(self: *Checker, state: Snapshot) void {
    for (self.scopes.items, state) |scope, states| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            binding.assigned = states[index].assigned;
            binding.type = states[index].type;
        }
    }
}

/// `restore`, noting which names only the loop assigned.
fn restoreAfterLoop(self: *Checker, before: Snapshot) void {
    for (self.scopes.items, before) |scope, states| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            if (binding.assigned and !states[index].assigned) binding.assigned_in_loop = true;
            binding.assigned = states[index].assigned;
            binding.type = states[index].type;
        }
    }
}

/// Merges two paths that rejoin: a name is assigned only if both assigned it,
/// and narrowing survives only if both proved the same thing.
fn intersect(self: *Checker, other: Snapshot) void {
    for (self.scopes.items, other) |scope, states| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            binding.assigned = binding.assigned and states[index].assigned;
            if (!binding.type.same(states[index].type)) binding.type = binding.declared;
        }
    }
}

/// Puts back what narrowing had proved at `state`, keeping what has been
/// assigned since, which only a condition's right side can have added.
fn restoreTypes(self: *Checker, state: Snapshot) void {
    for (self.scopes.items[0..@min(self.scopes.items.len, state.len)], state) |scope, states| {
        var index: usize = 0;
        var entries = scope.valueIterator();
        while (entries.next()) |binding| : (index += 1) {
            if (index < states.len) binding.type = states[index].type;
        }
    }
}

fn markAllAssigned(self: *Checker) void {
    for (self.scopes.items) |scope| {
        var values = scope.valueIterator();
        while (values.next()) |binding| binding.assigned = true;
    }
}

// Expressions.

fn typeOf(self: *Checker, expression: *const Ast.Expression) Error!Type {
    return switch (expression.data) {
        .int_literal => .int,
        .float_literal => .float,
        .bool_literal => .bool,
        .nothing_literal => .nothing,
        .case_expression => self.typeOfCase(expression, null),
        .enum_value => |value| self.structs.get(self.keyOf(value.type_name)) orelse .invalid,

        .name => |name| blk: {
            if (std.mem.eql(u8, name, "super")) break :blk try self.typeOfSuper(expression.span);
            // Missing only when the resolver already reported the name, or
            // while inferring early for a call that `checkCaptures` rejects.
            const binding = self.find(name) orelse break :blk .invalid;
            // Section 3.4 and 7.5: a bare function name is its callable value.
            if (binding.is_type) {
                try self.report(
                    expression.span,
                    "`{s}` is a type, not a value",
                    .{name},
                    "Construct a value by calling the type with parentheses.",
                );
                break :blk .invalid;
            }
            if (binding.is_function) {
                try self.checkNestedUse(expression);
                break :blk try self.typeOfFunctionValue(expression, .{ .key = binding.function_key orelse self.keyOf(name), .display = name });
            }
            if (self.constructing != null and std.mem.eql(u8, name, "self")) {
                try self.requireSelfReady(expression.span);
                break :blk binding.type;
            }
            if (!binding.assigned) {
                try self.reportUnassigned(expression.span, name, binding.*);
                // Treated as assigned from here so one unassigned read does not
                // report again at every later use.
                binding.assigned = true;
            }
            break :blk binding.type;
        },

        .unary => |unary| self.typeOfUnary(expression, unary),
        .binary => |binary| self.typeOfBinary(expression, binary),
        .logical => |logical| self.typeOfLogical(logical),
        .comparison => |comparison| self.typeOfComparison(comparison),
        .call => |call| self.typeOfCall(expression, call),
        .list_literal => self.typeOfList(expression, null),
        .string_literal => .string,
        // Section 5.1: any value can be interpolated, displayed as `print`
        // would display it.
        .interpolation => |parts| blk: {
            for (parts) |part| switch (part) {
                .text => {},
                .expression => |part_expression| _ = try self.typeOf(part_expression),
            };
            break :blk .string;
        },
        .index => |index| self.typeOfIndex(index),
        // A namespace-qualified name is a reference, not a property access:
        // `Shapes.area` names one declaration, as the resolver worked out.
        .member => |member| if (try self.referenceOf(expression)) |reference|
            self.typeOfQualified(expression, reference)
        else
            self.typeOfMember(expression, member),
        .range => self.rejectCountingValue(expression),
        .lambda => self.typeOfLambda(expression, null),
        .tuple_literal => self.typeOfTuple(expression, null),
        .dictionary_literal => self.typeOfDictionary(expression, null),
        .type_test => self.typeOfTypeTest(expression),
    };
}

/// Section 7.5's captured function. Section 15.2's prelude functions are the
/// exception: `print` and `write` take any number of arguments of any type, and
/// no type that can be written describes that, so they can only be called.
fn typeOfFunctionValue(self: *Checker, expression: *const Ast.Expression, reference: Reference) Error!Type {
    if (!self.declarations.contains(reference.key)) {
        try self.reportWithHelp(
            expression.span,
            "`{s}` is built in, and built-in functions cannot be used as values",
            .{reference.display},
            "Call it with parentheses, as in `{s}(...)`, or wrap it in a lambda such as `{{ value => {s}(value) }}`.",
            .{ reference.display, reference.display },
        );
        return .invalid;
    }
    const signature = try self.signatureFor(reference.key);
    return Type.functionOf(self.arena, .{
        .parameters = signature.parameters,
        .parameter_names = signature.parameter_names,
        .return_type = signature.return_type,
    });
}

/// `typeOf`, for a place where a value of `expected` is wanted. A list literal
/// takes its element type from context — `[]` gets one at all, and `[1, 2]`
/// becomes a `[Float]` where one is expected — and a lambda takes its parameter
/// types the same way, which is what lets `numbers.each { n => ... }` leave
/// `n` unannotated (7.2).
fn typeOfExpected(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    if (expression.data == .list_literal) return self.typeOfList(expression, expected);
    if (expression.data == .lambda) return self.typeOfLambda(expression, expected);
    if (expression.data == .tuple_literal) return self.typeOfTuple(expression, expected);
    if (expression.data == .dictionary_literal) return self.typeOfDictionary(expression, expected);
    if (expression.data == .case_expression) return self.typeOfCase(expression, expected);
    return self.typeOf(expression);
}

/// Section 8.2's `["Ava": 12]`. Keys and values infer their types the way a
/// list's elements do, and an expected dictionary type passes both down so that
/// whole numbers written where `Float` values belong are built as `Float`s.
fn typeOfDictionary(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    const entries = expression.data.dictionary_literal;
    const wanted: ?Type = if (expected) |want| (if (want.kind == .dictionary) want else null) else null;

    const key_types = try self.arena.alloc(Type, entries.len);
    const value_types = try self.arena.alloc(Type, entries.len);
    for (entries, key_types, value_types) |entry, *key_type, *value_type| {
        key_type.* = try self.typeOfExpected(entry.key, if (wanted) |want| want.key.?.* else null);
        value_type.* = try self.typeOfExpected(entry.value, if (wanted) |want| want.element.?.* else null);
    }

    const key = if (wanted) |want| want.key.?.* else unifiedType(key_types);
    const value = if (wanted) |want| want.element.?.* else unifiedType(value_types);

    for (entries, key_types, value_types) |entry, key_type, value_type| {
        if (!key_type.assignableTo(key)) try self.report(
            entry.key.span,
            "this is {f}, but the dictionary's keys are {f}",
            .{ key_type, key },
            "A dictionary holds one type of key.",
        );
        if (!value_type.assignableTo(value)) try self.report(
            entry.value.span,
            "this is {f}, but the dictionary's values are {f}",
            .{ value_type, value },
            "A dictionary holds one type of value.",
        );
    }

    try self.requireEligibleKey(key, expression.span);

    const built = try Type.dictionaryOf(self.arena, key, value);
    try self.literal_types.put(self.arena, expression, built);
    return built;
}

/// The one type a literal's keys or values share, widening `Int` to `Float`
/// when both appear, as a list literal's elements do (4.4). A type that fits
/// none of the others is returned as-is, and the caller reports each entry that
/// does not fit it.
fn unifiedType(types: []const Type) Type {
    if (types.len == 0) return .invalid;
    var unified = types[0];
    for (types) |candidate| {
        if (candidate.isInvalid()) return .invalid;
        if (candidate.assignableTo(unified)) continue;
        if (unified.assignableTo(candidate)) unified = candidate;
    }
    return unified;
}

/// Section 8.3: a dictionary key needs stable equality and hashing.
fn requireEligibleKey(self: *Checker, key: Type, span: Source.Span) Error!void {
    if (key.eligibleKey()) return;
    try self.report(
        span,
        "{f} cannot be a dictionary key",
        .{key},
        "A key must be a number, a `Bool`, a `String`, or a tuple or struct made only from valid key types. Lists, other mutable collections, and class objects cannot be keys.",
    );
}

/// Section 8.2's `("score", 10)`. Each position takes its own type, and an
/// expected tuple type passes down position by position so that a whole number
/// written where a `Float` is expected is built as one (4.4).
fn typeOfTuple(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    const positions = expression.data.tuple_literal;
    const expected_positions: ?[]const Type = if (expected) |tuple|
        (if (tuple.kind == .tuple and tuple.elements.len == positions.len) tuple.elements else null)
    else
        null;

    const types = try self.arena.alloc(Type, positions.len);
    for (positions, types, 0..) |position, *position_type, index| {
        const want: ?Type = if (expected_positions) |wanted| wanted[index] else null;
        position_type.* = try self.typeOfExpected(position, want);

        // The position takes the expected type when it fits, so a whole number
        // written where a `Float` belongs is stored as one (4.4). Keeping the
        // written type when it does not fit leaves the mismatch to report it.
        if (want) |wanted| {
            if (position_type.assignableTo(wanted)) position_type.* = wanted;
        }
    }

    const built = try Type.tupleOf(self.arena, types);
    // Recorded for the interpreter, which needs the position kinds to store a
    // whole number as a `Float` where one was expected, as it does for a list.
    try self.literal_types.put(self.arena, expression, built);
    return built;
}

/// Section 8.2's set literal: bracketed elements in a place whose type is a
/// set. Without an expected set type a bracketed list is a list, so this is
/// only ever reached with one in hand.
fn typeOfSet(self: *Checker, expression: *const Ast.Expression, want: Type) Error!Type {
    const elements = expression.data.list_literal;
    const member = want.element.?.*;

    for (elements) |element| {
        const actual = try self.typeOfExpected(element, member);
        if (!actual.assignableTo(member)) try self.report(
            element.span,
            "this is {f}, but the set holds {f}",
            .{ actual, member },
            "A set holds one type of value.",
        );
    }

    try self.requireEligibleMember(member, expression.span);
    try self.literal_types.put(self.arena, expression, want);
    return want;
}

/// A set member is stored and found the same way a dictionary key is, so it
/// answers to the same rule (8.3).
fn requireEligibleMember(self: *Checker, member: Type, span: Source.Span) Error!void {
    if (member.eligibleKey()) return;
    try self.report(
        span,
        "a set cannot hold {f}",
        .{member},
        "A set holds whole or decimal numbers, `Bool`s, `String`s, or tuples of those. Anything that can change after it is stored could not be found again.",
    );
}

/// Section 8.2. Nonempty literals infer their element type, widening `Int` to
/// `Float` when both appear (4.4); an empty one needs the type from context.
fn typeOfList(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    const elements = expression.data.list_literal;

    // Section 8.2: bracketed elements are a set where a set is expected, and an
    // empty `[]` is whichever of the three the context asks for. Only a literal
    // takes its kind this way; a list already in a binding stays a list.
    if (expected) |want| {
        if (want.kind == .set) return self.typeOfSet(expression, want);
        if (want.kind == .dictionary) {
            if (elements.len == 0) {
                try self.literal_types.put(self.arena, expression, want);
                return want;
            }
            try self.report(
                expression.span,
                "this is a list, but {f} was expected",
                .{want},
                "A dictionary is written with `key: value` entries, as in `[\"Ava\": 12]`.",
            );
            return .invalid;
        }
    }

    const expected_element: ?Type = if (expected) |list|
        (if (list.kind == .list) list.element.?.* else null)
    else
        null;

    if (elements.len == 0) {
        const element = expected_element orelse {
            try self.report(
                expression.span,
                "an empty list needs a type",
                .{},
                "Say what it will hold, as in `var names: [Int] = []`, `var ages: [String: Int] = []`, or `var seen: {String} = []`.",
            );
            return .invalid;
        };
        return self.recordLiteral(expression, element);
    }

    const types = try self.arena.alloc(Type, elements.len);
    for (elements, types) |element, *element_type| {
        element_type.* = try self.typeOfExpected(element, expected_element);
    }

    // The element type: the one expected, or the one the elements agree on.
    var target = expected_element orelse types[0];
    if (expected_element == null) {
        for (types[1..]) |candidate| {
            if (candidate.assignableTo(target)) continue;
            if (target.assignableTo(candidate)) target = candidate;
        }
    }

    for (elements, types) |element, element_type| {
        if (element_type.assignableTo(target)) continue;
        // Section 4.5: a literal holding `nothing` needs the element type from
        // context, because `[String]?` and `[String?]` are different types and
        // the literal alone does not say which was meant.
        if (element_type.kind == .nothing or target.kind == .nothing) {
            const present = if (target.kind == .nothing) element_type else target;
            try self.reportWithHelp(
                expression.span,
                "this list mixes `nothing` with {f}, so its type has to be written",
                .{present},
                "Say what it holds, as in `var each: [{f}?] = [...]`.",
                .{present},
            );
            return self.recordLiteral(expression, .invalid);
        }
        try self.report(
            element.span,
            "this is {f}, but the list holds {f}",
            .{ element_type, target },
            "A list holds one type of value.",
        );
    }
    return self.recordLiteral(expression, target);
}

/// Records the type a list literal was built with, so the interpreter can store
/// its elements at that type: `[1, 2]` where a `[Float]` is expected holds
/// `1.0` and `2.0` (4.4).
fn recordLiteral(self: *Checker, expression: *const Ast.Expression, element: Type) Error!Type {
    const list = try Type.listOf(self.arena, element);
    try self.literal_types.put(self.arena, expression, list);
    return list;
}

/// Section 7.4's lambda.
///
/// Parameter types come from their annotations, or from the callable type
/// expected here. Nothing else can supply them: section 7.4 requires a
/// standalone lambda to annotate its parameters rather than have them inferred
/// from the body's use of them, which would make the diagnostic for a mistake
/// appear far from the mistake.
///
/// The body is checked in place, with every enclosing scope still visible.
/// That visibility is capture, and checking it here rather than against a fresh
/// view is what makes a captured name's type the type it has where the lambda
/// is written.
fn typeOfLambda(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    const lambda = expression.data.lambda;

    var wanted: ?*const Signature = if (expected) |context|
        (if (context.kind == .function) context.signature else null)
    else
        null;
    // A lambda of the wrong shape has been reported here, so its type is left
    // undetermined rather than reported again where it is being stored. An
    // expected type that is already invalid means the surrounding call was
    // reported, which has the same effect: nothing here is worth a second
    // diagnostic.
    var mismatched = if (expected) |context| context.kind == .invalid else false;
    if (wanted) |signature| {
        if (signature.parameters.len != lambda.parameters.len) {
            try self.report(
                expression.span,
                "this lambda takes {d} value{s}, but it will be given {d}",
                .{
                    lambda.parameters.len,
                    if (lambda.parameters.len == 1) "" else "s",
                    signature.parameters.len,
                },
                "Match the number of parameters to the number of values passed to it.",
            );
            wanted = null;
            mismatched = true;
        }
    }

    const parameter_types = try self.arena.alloc(Type, lambda.parameters.len);
    const parameter_names = try self.arena.alloc([]const u8, lambda.parameters.len);
    for (lambda.parameters, parameter_types, parameter_names, 0..) |parameter, *resolved, *written, index| {
        written.* = parameter.name;
        resolved.* = if (parameter.annotation) |annotation|
            try self.resolveTypeExpression(annotation)
        else if (wanted) |signature|
            signature.parameters[index]
        else if (mismatched)
            // The shape is already reported; which parameter lost its type is
            // a consequence of that, not a second mistake.
            .invalid
        else blk: {
            if (parameter.pattern != null) {
                // A tuple being unpacked has nowhere to write its type.
                try self.report(
                    parameter.name_span,
                    "this lambda cannot tell what tuple it unpacks",
                    .{},
                    "Give it a type where it is stored, as in `const pick: func((Int, Int)): Int = { (a, b) => a }`, or pass it straight to a method such as `map`.",
                );
                break :blk .invalid;
            }
            try self.report(
                parameter.name_span,
                "`{s}` needs a type",
                .{parameter.name},
                "A lambda written on its own says what it receives, as in `{ value: Int => value * 2 }`.",
            );
            break :blk .invalid;
        };
    }

    // An expected result of `invalid` means the caller has no opinion, which is
    // how `map` asks for a block without saying what it must produce.
    const wanted_result: ?Type = if (wanted) |signature|
        (if (signature.return_type.kind == .invalid) null else signature.return_type)
    else
        null;

    const result = try self.checkLambdaBody(expression, lambda, parameter_types, parameter_names, wanted_result);

    const lambda_type = try Type.functionOf(self.arena, .{
        .parameters = parameter_types,
        .parameter_names = parameter_names,
        .return_type = result,
    });
    // The interpreter reads this to widen arguments and results the way section
    // 4.4 allows, exactly as it does for a named function's signature.
    try self.literal_types.put(self.arena, expression, lambda_type);
    return if (mismatched) .invalid else lambda_type;
}

/// The body of a lambda, with its parameters in scope.
///
/// `return` inside a lambda belongs to the lambda (6.5), and `break` and
/// `continue` cannot reach an enclosing loop from inside one (7.4), so both are
/// saved and restarted here the way a function body restarts them.
fn checkLambdaBody(
    self: *Checker,
    expression: *const Ast.Expression,
    lambda: Ast.Expression.Lambda,
    parameter_types: []const Type,
    parameter_names: []const []const u8,
    wanted_result: ?Type,
) Error!Type {
    const before = try self.snapshot();

    try self.pushScope();
    const parameters = self.scopes.items[self.scopes.items.len - 1];
    for (parameter_names, parameter_types, 0..) |name, parameter_type, index| {
        // Section 8.6's `{ (name, age) => ... }`: one parameter, unpacked.
        if (index < lambda.parameters.len) {
            if (lambda.parameters[index].pattern) |pattern| {
                try self.bindPattern(pattern, parameter_type, pattern.span, .parameter);
                continue;
            }
        }
        // Section 7.4: `_` binds nothing, and may appear more than once.
        if (std.mem.eql(u8, name, "_")) continue;
        try parameters.put(self.arena, name, .{
            .type = parameter_type,
            .declared = parameter_type,
            .assigned = true,
            .mutability = .parameter,
        });
    }

    const outer_return_type = self.current_return_type;
    const outer_in_function = self.in_function;
    const outer_loops = self.loops;
    const outer_pending = self.pending_return_types;
    defer {
        _ = self.scopes.pop();
        self.current_return_type = outer_return_type;
        self.in_function = outer_in_function;
        self.loops = outer_loops;
        self.pending_return_types = outer_pending;
        // A lambda may never run, and may run long after this point, so what it
        // assigns to a captured variable cannot make that variable assigned
        // here.
        self.restore(before);
    }
    self.loops = .empty;
    self.pending_return_types = .empty;
    self.in_function = true;
    self.current_return_type = wanted_result;

    switch (lambda.body) {
        .expression => |body| {
            const produced = try self.typeOfExpected(body, wanted_result);
            if (wanted_result) |result| {
                if (!produced.assignableTo(result)) {
                    try self.report(
                        body.span,
                        "this lambda produces {f}, but {f} is expected here",
                        .{ produced, result },
                        mismatchHelp(produced, result, "Produce a value of the expected type, or convert it first."),
                    );
                }
                return result;
            }
            return produced;
        },
        .block => |body| {
            try self.checkStatements(body.statements);
            if (wanted_result) |result| {
                if (result.kind != .nothing and self.blockCompletes(body.statements)) {
                    try self.report(
                        expression.span,
                        "not every path in this lambda returns a value",
                        .{},
                        "Add a `return` on every path, or restructure so every branch returns.",
                    );
                }
                return result;
            }
            return self.inferredReturnType(
                self.pending_return_types.items,
                "this lambda",
                expression.span,
            );
        },
    }
}

fn typeOfIndex(self: *Checker, index: Ast.Expression.Index) Error!Type {
    const base = try self.typeOf(index.base);

    // Section 8.3: a dictionary is indexed by its key, and the lookup can miss,
    // so it produces an optional. The non-nesting rule of 4.5 means a
    // dictionary of optionals reads the same whether the entry is missing or
    // holds `nothing`; `contains_key?` is what tells those apart.
    if (base.kind == .dictionary) {
        try self.requireKey(index.index, base.key.?.*);
        return base.element.?.optionalOf();
    }

    try self.requireIndex(index.index);
    if (base.kind == .invalid) return .invalid;
    if (!try self.requirePresent(base, index.base, null)) return .invalid;
    // Section 9.1: a string's index counts characters, and each is a String.
    if (base.kind == .string) return .string;
    if (base.kind == .set) {
        try self.report(
            index.base.span,
            "a set has no keys to look up",
            .{},
            "A set only records what is in it. Ask with `contains?(value)`.",
        );
        return .invalid;
    }
    if (base.kind != .list) {
        try self.report(
            index.base.span,
            "{f} cannot be indexed",
            .{base},
            "Only a list or a String has elements to index.",
        );
        return .invalid;
    }
    return base.element.?.*;
}

/// The key a dictionary is indexed by, which must be its key type rather than
/// a position.
fn requireKey(self: *Checker, index: *const Ast.Expression, key: Type) Error!void {
    const actual = try self.typeOfExpected(index, key);
    if (actual.assignableTo(key)) return;
    try self.report(
        index.span,
        "this is {f}, but the dictionary's keys are {f}",
        .{ actual, key },
        "Look it up with a key of the dictionary's own type.",
    );
}

fn requireIndex(self: *Checker, index: *const Ast.Expression) Error!void {
    const actual = try self.typeOf(index);
    if (actual.kind == .int or actual.kind == .invalid) return;
    try self.report(
        index.span,
        "an index must be an Int, but this is {f}",
        .{actual},
        "Indices count whole positions, starting from 0.",
    );
}

/// Section 14.2's `Shapes.area` used as a value rather than called. It is the
/// name branch of `typeOf`, reached through a member expression.
fn typeOfQualified(self: *Checker, expression: *const Ast.Expression, reference: Reference) Error!Type {
    if (try self.reportPrivateTypeMember(reference.key, expression.span)) return .invalid;
    if (self.type_fields.get(reference.key)) |field| {
        try self.settleTypeField(reference.key);
        // Section 7.1, for section 10.4's setup: reading the field may be
        // what sets up the type, and that reads whatever its fields' values do.
        if (!self.in_function) {
            try self.checkCapturesOf(expression.span, try Resolver.typeSetupKey(self.arena, field.type_key), reference.display, "this");
        }
        return self.module.get(reference.key).?.declared;
    }
    const binding = self.findKey(reference.key) orelse return .invalid;
    if (binding.is_type) {
        try self.report(
            expression.span,
            "`{s}` is a type, not a value",
            .{reference.display},
            "Construct a value by calling the type with parentheses.",
        );
        return .invalid;
    }
    if (binding.is_function) {
        // Taking a type-level function as a value still reaches the member and
        // sets up its type, even though the function body does not run yet.
        if (!self.in_function) {
            if (self.facts.type_members.get(reference.key)) |type_key| {
                try self.checkCapturesOf(
                    expression.span,
                    try Resolver.typeSetupKey(self.arena, type_key),
                    reference.display,
                    "this",
                );
            }
        }
        return self.typeOfFunctionValue(expression, reference);
    }
    if (!binding.assigned) {
        try self.reportUnassigned(expression.span, reference.display, binding.*);
        binding.assigned = true;
    }
    return binding.type;
}

/// A property: `count` is the only one so far (8.5).
fn typeOfMember(self: *Checker, expression: *const Ast.Expression, member: Ast.Expression.Member) Error!Type {
    // Section 4.4's `type_name`, which every value has, `nothing` included,
    // so it needs no proof that an optional is there. It reads no field, so
    // it needs none of `self`'s either.
    if (member.position == null and std.mem.eql(u8, member.name, "type_name")) {
        const value = if (isSelf(member.base)) (self.find("self") orelse return .invalid).type else try self.typeOf(member.base);
        try self.type_names.put(self.arena, expression, value);
        return .string;
    }
    // `self.x` inside a constructor reads one field, which needs only that
    // field to be set, not all of them.
    if (self.constructing != null and member.base.data == .name and
        std.mem.eql(u8, member.base.data.name, "self") and member.position == null)
    {
        // Section 10.5: a base class's private members stay private to it.
        if (try self.memberOwner(self.constructing.?.type, member.name)) |owner| {
            if (try self.reportPrivate(owner, member.name, member.name_span)) return .invalid;
        }
        if (try self.propertyOf(self.constructing.?.type, member.name)) |property| {
            if (try self.reportOverridable(member.name, member.name_span, "read")) return .invalid;
            return self.typeOfPropertyRead(member, property);
        }
        if (try self.fieldSetBinding(member.name)) |set| {
            if (!set.assigned) {
                const building = self.constructing.?;
                if (building.part == .default_of or self.in_parameter_default) {
                    try self.reportWithHelp(
                        member.name_span,
                        "`self.{s}` is not set yet when this default runs",
                        .{member.name},
                        "{s}",
                        .{if (self.in_parameter_default)
                            "A parameter default runs before the constructor's body, so it can read only fields that have defaults of their own."
                        else if (building.declaration.constructor == null)
                            "A default can read only the fields declared before it."
                        else
                            "A default runs before the constructor, so it can read only earlier fields that have defaults of their own."},
                    );
                } else {
                    try self.reportWithHelp(
                        member.name_span,
                        "`self.{s}` is read here before it is set",
                        .{member.name},
                        "Set `self.{s}` first, as in `self.{s} = ...`.",
                        .{ member.name, member.name },
                    );
                }
                set.assigned = true;
            }
            return set.type;
        }
        const building = self.constructing.?.type;
        if (try self.memberKey(building, member.name) != null) {
            if (try self.reportOverridable(member.name, member.name_span, "capture")) return .invalid;
            // Section 10.2: capturing a method copies `self` (7.5), which
            // needs every field, exactly as calling one does.
            if (try self.firstUnsetField()) |field| {
                if (!try self.reportInDefault(member.name_span, "capture a method of `self`")) try self.reportWithHelp(
                    member.name_span,
                    "`{s}` cannot be captured until every field of `self` is set",
                    .{member.name},
                    "Set `self.{s}` first. Capturing a method keeps a copy of `self`, so it has to wait for all of them.",
                    .{field},
                );
                return .invalid;
            }
            return self.typeOfMethodValue(expression, building, member.name);
        }
        // Not a field. Reported directly, since going through `typeOf(self)`
        // would first complain that `self` is not ready yet.
        if (try self.reportTypeMemberThroughValue(building, member.name, member.name_span)) return .invalid;
        try self.report(
            member.name_span,
            "{f} has no field named `{s}`",
            .{ building, member.name },
            "Check the field name in the type's declaration.",
        );
        return .invalid;
    }
    const base = try self.typeOf(member.base);
    if (base.kind == .invalid) return .invalid;
    if (!try self.requirePresent(base, member.base, member.name)) return .invalid;

    if (base.kind == .struct_value) {
        if (try self.memberOwner(base, member.name)) |owner| {
            if (try self.reportPrivate(owner, member.name, member.name_span)) return .invalid;
        }
        for (base.user.?.fields) |field| {
            if (!std.mem.eql(u8, field.name, member.name)) continue;
            if (isSuper(member.base)) {
                try self.reportWithHelp(
                    member.name_span,
                    "`{s}` is a field, so reach it through `self`",
                    .{member.name},
                    "`super` reaches a base class's version of a method or property. A subclass never replaces a field, so `self.{s}` is the same one.",
                    .{member.name},
                );
                return .invalid;
            }
            return field.type;
        }
        if (try self.propertyOf(base, member.name)) |property| {
            if (isSuper(member.base)) try self.super_members.put(self.arena, expression, property.getter);
            return self.typeOfPropertyRead(member, property);
        }
        if (try self.reportTypeMemberThroughValue(base, member.name, member.name_span)) return .invalid;
        if (try self.memberKey(base, member.name)) |key| {
            if (try self.reportAbstractThroughSuper(member, key)) return .invalid;
            return self.typeOfMethodValue(expression, base, member.name);
        }
        try self.report(
            member.name_span,
            "{f} has no field named `{s}`",
            .{ base, member.name },
            try self.subclassMemberHelp(base, member, "Check the field name in the type's declaration."),
        );
        return .invalid;
    }

    // Section 8.2's `entry.0`. The position is known where it is written, so an
    // invalid one is a compile-time error rather than a runtime one.
    if (member.position) |position| {
        if (base.kind != .tuple) {
            try self.report(
                member.name_span,
                "`{f}` has no positions",
                .{base},
                "Only a tuple is reached by position. Write the name of what you want instead.",
            );
            return .invalid;
        }
        if (position >= base.elements.len) {
            try self.reportWithHelp(
                member.name_span,
                "{f} has no position {d}",
                .{ base, position },
                "Its positions are `0` through `{d}`.",
                .{base.elements.len - 1},
            );
            return .invalid;
        }
        return base.elements[position];
    }

    if (base.kind == .tuple) {
        if (std.mem.eql(u8, member.name, "count")) {
            try self.reportWithHelp(
                member.name_span,
                "a tuple has no `count`",
                .{},
                "Its size is fixed where it is written. Reach its positions with `.0` through `.{d}`.",
                .{base.elements.len - 1},
            );
            return .invalid;
        }
        try self.report(
            member.name_span,
            "a tuple has no `{s}`",
            .{member.name},
            "Reach a tuple by position, as in `entry.0`, or unpack it into names.",
        );
        return .invalid;
    }

    // Section 8.5: size is a read-only property on every collection.
    if (base.kind == .dictionary or base.kind == .set) {
        if (std.mem.eql(u8, member.name, "count")) return .int;
        try self.reportUnknownMember(base, member, "property");
        return .invalid;
    }

    if (base.kind == .list or base.kind == .string) {
        if (std.mem.eql(u8, member.name, "count")) return .int;
        // Section 8.5: `first` and `last` are properties, and may be absent
        // because the list may be empty. Their companion is `empty?`, which
        // 4.5 names because a list of optionals cannot tell the two apart.
        if (base.kind == .list and
            (std.mem.eql(u8, member.name, "first") or std.mem.eql(u8, member.name, "last")))
        {
            return base.element.?.optionalOf();
        }
        if (Type.list_methods.has(member.name) or Type.string_methods.has(member.name) or
            std.mem.eql(u8, member.name, "to_string"))
        {
            try self.reportWithHelp(
                member.name_span,
                "`{s}` is a method, so it needs parentheses",
                .{member.name},
                "Call it, as in `.{s}()`. Methods cannot be used as values yet.",
                .{member.name},
            );
            return .invalid;
        }
    }
    try self.reportUnknownMember(base, member, "property");
    return .invalid;
}

/// Section 7.5's `counter.increment` without parentheses: a function that
/// calls the method on its own copy of the receiver, which a changing method
/// keeps changing from one call to the next. Nothing about the receiver's
/// place is checked, since the copy is the only thing that can change.
fn typeOfMethodValue(self: *Checker, expression: *const Ast.Expression, owner: Type, name: []const u8) Error!Type {
    const key = (try self.memberKey(owner, name)).?;
    try self.method_calls.put(self.arena, expression, key);
    const declared = try self.signatureFor(key);
    if (takesSelf(declared, owner)) {
        try self.reportTakesSelf(expression.data.member.name_span, name, owner);
        return .invalid;
    }
    const signature = try self.signatureOn(declared, owner);
    return Type.functionOf(self.arena, .{
        .parameters = signature.parameters,
        .parameter_names = signature.parameter_names,
        .return_type = signature.return_type,
    });
}

/// A method call such as `scores.append(10)`.
fn typeOfMethodCall(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
) Error!Type {
    // Section 10.2: "Before all fields are ready ... instance methods may not
    // be called."
    if (self.constructing != null and member.base.data == .name and
        std.mem.eql(u8, member.base.data.name, "self"))
    {
        if (try self.reportOverridable(member.name, member.name_span, "call")) {
            try self.typeArguments(call.arguments);
            return .invalid;
        }
        if (try self.firstUnsetField()) |field| {
            if (!try self.reportInDefault(member.name_span, "call a method on `self`")) try self.reportWithHelp(
                member.name_span,
                "`{s}` cannot be called until every field of `self` is set",
                .{member.name},
                "Set `self.{s}` first. A method may read any field, so it has to wait for all of them.",
                .{field},
            );
            try self.typeArguments(call.arguments);
            return .invalid;
        }
    }

    const base = try self.typeOf(member.base);
    if (base.kind == .invalid) {
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    if (base.kind != .struct_value or base.optional) {
        // Nothing else about the call is checked, since a named value's
        // position means nothing here and would only report again.
        if (try self.rejectNames(call)) {
            try self.typeArguments(call.arguments);
            return .invalid;
        }
    }

    // Section 4.5's `or` is the one thing you may do to a value that may be
    // absent without proving it is there, because supplying the fallback is
    // what proves it.
    if (std.mem.eql(u8, member.name, "or")) return self.typeOfOr(expression, call, member, base);
    if (!try self.requirePresent(base, member.base, member.name)) {
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    if (base.kind == .struct_value) return self.typeOfStructMethodCall(expression, call, member, base);
    if (base.kind == .string) return self.typeOfStringMethod(call, member);
    if ((base.kind == .int or base.kind == .float or base.kind == .bool) and
        std.mem.eql(u8, member.name, "to_string"))
    {
        _ = try self.requireArity(member, call.arguments, 0, 0);
        return .string;
    }

    if (base.kind == .list and std.mem.eql(u8, member.name, "count")) {
        try self.report(
            member.name_span,
            "`count` is a property, so it takes no parentheses",
            .{},
            "Write `.count` without `()`.",
        );
        try self.typeArguments(call.arguments);
        return .int;
    }

    if (base.kind == .dictionary or base.kind == .set) {
        return self.typeOfMapMethod(expression, call, member, base);
    }

    if (base.kind == .list) {
        // Section 8.2 names this as the way to build a set where no set type is
        // expected: `["red", "green"].to_set()`.
        if (std.mem.eql(u8, member.name, "to_set")) {
            _ = try self.requireArity(member, call.arguments, 0, 0);
            const member_type = base.element.?.*;
            try self.requireEligibleMember(member_type, member.name_span);
            return Type.setOf(self.arena, member_type);
        }
        if (std.mem.eql(u8, member.name, "each")) return self.typeOfEach(call, member, base);
        if (std.mem.eql(u8, member.name, "map")) return self.typeOfMap(call, member, base);
        // Section 8.6's searching pair. `find_index` is what 4.5 names as the
        // companion for a list whose elements may themselves be `nothing`.
        if (std.mem.eql(u8, member.name, "find")) {
            _ = try self.requireBlock(call, member, base, .bool) orelse return .invalid;
            return base.element.?.optionalOf();
        }
        if (std.mem.eql(u8, member.name, "find_index")) {
            _ = try self.requireBlock(call, member, base, .bool) orelse return .invalid;
            return Type.int.optionalOf();
        }
    }

    const method = (if (base.kind == .list) Type.list_methods.get(member.name) else null) orelse {
        try self.reportUnknownMember(base, member, "method");
        try self.typeArguments(call.arguments);
        return .invalid;
    };
    const element = base.element.?.*;

    if (call.arguments.len != method.parameters.len) {
        const expected = method.parameters.len;
        try self.report(
            member.name_span,
            "`{s}` takes {d} argument{s}, but this call passes {d}",
            .{ member.name, expected, if (expected == 1) "" else "s", call.arguments.len },
            "Match the number of arguments to what the method needs.",
        );
        try self.typeArguments(call.arguments);
    } else {
        for (call.arguments, method.parameters) |argument, operand| {
            const wanted: Type = switch (operand) {
                .element => element,
                .index => .int,
            };
            const actual = try self.typeOfExpected(argument, wanted);
            if (actual.assignableTo(wanted)) continue;
            try self.report(
                argument.span,
                "this is {f}, but `{s}` needs {f}",
                .{ actual, member.name, wanted },
                "Pass a value of the type the list holds, or convert it first.",
            );
        }
    }

    if (method.mutates) try self.requireChangeable(member);

    return switch (method.result) {
        .nothing => .nothing,
        .bool => .bool,
        .element => element,
    };
}

/// Section 4.5: everything but `or` needs the value to be there first.
/// `member` is the name being reached for, so the diagnostic can repeat it.
/// Returns false when it reported.
fn requirePresent(
    self: *Checker,
    base: Type,
    at: *const Ast.Expression,
    member: ?[]const u8,
) Error!bool {
    if (!base.optional) return true;
    // A name can be proved present by testing it; anything else has to be put
    // in one first, which is what the correction says.
    const help = if (at.data == .name and self.unprovable(at.data.name) != null)
        try std.fmt.allocPrint(
            self.arena,
            "A test cannot prove `{s}` is there, because {s} can set it back to `nothing` at any time. Copy it into a `const` and test that, or give it a fallback with `.or(...)`.",
            .{ at.data.name, self.unprovable(at.data.name).? },
        )
    else if (at.data == .name)
        try std.fmt.allocPrint(
            self.arena,
            "Give it a fallback with `.or(...)`, or check it first with `if {s} != nothing {{ ... }}`.",
            .{at.data.name},
        )
    else
        "Give it a fallback with `.or(...)`, or put it in a name and check that against `nothing` first.";

    if (member) |name| {
        try self.report(
            at.span,
            "this is {f}, so `{s}` may not be there to use",
            .{ base, name },
            help,
        );
    } else {
        try self.report(at.span, "this is {f}, so it may not be there to use", .{base}, help);
    }
    return false;
}

/// Section 4.5's `or`: the value if it is there, and the fallback if it is not.
/// The result is never optional, which is what makes it the way out.
fn typeOfOr(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    base: Type,
) Error!Type {
    const present = base.payload();
    // The interpreter widens the fallback to this, since `.or(0)` standing in
    // for a `Float?` has to produce `0.0` (4.4).
    try self.literal_types.put(self.arena, expression, present);
    if (!base.optional) {
        try self.report(
            member.name_span,
            "`or` needs a value that may be absent, and this is already {f}",
            .{base},
            "Remove the `.or(...)`; there is nothing for it to stand in for.",
        );
        try self.typeArguments(call.arguments);
        return present;
    }
    if (call.arguments.len != 1) {
        try self.report(
            member.name_span,
            "`or` takes 1 argument, but this call passes {d}",
            .{call.arguments.len},
            "Pass what to use when the value is absent, as in `.or(0)`.",
        );
        try self.typeArguments(call.arguments);
        return present;
    }

    const fallback = try self.typeOfExpected(call.arguments[0], present);
    if (!fallback.assignableTo(present)) {
        try self.report(
            call.arguments[0].span,
            "this is {f}, but the value it stands in for is {f}",
            .{ fallback, present },
            mismatchHelp(fallback, present, "The fallback has to be the same kind of value."),
        );
    }
    return present;
}

/// Section 8.5's `each`, the traversal every collection has. The block receives
/// one element and is run for its effect, so whatever it produces is ignored —
/// except a body that is a single expression producing a value, which is
/// section 5.2's unused result and is almost always a `map` written as an
/// `each`.
fn typeOfEach(self: *Checker, call: Ast.Expression.Call, member: Ast.Expression.Member, base: Type) Error!Type {
    const block = try self.requireBlock(call, member, base, .invalid) orelse return .nothing;
    if (block.data == .lambda and block.data.lambda.body == .expression) {
        const body = block.data.lambda.body.expression;
        if (body.data != .call) {
            try self.report(
                body.span,
                "this block produces a value, and `each` does not use it",
                .{},
                "Use `map` to collect the results into a list, or do something with each element here.",
            );
        }
    }
    return .nothing;
}

/// Section 8.6's `map`: a new list of what the block produces for each element.
/// The block's result type is what decides the list's element type, so nothing
/// is expected of it beyond producing something.
fn typeOfMap(self: *Checker, call: Ast.Expression.Call, member: Ast.Expression.Member, base: Type) Error!Type {
    const block = try self.requireBlock(call, member, base, .invalid) orelse return .invalid;
    const produced = self.literal_types.get(block) orelse (try self.typeOf(block));
    if (produced.kind != .function) return .invalid;

    const result = produced.signature.?.return_type;
    if (result.kind == .nothing) {
        try self.report(
            block.span,
            "this block produces nothing, so there is nothing for `map` to collect",
            .{},
            "Produce a value for each element, or use `each` to run the block for its effect.",
        );
        return .invalid;
    }
    return Type.listOf(self.arena, result);
}

/// The single block argument a higher-order method takes, checked against a
/// callable that receives one element. `result` of `invalid` asks for a block
/// without saying what it must produce.
/// Section 8.5's essential vocabulary for a dictionary and a set. The rest of
/// section 8.6 arrives with the standard-library slice.
fn typeOfMapMethod(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    base: Type,
) Error!Type {
    _ = expression;
    const set = base.kind == .set;
    const key = if (set) base.element.?.* else base.key.?.*;
    const value = base.element.?.*;
    const name = member.name;

    // Shared by both, and by lists.
    if (std.mem.eql(u8, name, "each")) return self.typeOfEach(call, member, base);
    if (std.mem.eql(u8, name, "map")) return self.typeOfMap(call, member, base);
    if (std.mem.eql(u8, name, "empty?")) {
        _ = try self.requireArity(member, call.arguments, 0, 0);
        return .bool;
    }
    if (std.mem.eql(u8, name, "count")) {
        try self.report(
            member.name_span,
            "`count` is a property, so it takes no parentheses",
            .{},
            "Write `.count` without `()`.",
        );
        try self.typeArguments(call.arguments);
        return .int;
    }

    // Section 8.5: a dictionary and a set each ask about membership with the
    // name that reads correctly for what they hold.
    const membership = if (set) "contains?" else "contains_key?";
    if (std.mem.eql(u8, name, membership)) {
        if (try self.requireArity(member, call.arguments, 1, 1)) {
            try self.requireKey(call.arguments[0], key);
        } else {
            try self.typeArguments(call.arguments);
        }
        return .bool;
    }

    if (std.mem.eql(u8, name, "remove")) {
        if (try self.requireArity(member, call.arguments, 1, 1)) {
            try self.requireKey(call.arguments[0], key);
        } else {
            try self.typeArguments(call.arguments);
        }
        try self.requireMutableReceiver(member, name);
        // Section 8.5's removal answers with what was there, and an entry that
        // was never there is absence rather than an error, because a key that
        // is not present is an ordinary thing to ask about.
        return if (set) .nothing else value.optionalOf();
    }

    if (set) {
        if (std.mem.eql(u8, name, "add")) {
            if (try self.requireArity(member, call.arguments, 1, 1)) {
                try self.requireKey(call.arguments[0], key);
            } else {
                try self.typeArguments(call.arguments);
            }
            try self.requireMutableReceiver(member, name);
            return .nothing;
        }
        try self.reportUnknownMember(base, member, "method");
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    if (std.mem.eql(u8, name, "contains_value?")) {
        if (try self.requireArity(member, call.arguments, 1, 1)) {
            const actual = try self.typeOfExpected(call.arguments[0], value);
            if (!actual.assignableTo(value)) try self.report(
                call.arguments[0].span,
                "this is {f}, but the dictionary's values are {f}",
                .{ actual, value },
                "Ask with a value of the dictionary's own type.",
            );
        } else {
            try self.typeArguments(call.arguments);
        }
        return .bool;
    }

    if (std.mem.eql(u8, name, "keys")) {
        _ = try self.requireArity(member, call.arguments, 0, 0);
        return Type.listOf(self.arena, key);
    }
    if (std.mem.eql(u8, name, "values")) {
        _ = try self.requireArity(member, call.arguments, 0, 0);
        return Type.listOf(self.arena, value);
    }
    if (std.mem.eql(u8, name, "entries")) {
        _ = try self.requireArity(member, call.arguments, 0, 0);
        return Type.listOf(self.arena, try self.itemType(base));
    }
    if (std.mem.eql(u8, name, "merge")) {
        if (try self.requireArity(member, call.arguments, 1, 1)) {
            const actual = try self.typeOfExpected(call.arguments[0], base);
            if (!actual.assignableTo(base)) try self.report(
                call.arguments[0].span,
                "this is {f}, but `merge` needs {f}",
                .{ actual, base },
                "Both dictionaries must hold the same types.",
            );
        } else {
            try self.typeArguments(call.arguments);
        }
        try self.requireMutableReceiver(member, name);
        return .nothing;
    }

    try self.reportUnknownMember(base, member, "method");
    try self.typeArguments(call.arguments);
    return .invalid;
}

/// What a receiver's path bottoms out at, once every index and struct field
/// on it has been walked. `.reported` means a `const` field, a tuple
/// position, or a namespace-qualified place already produced the diagnostic,
/// and the caller does nothing more.
/// Where a receiver path starts and what freezes it, once walked. `frozen` is the
/// first `const` field after the last object on the path, which stops a change
/// as a `const` binding would. `reference` says the path passes through an
/// object (10.1): the object is shared, so the binding the path starts from is
/// not what changes, and neither is anything frozen before the object.
const Place = union(enum) {
    reported,
    /// Nothing about the path is known beyond where it starts, so only that is
    /// checked.
    root: *const Ast.Expression,
    typed: Typed,

    const Typed = struct {
        root: *const Ast.Expression,
        type: Type,
        reference: bool = false,
        frozen: ?Frozen = null,
    };
};

const Frozen = struct {
    name: []const u8,
    span: Source.Span,
    owner: Type,
    field_type: Type,
};

fn isTrait(t: Type) bool {
    return t.kind == .struct_value and t.user.?.trait;
}

fn isClass(t: Type) bool {
    return t.kind == .struct_value and !t.optional and t.user.?.class;
}

/// Walks a receiver down through indices and struct fields to the expression
/// it is ultimately reached from. Section 4.3 freezes a `const` field exactly
/// as it freezes a binding, a tuple position can never be written through at
/// all since there is no way to change a tuple after it is built (8.2), and
/// changing a value reached through a namespace is not implemented. Recursing
/// to the root first and checking each field on the way back out means a
/// field's owner type is read from the binding or the previous step, never
/// from `typeOf`, which would repeat whatever the caller's own check reported.
fn resolvePlace(self: *Checker, expression: *const Ast.Expression) Error!Place {
    switch (expression.data) {
        .index => |index| {
            const base = switch (try self.resolvePlace(index.base)) {
                .reported => return .reported,
                .root => |root| return .{ .root = root },
                .typed => |typed| typed,
            };
            const item = if (base.type.kind == .list or base.type.kind == .dictionary)
                base.type.element.?.*
            else
                return .{ .root = base.root };
            var reached = base;
            reached.type = item;
            return .{ .typed = reached };
        },
        .member => |inner| {
            // `Shapes.scores` reaches a real value, but changing it from
            // another file is not implemented; this is not the same as
            // `Shapes` alone being "a namespace, not a value" (checked
            // elsewhere), so it gets its own diagnostic.
            if (self.facts.qualified.get(expression)) |key| {
                if (self.type_fields.contains(key)) {
                    return .{ .typed = .{ .root = expression, .type = self.module.get(key).?.declared } };
                }
                try self.report(
                    expression.span,
                    "changing a value through its namespace is not available yet",
                    .{},
                    "Bring it into this file with `using`, then change it directly.",
                );
                return .reported;
            }
            // `entry.0`: a tuple position can never be written through, since
            // there is no way to change a tuple once it is built (8.2).
            if (inner.position != null) {
                try self.report(
                    expression.span,
                    "a tuple cannot be changed in place",
                    .{},
                    "Build a new one, as in `pair = (1, pair.1)`.",
                );
                return .reported;
            }
            var base = switch (try self.resolvePlace(inner.base)) {
                .reported => return .reported,
                .root => |root| return .{ .root = root },
                .typed => |typed| typed,
            };
            if (base.type.kind != .struct_value) return .{ .root = base.root };
            // Already reported when the receiver was type-checked.
            if (Resolver.isPrivate(inner.name)) {
                const owner = try self.memberOwner(base.type, inner.name) orelse base.type.user.?.name;
                if (!self.insideType(owner, inner.name_span)) return .reported;
            }
            if (try self.propertyOf(base.type, inner.name) != null) {
                try self.reportComputedInPlace(inner.name, inner.name_span);
                return .reported;
            }
            if (isClass(base.type)) {
                base.reference = true;
                base.frozen = null;
            }
            for (base.type.user.?.fields) |field| {
                if (!std.mem.eql(u8, field.name, inner.name)) continue;
                if (!field.mutable and base.frozen == null) {
                    base.frozen = .{ .name = inner.name, .span = inner.name_span, .owner = base.type, .field_type = field.type };
                }
                base.type = field.type;
                return .{ .typed = base };
            }
            return .{ .root = base.root };
        },
        .name => {
            if (self.find(expression.data.name)) |binding| {
                return .{ .typed = .{ .root = expression, .type = binding.type } };
            }
            return .{ .root = expression };
        },
        // A temporary. Its type is worked out again, quietly, since the
        // caller has already reported anything wrong with it; what matters
        // here is only whether the path through it reaches an object.
        else => {
            const reported = self.diagnostics.items.len;
            const temporary = try self.typeOf(expression);
            self.diagnostics.shrinkRetainingCapacity(reported);
            return .{ .typed = .{ .root = expression, .type = temporary, .reference = isClass(temporary) } };
        },
    }
}

fn reportFrozenField(self: *Checker, frozen: Frozen) Error!void {
    try self.reportWithHelp(
        frozen.span,
        "`{s}` is a `const` field of {f}, so it cannot change",
        .{ frozen.name, frozen.owner },
        "Declare it `var {s}: {f}` in {f} if it needs to change.",
        .{ frozen.name, frozen.field_type, frozen.owner },
    );
}

/// What a change through a receiver path needs of where it starts: a changing
/// binding, unless the path reaches an object first. Returns the root when
/// that is still for the caller to judge because it is a temporary with no
/// object on the path.
fn requireChangeablePath(self: *Checker, base: *const Ast.Expression) Error!?*const Ast.Expression {
    const place = try self.resolvePlace(base);
    const typed: Place.Typed = switch (place) {
        .reported => return null,
        .root => |root| .{ .root = root, .type = .invalid },
        .typed => |typed| typed,
    };
    if (typed.frozen) |frozen| {
        try self.reportFrozenField(frozen);
        return null;
    }
    if (typed.reference) return null;
    const root = typed.root;
    if (root.data == .name) {
        const binding = self.find(root.data.name) orelse return null;
        try self.requireMutable(root.data.name, root.span, binding.*);
        return null;
    }
    if (self.facts.qualified.get(root)) |key| {
        if (self.type_fields.contains(key)) {
            try self.requireMutable(try Resolver.displayKey(self.arena, key), root.span, self.module.get(key).?);
        }
        return null;
    }
    return root;
}

/// Section 4.3 and 7.1: a method that changes its receiver cannot be called on
/// a `const`, a parameter, a loop variable, or a temporary.
fn requireMutableReceiver(self: *Checker, member: Ast.Expression.Member, name: []const u8) Error!void {
    if (try self.requireChangeablePath(member.base) == null) return;
    try self.reportWithHelp(
        member.name_span,
        "`{s}` changes what it is called on, and this value has nowhere to keep the change",
        .{name},
        "Put it in a `var` first, then call `{s}` on that.",
        .{name},
    );
}

/// Section 8.6: "every ordinary collection block receives one logical item",
/// and a dictionary's item is a `(key, value)` tuple. That is also what a `for`
/// loop over one visits, so both go through here.
fn itemType(self: *Checker, collection: Type) Error!Type {
    if (collection.kind != .dictionary) return collection.element.?.*;
    return Type.tupleOf(self.arena, &.{ collection.key.?.*, collection.element.?.* });
}

fn requireBlock(
    self: *Checker,
    call: Ast.Expression.Call,
    member: Ast.Expression.Member,
    base: Type,
    result: Type,
) Error!?*const Ast.Expression {
    if (call.arguments.len != 1) {
        try self.report(
            member.name_span,
            "`{s}` takes 1 block, but this call passes {d} argument{s}",
            .{ member.name, call.arguments.len, if (call.arguments.len == 1) "" else "s" },
            "Write the block after the method, as in `numbers.each { number => print(number) }`.",
        );
        try self.typeArguments(call.arguments);
        return null;
    }

    const element = try self.arena.create(Type);
    element.* = try self.itemType(base);
    const expected = try Type.functionOf(self.arena, .{
        .parameters = element[0..1],
        .return_type = result,
    });

    const block = call.arguments[0];
    const actual = try self.typeOfExpected(block, expected);
    if (actual.kind != .function and actual.kind != .invalid) {
        try self.report(
            block.span,
            "`{s}` needs a block, but this is {f}",
            .{ member.name, actual },
            "Write the block after the method, as in `numbers.each { number => print(number) }`.",
        );
        return null;
    }
    return block;
}

/// Section 9.2's string methods. None changes the string, which is immutable.
fn typeOfStringMethod(self: *Checker, call: Ast.Expression.Call, member: Ast.Expression.Member) Error!Type {
    if (std.mem.eql(u8, member.name, "count")) {
        try self.report(
            member.name_span,
            "`count` is a property, so it takes no parentheses",
            .{},
            "Write `.count` without `()`.",
        );
        try self.typeArguments(call.arguments);
        return .int;
    }
    const method = Type.string_methods.get(member.name) orelse {
        try self.reportUnknownMember(.string, member, "method");
        try self.typeArguments(call.arguments);
        return .invalid;
    };

    const most = method.parameters.len;
    if (try self.requireArity(member, call.arguments, most - method.optional, most)) {
        for (call.arguments, method.parameters[0..call.arguments.len]) |argument, operand| {
            const wanted: Type = switch (operand) {
                .string => .string,
                .int => .int,
                .float => .float,
            };
            const actual = try self.typeOf(argument);
            if (actual.assignableTo(wanted)) continue;
            try self.report(
                argument.span,
                "this is {f}, but `{s}` needs {f}",
                .{ actual, member.name, wanted },
                "Pass a value of the type the method needs, or convert it first.",
            );
        }
    }

    const result: Type = switch (method.result) {
        .bool => .bool,
        .int => .int,
        .float => .float,
        .string => .string,
        .strings => try Type.listOf(self.arena, .string),
    };
    return if (method.maybe) result.optionalOf() else result;
}

/// Reports a call with too few or too many arguments, typing them anyway.
/// True when the count is right.
fn requireArity(
    self: *Checker,
    member: Ast.Expression.Member,
    arguments: []const *const Ast.Expression,
    least: usize,
    most: usize,
) Error!bool {
    if (arguments.len >= least and arguments.len <= most) return true;
    if (least == most) {
        try self.report(
            member.name_span,
            "`{s}` takes {d} argument{s}, but this call passes {d}",
            .{ member.name, most, if (most == 1) "" else "s", arguments.len },
            "Match the number of arguments to what the method needs.",
        );
    } else {
        try self.report(
            member.name_span,
            "`{s}` takes {d} or {d} arguments, but this call passes {d}",
            .{ member.name, least, most, arguments.len },
            "Match the number of arguments to what the method needs.",
        );
    }
    try self.typeArguments(arguments);
    return false;
}

/// A mutating method changes the list it is called on, so that list has to be
/// one a program can see again: held by a `var`, directly or through indexing.
/// Changing a temporary, such as the result of a call, would be lost at once.
fn requireChangeable(self: *Checker, member: Ast.Expression.Member) Error!void {
    if (try self.requireChangeablePath(member.base) == null) return;
    try self.reportWithHelp(
        member.base.span,
        "`{s}` changes a list, but this list is a temporary value, so the change would be lost",
        .{member.name},
        "Store the list in a `var` first, then call `{s}` on it.",
        .{member.name},
    );
}

/// A member that does not exist, with the Emerald name for what the writer
/// probably meant when they reached for another language's.
fn reportUnknownMember(self: *Checker, base: Type, member: Ast.Expression.Member, comptime what: []const u8) Error!void {
    const suggestion: ?[]const u8 = switch (base.kind) {
        .list => familiarListName(member.name),
        .string => familiarStringName(member.name),
        .dictionary, .set => familiarMapName(member.name, base.kind == .set),
        else => null,
    };
    if (suggestion) |name| {
        return self.reportWithHelp(
            member.name_span,
            "{f} has no " ++ what ++ " `{s}`",
            .{ base, member.name },
            "Emerald calls this `{s}`.",
            .{name},
        );
    }
    try self.report(
        member.name_span,
        "{f} has no " ++ what ++ " `{s}`",
        .{ base, member.name },
        switch (base.kind) {
            .list => "A list has `count`, `empty?`, `contains?`, `append`, `insert`, `remove`, `remove_all`, `remove_at`, `remove_first`, `remove_last`, and `clear`.",
            .dictionary => "A dictionary has `count`, `empty?`, `each`, `map`, `contains_key?`, `contains_value?`, `keys`, `values`, `entries`, `remove`, and `merge`, and is looked up with `[key]`.",
            .set => "A set has `count`, `empty?`, `each`, `map`, `contains?`, `add`, and `remove`.",
            .string => "A String has `count`, `empty?`, `blank?`, `contains?`, `starts_with?`, `ends_with?`, `trim`, `upper`, `lower`, `capitalize`, `reverse`, `repeat`, `replace`, `substring`, `split`, `lines`, `chars`, `to_int`, and `to_float`, among others.",
            else => "Check the spelling, or what kind of value this is.",
        },
    );
}

/// Names other languages use for dictionary and set operations Emerald spells
/// differently.
fn familiarMapName(name: []const u8, set: bool) ?[]const u8 {
    const shared = std.StaticStringMap([]const u8).initComptime(.{
        .{ "length", "count" },
        .{ "size", "count" },
        .{ "len", "count" },
        .{ "is_empty", "empty?" },
        .{ "isEmpty", "empty?" },
        .{ "for_each", "each" },
        .{ "delete", "remove" },
        .{ "erase", "remove" },
        .{ "discard", "remove" },
    });
    if (shared.get(name)) |shared_name| return shared_name;

    if (set) {
        const set_names = std.StaticStringMap([]const u8).initComptime(.{
            .{ "contains_key?", "contains?" },
            .{ "has", "contains?" },
            .{ "includes", "contains?" },
            .{ "member?", "contains?" },
            .{ "insert", "add" },
            .{ "append", "add" },
            .{ "push", "add" },
        });
        return set_names.get(name);
    }

    const dictionary_names = std.StaticStringMap([]const u8).initComptime(.{
        .{ "get", "[key]" },
        .{ "put", "[key] =" },
        .{ "set", "[key] =" },
        .{ "add", "[key] =" },
        .{ "insert", "[key] =" },
        .{ "contains?", "contains_key?" },
        .{ "has_key", "contains_key?" },
        .{ "has_key?", "contains_key?" },
        .{ "includes?", "contains_key?" },
        .{ "key?", "contains_key?" },
        .{ "items", "entries" },
        .{ "pairs", "entries" },
        .{ "update", "merge" },
    });
    return dictionary_names.get(name);
}

/// Names other languages use for string operations Emerald spells differently.
fn familiarStringName(name: []const u8) ?[]const u8 {
    const familiar = std.StaticStringMap([]const u8).initComptime(.{
        .{ "length", "count" },
        .{ "size", "count" },
        .{ "len", "count" },
        .{ "upcase", "upper" },
        .{ "uppercase", "upper" },
        .{ "to_upper", "upper" },
        .{ "downcase", "lower" },
        .{ "lowercase", "lower" },
        .{ "to_lower", "lower" },
        .{ "strip", "trim" },
        .{ "includes", "contains?" },
        .{ "contains", "contains?" },
        .{ "starts_with", "starts_with?" },
        .{ "ends_with", "ends_with?" },
        .{ "empty", "empty?" },
        .{ "is_empty", "empty?" },
        .{ "slice", "substring" },
        .{ "substr", "substring" },
        .{ "reversed", "reverse" },
        .{ "parse", "to_int" },
    });
    return familiar.get(name);
}

/// Names other languages use for list operations Emerald spells differently.
fn familiarListName(name: []const u8) ?[]const u8 {
    const familiar = std.StaticStringMap([]const u8).initComptime(.{
        .{ "length", "count" },
        .{ "size", "count" },
        .{ "len", "count" },
        .{ "push", "append" },
        .{ "add", "append" },
        .{ "pop", "remove_last" },
        .{ "shift", "remove_first" },
        .{ "includes", "contains?" },
        .{ "contains", "contains?" },
        .{ "has", "contains?" },
        .{ "empty", "empty?" },
        .{ "is_empty", "empty?" },
        .{ "delete", "remove" },
        .{ "delete_at", "remove_at" },
        .{ "for_each", "each" },
        .{ "foreach", "each" },
        .{ "collect", "map" },
        .{ "select", "map" },
    });
    return familiar.get(name);
}

/// Ranges and the other ways of counting have no type of their own yet: they
/// are values in section 6.4, but everything a program could do with one
/// besides looping arrives with the collection vocabulary.
fn rejectCountingValue(self: *Checker, expression: *const Ast.Expression) Error!Type {
    try self.checkCounting(expression);
    try self.report(
        expression.span,
        "a range can only be looped over so far",
        .{},
        "Use it in a `for` loop, as in `for i in 10.down_to(1)`.",
    );
    return .invalid;
}

fn typeOfUnary(
    self: *Checker,
    expression: *const Ast.Expression,
    unary: Ast.Expression.Unary,
) Error!Type {
    const operand = try self.typeOf(unary.operand);
    if (operand.kind == .invalid) return .invalid;

    switch (unary.operator) {
        .negate => {
            if (operand.isNumber()) return operand;
            try self.report(
                expression.span,
                "`-` needs a number, but this is {f}",
                .{operand},
                "Use `not` to invert a Bool.",
            );
        },
        .not => {
            if (operand.kind == .bool) return .bool;
            try self.report(
                expression.span,
                "`not` needs a Bool, but this is {f}",
                .{operand},
                "Compare it to something first, as in `not (count > 0)`.",
            );
        },
    }
    return .invalid;
}

fn typeOfBinary(
    self: *Checker,
    expression: *const Ast.Expression,
    binary: Ast.Expression.Binary,
) Error!Type {
    const left = try self.typeOf(binary.left);
    const right = try self.typeOf(binary.right);
    if (left.kind == .struct_value and !left.optional) {
        if (binary.operator.contract()) |contract| {
            return self.typeOfOperatorCall(expression.span, binary.operator.lexeme(), contract, binary.left, left, right);
        }
    }
    return self.arithmetic(expression.span, binary.operator, left, right);
}

fn arithmetic(
    self: *Checker,
    span: Source.Span,
    operator: Ast.BinaryOperator,
    left: Type,
    right: Type,
) Error!Type {
    // `+` joins two Strings; nothing else mixes text and arithmetic. A String
    // that may be absent is not one until it is proved present (4.5).
    if (left.kind == .string or right.kind == .string) {
        if (left.kind == .invalid or right.kind == .invalid) return .invalid;
        if (operator == .add and left.kind == .string and right.kind == .string and
            !left.optional and !right.optional) return .string;
        if (operator == .add) {
            try self.report(
                span,
                "`+` joins two Strings, but this is {f} and {f}",
                .{ left, right },
                if (left.optional or right.optional)
                    "One of these may be absent. Give it a fallback with `.or(\"\")`, or check it against `nothing` first."
                else
                    "Convert the value with `to_string()`, or use interpolation, as in `\"#{name}: #{score}\"`.",
            );
        } else {
            try self.report(
                span,
                "{s} needs numbers, but this is {f} and {f}",
                .{ operator.describe(), left, right },
                "Strings have no arithmetic. `+` is the one operator for them, and it joins two Strings.",
            );
        }
        return .invalid;
    }

    if (left.kind == .struct_value and !left.optional) {
        if (operator.contract()) |contract| return self.typeOfOperatorCall(span, operator.lexeme(), contract, null, left, right);
    }

    // Section 5.3: `/` always produces a Float.
    return Type.arithmeticResult(left, right, operator == .divide) orelse {
        try self.report(
            span,
            "{s} needs numbers, but this is {f} and {f}",
            .{ operator.describe(), left, right },
            // A number that may be absent is the common case here, and it has a
            // different fix from a value that is the wrong kind entirely.
            if ((left.optional and left.payload().isNumber()) or (right.optional and right.payload().isNumber()))
                "One of these may be absent. Give it a fallback with `.or(0)`, or check it against `nothing` first."
            else if (left.kind == .struct_value and !left.optional)
                "Only `+`, `-`, `*`, `/`, and ordering can be given a meaning for a user type, through the prelude's traits. Write a method for this instead."
            else if (right.kind == .struct_value and !right.optional and operator.contract() != null)
                "An operator on a value of a user type runs that type's method, so the value goes on the left, with one of the same type on the right. For anything else, write a method with a name of its own, such as `scaled_by`."
            else
                "Arithmetic works on Int and Float.",
        );
        return .invalid;
    };
}

/// Section 11.5: an operator on a value of a user type runs a method of a
/// prelude trait the type adopts, with the right operand as its argument, and
/// gives what the method gives.
fn typeOfOperatorCall(
    self: *Checker,
    span: Source.Span,
    lexeme: []const u8,
    contract: Ast.OperatorContract,
    /// The left operand as written, or null for a compound assignment, whose
    /// left side is a place.
    left_node: ?*const Ast.Expression,
    left: Type,
    right: Type,
) Error!Type {
    const trait_key = try std.fmt.allocPrint(self.arena, Resolver.prelude_namespace ++ ".{s}", .{contract.trait});
    const trait = self.structs.get(trait_key).?.user.?;
    const user = left.user.?;
    const result_name = if (std.mem.eql(u8, contract.method, Ast.OperatorContract.ordered.method)) "Int" else user.display_name;
    if (!user.conformsTo(trait)) {
        if (left.opaque_self) {
            try self.reportWithHelp(
                span,
                "`{s}` needs a type that adopts `{s}`, but this is {f}",
                .{ lexeme, contract.trait, left },
                "`Self` in `{s}` promises only what `{s}` declares. Add `with {s}` to `{s}`.",
                .{ user.display_name, user.display_name, contract.trait, user.display_name },
            );
        } else if (user.trait) {
            try self.reportWithHelp(
                span,
                "`{s}` needs a type that adopts `{s}`, but this is {f}",
                .{ lexeme, contract.trait, left },
                "A value seen as `{s}` promises only what `{s}` declares.",
                .{ user.display_name, user.display_name },
            );
        } else if (!std.mem.eql(u8, self.keyOf(contract.trait), trait_key)) {
            try self.reportWithHelp(
                span,
                "`{s}` needs {f} to adopt the prelude's `{s}`",
                .{ lexeme, left, contract.trait },
                "This program declares its own `{s}`, which takes the prelude's place wherever the name is written, but operators run only through the prelude's. Rename this program's `{s}`.",
                .{ contract.trait, contract.trait },
            );
        } else {
            try self.reportWithHelp(
                span,
                "`{s}` needs {f} to adopt `{s}`",
                .{ lexeme, left, contract.trait },
                "Add `with {s}` to `{s}`, and give it `@override func {s}(other: {s}): {s}`.",
                .{ contract.trait, user.display_name, contract.method, user.display_name, result_name },
            );
        }
        return .invalid;
    }
    const key = try self.memberKey(left, contract.method) orelse return .invalid;
    // Section 10.2: an operator on `self` calls a method through it, which
    // construction cannot do for one a subclass could override. Using `self`
    // before every field is set was already reported where it is written.
    if (left_node) |node| if (isSelf(node) and try self.reportOverridable(contract.method, span, "call")) return .invalid;
    const declared = try self.signatureFor(key);
    // A member of another kind with the method's name is reported with the type.
    if (self.properties.contains(key) or declared.parameters.len != 1) return .invalid;
    if (takesSelf(declared, left)) {
        try self.reportWithHelp(
            span,
            "`{s}` cannot be used on values seen as `{s}`",
            .{ lexeme, user.display_name },
            "It runs `{s}`, which takes `Self`: both sides have to be the same type, and a value seen through a trait could be any type that adopts it. Use values whose type is known.",
            .{contract.method},
        );
        return .invalid;
    }
    const signature = try self.signatureOn(declared, left);
    const wanted = signature.parameters[0];
    if (!right.assignableTo(wanted)) {
        try self.reportWithHelp(
            span,
            "`{s}` on {f} needs {f} on the right, but this is {f}",
            .{ lexeme, left, wanted, right },
            "`{s}` runs `{s}(other: {f})`, so both sides are the same type. For anything else, write a method with a name of its own, such as `scaled_by`.",
            .{ lexeme, contract.method, wanted },
        );
    }
    // An operator's operands are left as they are, as they are for numbers.
    if (!isClass(left) and try self.methodChanges(key)) {
        try self.reportWithHelp(
            span,
            "`{s}` cannot run `{s}`, because `{s}` changes the value it runs on",
            .{ lexeme, contract.method, contract.method },
            "An operator leaves its operands as they are. Have `{s}` build and return a new value instead of changing `self`.",
            .{contract.method},
        );
    }
    if (!self.in_function) try self.checkCaptures(span, key, contract.method);
    return signature.return_type;
}

/// Section 6.3's `case` that produces a value. Its type is what its arms
/// agree on, recorded so the interpreter can widen an `Int` arm to `Float`.
fn typeOfCase(self: *Checker, expression: *const Ast.Expression, expected: ?Type) Error!Type {
    const result = try self.checkCase(expression.data.case_expression, expected);
    try self.literal_types.put(self.arena, expression, result);
    return result;
}

/// Section 6.3's `case`, as a statement or a value. Arms are branches, as an
/// `if` chain's are: a subjectless arm knows its own condition held and every
/// earlier one failed, and what follows the `case` is the merge of every arm
/// that can finish, plus skipping them all when no arm has to match.
/// Returns the arms' common type for a `case` that produces a value.
fn checkCase(self: *Checker, case: *const Ast.Case, expected: ?Type) Error!Type {
    const subject: ?Type = if (case.subject) |written| try self.typeOf(written) else null;
    const produces = case.producesValue();

    var covered: std.StringHashMapUnmanaged(void) = .empty;
    var results: std.ArrayList(Type) = .empty;
    var result_spans: std.ArrayList(Source.Span) = .empty;
    const before = try self.snapshot();
    var finishing: std.ArrayList(Snapshot) = .empty;

    for (case.arms, 0..) |arm, position| {
        self.restore(before);
        if (subject == null) {
            for (case.arms[0..position]) |earlier| self.narrow(earlier.alternatives[0], false);
        }
        for (arm.alternatives) |alternative| {
            if (subject) |subject_type| {
                try self.checkAlternative(alternative, subject_type, &covered);
            } else {
                try self.requireCondition(alternative);
                self.narrow(alternative, true);
            }
        }
        if (try self.checkCaseBody(arm.body, expected, &results, &result_spans)) {
            try finishing.append(self.arena, try self.snapshot());
        }
    }

    const coverage = try self.caseCoverage(subject, &covered);
    const exhaustive = case.otherwise != null or coverage.complete;
    if (exhaustive) try self.exhaustive_cases.put(self.arena, case, {});

    self.restore(before);
    if (subject == null) {
        for (case.arms) |arm| self.narrow(arm.alternatives[0], false);
    }
    if (case.otherwise) |otherwise| {
        if (try self.checkCaseBody(otherwise, expected, &results, &result_spans)) {
            try finishing.append(self.arena, try self.snapshot());
        }
    } else if (!exhaustive) {
        // No arm has to match, so skipping them all is a path too.
        try finishing.append(self.arena, try self.snapshot());
    }

    if (finishing.items.len == 0) {
        // Every arm returns or leaves the loop, so nothing after is reachable;
        // see `checkConditional`.
        self.restore(before);
        self.markAllAssigned();
    } else {
        self.restore(finishing.items[0]);
        for (finishing.items[1..]) |path| self.intersect(path);
    }

    if (!produces) return .nothing;
    if (!exhaustive) {
        if (coverage.missing.len > 0) {
            try self.reportWithHelp(
                case.keyword_span,
                "this `case` gives no value for {s}",
                .{coverage.missing},
                "A `case` that produces a value needs one for every possible subject. Add an arm for each, or `else then ...` after the last arm.",
                .{},
            );
        } else {
            try self.report(
                case.keyword_span,
                "this `case` needs an `else`, since its arms cannot cover every value",
                .{},
                "A `case` that produces a value needs one for every possible subject. Add `else then ...` after the last arm.",
            );
        }
    }
    return self.caseResultType(results.items, result_spans.items);
}

/// One arm's block or value. Returns whether running it can carry on past the
/// `case`.
fn checkCaseBody(
    self: *Checker,
    body: Ast.Case.Body,
    expected: ?Type,
    results: *std.ArrayList(Type),
    result_spans: *std.ArrayList(Source.Span),
) Error!bool {
    switch (body) {
        .block => |block| {
            try self.checkBlock(block);
            return self.blockCompletes(block.statements);
        },
        .value => |value| {
            try results.append(self.arena, try self.typeOfExpected(value, expected));
            try result_spans.append(self.arena, value.span);
            return true;
        },
    }
}

/// What a `case`'s value arms agree on. `nothing` in some arms makes the
/// others' type optional, and `Int` and `Float` arms give `Float`.
fn caseResultType(self: *Checker, results: []const Type, spans: []const Source.Span) Error!Type {
    var target: ?Type = null;
    var absent = false;
    for (results) |result| {
        if (result.kind == .invalid) return .invalid;
        if (result.kind == .nothing) {
            absent = true;
            continue;
        }
        const current = target orelse {
            target = result;
            continue;
        };
        if (result.assignableTo(current)) continue;
        if (current.assignableTo(result)) target = result;
    }
    const agreed = target orelse return .nothing;
    for (results, spans) |result, span| {
        if (result.kind == .nothing or result.assignableTo(agreed)) continue;
        try self.reportWithHelp(
            span,
            "this arm gives {f}, but the others give {f}",
            .{ result, agreed },
            "Every arm of a `case` gives the same type of value.",
            .{},
        );
        return .invalid;
    }
    return if (absent) agreed.optionalOf() else agreed;
}

/// One alternative of a `case` with a subject: comparable with the subject by
/// `==`, and not one an earlier arm already matches.
fn checkAlternative(
    self: *Checker,
    alternative: *const Ast.Expression,
    subject: Type,
    covered: *std.StringHashMapUnmanaged(void),
) Error!void {
    const actual = try self.typeOfExpected(alternative, subject);
    if (!equatable(subject, actual)) {
        try self.reportWithHelp(
            alternative.span,
            "`when` compares this with the subject by `==`, but {f} and {f} cannot be compared",
            .{ subject, actual },
            "{s}",
            .{if (isTrait(subject) or isTrait(actual))
                "A struct compares by its fields and an object by identity, and a trait may hold either. Match on a concrete value instead."
            else
                "Each alternative is a value of the subject's type, compared with it by `==`."},
        );
        return;
    }
    const key = try self.knownAlternative(alternative) orelse return;
    if (covered.contains(key)) {
        try self.report(
            alternative.span,
            "an earlier arm already matches this",
            .{},
            "Arms are tried from the top and the first match runs, so this one never could. Remove it.",
        );
        return;
    }
    try covered.put(self.arena, key, {});
}

/// A name for an alternative whose value is known before the program runs,
/// so repeating it can be reported and coverage counted: a literal, `nothing`,
/// or an enum value.
fn knownAlternative(self: *Checker, alternative: *const Ast.Expression) Error!?[]const u8 {
    return switch (alternative.data) {
        .int_literal => |value| try std.fmt.allocPrint(self.arena, "{d}", .{value}),
        .bool_literal => |value| if (value) "true" else "false",
        .nothing_literal => "nothing",
        .string_literal => |text| try std.fmt.allocPrint(self.arena, "\"{s}\"", .{text}),
        .name, .member => blk: {
            const reference = try self.referenceOf(alternative) orelse break :blk null;
            const field = self.type_fields.get(reference.key) orelse break :blk null;
            break :blk if (field.field.enum_value != null) reference.key else null;
        },
        else => null,
    };
}

const Coverage = struct {
    complete: bool,
    /// The values no arm matches, as a reader would list them, when the
    /// subject's values can be listed at all.
    missing: []const u8 = "",
};

/// Section 6.3 and 12: whether the alternatives matched cover every value of
/// an enum or a `Bool` subject, and `nothing` too when it may be absent.
fn caseCoverage(self: *Checker, subject: ?Type, covered: *const std.StringHashMapUnmanaged(void)) Error!Coverage {
    const subject_type = subject orelse return .{ .complete = false };
    var missing: std.ArrayList(u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    const payload = subject_type.payload();
    if (payload.kind == .bool) {
        for ([_][]const u8{ "true", "false" }) |value| {
            if (!covered.contains(value)) try names.append(self.arena, value);
        }
    } else if (payload.kind == .struct_value and payload.user.?.enumeration and !payload.opaque_self) {
        for (self.struct_declarations.get(payload.user.?.name).?.type_fields) |field| {
            if (field.enum_value == null) continue;
            const key = try Resolver.methodKey(self.arena, payload.user.?.name, field.name);
            if (!covered.contains(key)) {
                try names.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ payload.user.?.display_name, field.name }));
            }
        }
    } else {
        return .{ .complete = false };
    }
    if (subject_type.optional and !covered.contains("nothing")) try names.append(self.arena, "nothing");
    for (names.items, 0..) |name, position| {
        if (position > 0) try missing.appendSlice(self.arena, if (position + 1 == names.items.len) " or " else ", ");
        try missing.print(self.arena, "`{s}`", .{name});
    }
    return .{ .complete = names.items.len == 0, .missing = missing.items };
}

/// Whether `==` can compare the two, by the rules `typeOfComparison` applies.
fn equatable(left: Type, right: Type) bool {
    if (left.kind == .invalid or right.kind == .invalid) return true;
    if ((isTrait(left) or isTrait(right)) and !(left.opaque_self and left.same(right))) return false;
    return (left.isNumber() and right.isNumber()) or left.same(right) or
        comparableOptional(left, right) or relatedClasses(left, right);
}

fn typeOfLogical(self: *Checker, logical: Ast.Expression.Logical) Error!Type {
    try self.requireCondition(logical.left);
    // Section 4.5: the right side runs only when the left one held, for
    // `and`, or failed, for `or`, so it is checked knowing which.
    const before = try self.snapshot();
    self.narrow(logical.left, logical.operator == .conjunction);
    try self.requireCondition(logical.right);
    self.restoreTypes(before);
    return .bool;
}

/// A comparison chain yields a `Bool`, and every adjacent pair has to be
/// comparable. Section 4.4 allows a mixed `Int`/`Float` comparison, which is why
/// this asks whether the pair is numeric rather than whether the types match.
///
/// Equality needs two values of the same type. Order needs numbers: `true <
/// false` has no meaning a reader would guess, so it is rejected rather than
/// given one.
fn typeOfComparison(self: *Checker, comparison: Ast.Expression.Comparison) Error!Type {
    // Everything but list literals first, so that `scores == []` and `[] ==
    // scores` can both give the literal its element type from the other side.
    const operand_types = try self.arena.alloc(Type, comparison.operands.len);
    for (comparison.operands, operand_types) |operand, *operand_type| {
        if (operand.data != .list_literal) operand_type.* = try self.typeOf(operand);
    }
    for (comparison.operands, operand_types, 0..) |operand, *operand_type, position| {
        if (operand.data != .list_literal) continue;
        const neighbor: ?Type = if (position > 0 and comparison.operands[position - 1].data != .list_literal)
            operand_types[position - 1]
        else if (position + 1 < comparison.operands.len and comparison.operands[position + 1].data != .list_literal)
            operand_types[position + 1]
        else
            null;
        operand_type.* = try self.typeOfList(operand, neighbor);
    }

    var left_node = comparison.operands[0];
    var left = operand_types[0];

    for (comparison.operators, comparison.operands[1..], operand_types[1..]) |operator, operand_node, right| {
        // The pair is the problem, so both sides are underlined.
        const pair: Source.Span = .{ .start = left_node.span.start, .end = operand_node.span.end };
        const numeric = left.isNumber() and right.isNumber();
        const unknown = left.kind == .invalid or right.kind == .invalid;

        if (!unknown and !operator.isEquality() and left.kind == .struct_value and !left.optional) {
            // Section 11.5: ordering a user type runs its `compare`.
            _ = try self.typeOfOperatorCall(pair, operator.lexeme(), .ordered, left_node, left, right);
        } else if (!unknown and (isTrait(left) or isTrait(right)) and !(left.opaque_self and left.same(right))) {
            try self.report(
                pair,
                "values seen through a trait cannot be compared yet",
                .{},
                "A struct compares by its fields and an object by identity, and a trait may hold either. Compare the concrete values instead.",
            );
        } else if (!unknown and !numeric and !left.same(right) and !comparableOptional(left, right) and !relatedClasses(left, right)) {
            try self.report(
                pair,
                "{f} and {f} cannot be compared",
                .{ left, right },
                if (isClass(left.payload()) and isClass(right.payload()))
                    "Two objects can be compared only when one's class is the other's or extends it, since only then can they be the same object."
                else
                    "`==` and `!=` compare two values of the same type, and Int and Float compare with each other.",
            );
        } else if (!unknown and !numeric and !operator.isEquality() and
            !(left.kind == .string and !left.optional and !right.optional))
        {
            try self.report(
                pair,
                "`{s}` needs numbers, but these are {f} values",
                .{ operator.lexeme(), left },
                "Only numbers are ordered. Use `==` or `!=` to compare other values.",
            );
        }
        left = right;
        left_node = operand_node;
    }

    return .bool;
}

/// Section 4.5: a value that may be absent is compared against `nothing` to
/// find out, which is the test narrowing reads. Two optionals of the same shape
/// compare as well, and an optional compares against a present value of its own
/// type, which is how `maybe == 5` asks whether it is there and is that.
///
/// Ordering is not included: `<` on something that may be absent has no answer,
/// so it stays rejected.
/// Section 10.1: "Class values may be compared when their static types have an
/// inheritance relationship", since both may be the same object.
fn relatedClasses(left: Type, right: Type) bool {
    const a = left.payload();
    const b = right.payload();
    if (a.kind != .struct_value or b.kind != .struct_value or !a.user.?.class) return false;
    return a.user.?.extends(b.user.?) or b.user.?.extends(a.user.?);
}

fn comparableOptional(left: Type, right: Type) bool {
    if (!left.optional and !right.optional) return false;
    if (left.kind == .nothing or right.kind == .nothing) return true;
    if (left.payload().isNumber() and right.payload().isNumber()) return true;
    return left.payload().same(right.payload());
}

fn typeOfCall(
    self: *Checker,
    expression: *const Ast.Expression,
    call: Ast.Expression.Call,
) Error!Type {
    if (isCounting(expression)) return self.rejectCountingValue(expression);
    if (isSuper(call.callee)) return self.typeOfSuperCall(expression, call);

    // `Shapes.area(3)` calls a declaration; `text.upper()` calls a method. The
    // resolver already decided which this is.
    const reference = try self.referenceOf(call.callee) orelse {
        // A tuple position holding a block is called through its value, not as
        // a method of the tuple.
        if (call.callee.data == .member and call.callee.data.member.position == null) {
            return self.typeOfMethodCall(expression, call, call.callee.data.member);
        }
        // Anything that is not a plain name — a lambda called where it is
        // written, an element of a list of functions — is called through its
        // value.
        return self.typeOfValueCall(call, try self.typeOf(call.callee), null);
    };

    const name = reference.display;
    if (self.receivers.get(reference.key)) |receiver| {
        if (receiver.user.?.trait) return self.typeOfTraitDefaultCall(expression, call, reference);
    }
    // A bare name is looked up the way a read finds it, so a local — a nested
    // function (7.1), or a variable holding a block — hides a module-level name
    // even when `using` gave that name a key of its own.
    const found = if (call.callee.data == .name) self.find(name) else self.findKey(reference.key);
    const binding = found orelse {
        try self.typeArguments(call.arguments);
        return .invalid;
    };
    if (try self.reportPrivateTypeMember(reference.key, call.callee.span)) {
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    if (binding.is_type) {
        if (!self.in_function) try self.checkCaptures(expression.span, reference.key, name);
        const declaration = self.struct_declarations.get(reference.key).?;
        if (declaration.trait) {
            try self.reportWithHelp(
                call.callee.span,
                "`{s}` is a trait, so it cannot be constructed",
                .{name},
                "A trait is a contract. Construct a struct or class that adopts `{s}` instead.",
                .{binding.type.user.?.display_name},
            );
            try self.typeArguments(call.arguments);
            return .invalid;
        }
        if (declaration.enumeration) {
            try self.reportWithHelp(
                call.callee.span,
                "`{s}` is an enum, so it cannot be constructed",
                .{name},
                "Its values are the ones it lists. Write one of them, such as `{s}.{s}`.",
                .{ name, declaration.type_fields[0].name },
            );
            try self.typeArguments(call.arguments);
            return binding.type;
        }
        if (declaration.abstract_span != null) {
            try self.reportWithHelp(
                call.callee.span,
                "`{s}` is abstract, so it cannot be constructed",
                .{name},
                "An abstract class is only a base for other classes. Construct one of the classes that extend `{s}` instead.",
                .{binding.type.user.?.display_name},
            );
            try self.typeArguments(call.arguments);
            return binding.type;
        }
        try self.checkConstruction(call, reference.key, name);
        return binding.type;
    }

    // A variable holding a function is called through its value, which is how
    // a parameter or a local that received a lambda is used.
    if (!binding.is_function) return self.typeOfValueCall(call, binding.type, name);

    const key = binding.function_key orelse reference.key;
    if (binding.function_key != null) try self.checkNestedUse(call.callee);

    // A prelude function. Section 15.2's `print` and `write` accept any number
    // of values and have no result; `input` takes an optional prompt.
    if (!self.declarations.contains(key)) {
        if (try self.rejectNames(call)) {
            try self.typeArguments(call.arguments);
            return .invalid;
        }
        if (std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "input_maybe")) {
            return self.typeOfInput(call, name);
        }
        try self.typeArguments(call.arguments);
        return .nothing;
    }

    const signature = try self.signatureFor(key);
    try self.checkArguments(call, name, try self.parametersOf(
        signature,
        self.declarations.get(key).?.parameters,
        "Match the number of arguments to the function's parameters.",
    ));

    if (!self.in_function) try self.checkCaptures(expression.span, key, name);
    return signature.return_type;
}

/// The arguments of a call that builds a value of the type `key`: calling the
/// type, or a subclass's `super(...)`. `name` is the type as written there.
fn checkConstruction(self: *Checker, call: Ast.Expression.Call, key: []const u8, name: []const u8) Error!void {
    const built = self.structs.get(key).?;
    // Section 10.2: a custom constructor replaces the generated one, so its
    // parameters are what a call must match.
    if (self.constructors.contains(key)) {
        const constructor = self.constructors.get(key).?.constructor.?;
        try self.checkArguments(call, name, try self.parametersOf(
            try self.constructorSignature(key),
            constructor.parameters,
            "Match the number of arguments to the constructor's parameters.",
        ));
        return;
    }
    const declaration = self.struct_declarations.get(key).?;
    // Section 10.2: a subclass without a constructor of its own gets one only
    // when nothing needs an argument, and it takes none.
    if (built.user.?.base != null) {
        if (call.arguments.len > 0) {
            try self.reportWithHelp(
                call.callee.span,
                "`{s}` takes no arguments, but this call passes {d}",
                .{ name, call.arguments.len },
                "A class that extends another has no generated constructor to take its fields. Give `{s}` a constructor of its own to take these values.",
                .{built.user.?.display_name},
            );
            try self.typeArguments(call.arguments);
        }
        return;
    }
    const fields = built.user.?.fields;
    // Section 10.5: outside the type, the generated constructor cannot set a
    // private field, so one without a default leaves no way to build the value
    // there.
    const outside = !self.insideType(key, call.callee.span);
    if (outside) for (declaration.fields) |field| {
        if (!Resolver.isPrivate(field.name) or field.default != null) continue;
        try self.reportWithHelp(
            call.callee.span,
            "`{s}` cannot be built here, because its field `{s}` is private and has no default",
            .{ name, field.name },
            "Give `{s}` a default, or give `{s}` a constructor that sets it.",
            .{ field.name, built.user.?.display_name },
        );
        try self.typeArguments(call.arguments);
        return;
    };
    if (fields.len == 0 and call.arguments.len > 0) {
        try self.report(
            call.callee.span,
            "`{s}` takes no arguments, but this call passes {d}",
            .{ name, call.arguments.len },
            "A type without fields has a generated constructor that takes no arguments.",
        );
        try self.typeArguments(call.arguments);
        return;
    }
    const types = try self.arena.alloc(Type, fields.len);
    const names = try self.arena.alloc([]const u8, fields.len);
    const defaults = try self.arena.alloc(bool, fields.len);
    var any_default = false;
    for (fields, declaration.fields, types, names, defaults) |field, written, *t, *n, *d| {
        t.* = field.type;
        n.* = field.name;
        d.* = written.default != null;
        any_default = any_default or d.*;
    }
    try self.checkArguments(call, name, .{
        .types = types,
        .names = names,
        .has_default = defaults,
        .noun = "field",
        .private_to = if (outside) built.user.?.display_name else null,
        .mismatch_help = "Pass a value of the field's declared type, or convert it first.",
        .arity_help = if (any_default)
            "Pass a value for each field without a default, in declaration order, or name the fields you pass."
        else
            "Pass one value for each required field, in declaration order.",
    });
}

fn isSelf(expression: *const Ast.Expression) bool {
    return expression.data == .name and std.mem.eql(u8, expression.data.name, "self");
}

/// The correction for a member a class does not have: when a class extending
/// it does, how `is` reaches it (4.4), and for a name that cannot be narrowed,
/// why not.
fn subclassMemberHelp(self: *Checker, base: Type, member: Ast.Expression.Member, general: []const u8) Error![]const u8 {
    if (!isClass(base)) return general;
    // The first declared, so the correction does not depend on hash order.
    var found: ?*const Type.User = null;
    var types = self.structs.valueIterator();
    while (types.next()) |candidate| {
        const user = candidate.user.?;
        if (user == base.user.? or !user.extends(base.user.?)) continue;
        const key = try self.memberOwner(candidate.*, member.name) orelse continue;
        if (!std.mem.eql(u8, key, user.name)) continue;
        if (found) |earlier| {
            const a = .{ self.facts.owner.get(user.name).?, self.type_spans.get(user.name).?.start };
            const b = .{ self.facts.owner.get(earlier.name).?, self.type_spans.get(earlier.name).?.start };
            if (a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])) continue;
        }
        found = user;
    }
    const owner = found orelse return general;
    const written = if (member.base.data == .name) member.base.data.name else "value";
    if (member.base.data == .name) {
        if (self.unprovable(written)) |reason| {
            return std.fmt.allocPrint(
                self.arena,
                "`{s}` belongs to `{s}`, which extends {f}. A test such as `{s} is {s}` cannot prove what `{s}` holds, because {s} assigns it and could change it in between. Copy it into a `const` first, and test that.",
                .{ member.name, owner.display_name, base, written, owner.display_name, written, reason },
            );
        }
    }
    return std.fmt.allocPrint(
        self.arena,
        "`{s}` belongs to `{s}`, which extends {f}. Inside `if {s} is {s} {{ ... }}`, it can be reached.",
        .{ member.name, owner.display_name, base, written, owner.display_name },
    );
}

/// Section 11.2's `Named.introduction(self)`, which runs that trait's own
/// default on a value adopting the trait, passed first.
fn typeOfTraitDefaultCall(self: *Checker, expression: *const Ast.Expression, call: Ast.Expression.Call, reference: Reference) Error!Type {
    const receiver = self.receivers.get(reference.key).?;
    const declaration = self.declarations.get(reference.key).?;
    if (self.properties.contains(reference.key) or declaration.abstract_span != null) {
        try self.reportWithHelp(
            call.callee.span,
            "`{s}` has no default to run",
            .{reference.display},
            "`{s}` is a requirement, with no body in the trait. Call it on a value instead, as in `value.{s}()`.",
            .{ declaration.name, declaration.name },
        );
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    const signature = try self.signatureFor(reference.key);
    if ((try Type.functionOf(self.arena, signature)).mentionsSelf()) {
        try self.reportWithHelp(
            call.callee.span,
            "`{s}` uses `Self`, so it cannot be called this way yet",
            .{reference.display},
            "Call it as a method instead, as in `value.{s}()`.",
            .{declaration.name},
        );
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    const types = try self.arena.alloc(Type, signature.parameters.len + 1);
    const names = try self.arena.alloc([]const u8, signature.parameters.len + 1);
    const defaults = try self.arena.alloc(bool, signature.parameters.len + 1);
    types[0] = receiver;
    names[0] = "self";
    defaults[0] = false;
    @memcpy(types[1..], signature.parameters);
    @memcpy(names[1..], signature.parameter_names);
    for (declaration.parameters, defaults[1..]) |parameter, *has| has.* = parameter.default != null;
    try self.checkArguments(call, reference.display, .{
        .types = types,
        .names = names,
        .has_default = defaults,
        .arity_help = "Pass the value to run it on first, then the method's own arguments.",
    });
    if (call.arguments.len > 0 and try self.methodChanges(reference.key)) {
        const first = try self.typeOf(call.arguments[0]);
        if (!isClass(first)) {
            try self.reportWithHelp(
                call.callee.span,
                "`{s}` changes the value it runs on, so it cannot be called this way yet",
                .{reference.display},
                "Call it as a method instead, as in `value.{s}()`.",
                .{declaration.name},
            );
        }
    }
    try self.trait_calls.put(self.arena, expression, reference.key);
    if (!self.in_function) try self.checkCaptures(expression.span, reference.key, reference.display);
    return signature.return_type;
}

/// Whether an expression is section 10.7's `super`.
fn isSuper(expression: *const Ast.Expression) bool {
    return expression.data == .name and std.mem.eql(u8, expression.data.name, "super");
}

/// `super`, as the receiver of `super.name`: the object, seen as its base
/// class. The parser has already said where it may be written.
fn typeOfSuper(self: *Checker, span: Source.Span) Error!Type {
    const receiver = self.find("self") orelse return .invalid;
    if (receiver.type.kind != .struct_value) return .invalid;
    const base = receiver.type.user.?.base orelse return .invalid;
    if (self.constructing != null) {
        if (try self.firstUnsetField()) |field| {
            if (!try self.reportInDefault(span, "use `super`")) try self.reportWithHelp(
                span,
                "`super` cannot be used until every field of `self` is set",
                .{},
                "Set `self.{s}` first. The base class's version may run code that reads any field.",
                .{field},
            );
            for (self.constructing.?.type.user.?.fields) |each| {
                (try self.fieldSetBinding(each.name)).?.assigned = true;
            }
        }
    }
    return Type.structOf(base);
}

/// `super.area()` where the base class leaves `area` abstract, so there is no
/// version of it there to run. Returns whether it reported.
fn reportAbstractThroughSuper(self: *Checker, member: Ast.Expression.Member, key: []const u8) Error!bool {
    if (!isSuper(member.base)) return false;
    const declaration = self.declarations.get(key) orelse return false;
    if (declaration.abstract_span == null) return false;
    const owner = self.receivers.get(key).?.user.?.display_name;
    try self.reportWithHelp(
        member.name_span,
        "`{s}` is abstract in `{s}`, so there is no version of it for `super` to reach",
        .{ member.name, owner },
        "Call it through `self` to run this class's version, or give `{s}` a body in `{s}`.",
        .{ member.name, owner },
    );
    return true;
}

/// Section 10.2's `super(...)`, which builds the base class's part of the
/// object. It is allowed only as the first statement of a constructor.
fn typeOfSuperCall(self: *Checker, expression: *const Ast.Expression, call: Ast.Expression.Call) Error!Type {
    const building = self.constructing orelse {
        try self.report(
            call.callee.span,
            "`super(...)` can only begin a constructor",
            .{},
            "It builds the base class's part of a new object, which only a constructor does. To run the base class's version of a method, write `super.name(...)`.",
        );
        try self.typeArguments(call.arguments);
        return .nothing;
    };
    if (building.super_call != expression) {
        try self.report(
            call.callee.span,
            "`super(...)` can only begin a constructor",
            .{},
            "Move it to the first line of the constructor, so the base class's part of the object is built before anything else runs.",
        );
        try self.typeArguments(call.arguments);
        return .nothing;
    }
    const user = building.type.user.?;
    const base = user.base orelse {
        try self.typeArguments(call.arguments);
        return .nothing;
    };
    try self.checkConstruction(call, base.name, base.display_name);
    // The base class's part is built: every inherited field is set.
    for (user.fields[0..user.inherited]) |field| {
        (try self.fieldSetBinding(field.name)).?.assigned = true;
        self.find(try fieldUnsetKey(self.arena, field.name)).?.assigned = false;
    }
    return .nothing;
}

/// Whether a constructor body starts with `super(...)`, and if so that call.
fn superCallOf(statements: []const Ast.Statement) ?*const Ast.Expression {
    if (statements.len == 0 or statements[0].data != .expression) return null;
    const expression = statements[0].data.expression;
    if (expression.data != .call or !isSuper(expression.data.call.callee)) return null;
    return expression;
}

/// What a call by name is matched against (7.3).
const Parameters = struct {
    types: []const Type,
    names: []const []const u8,
    has_default: []const bool,
    /// What one of them is called in a diagnostic.
    noun: []const u8 = "parameter",
    arity_help: []const u8,
    mismatch_help: []const u8 = "Pass a value of the expected type, or convert it first.",
    /// The type whose private fields a generated constructor called from
    /// outside it may not be given (10.5).
    private_to: ?[]const u8 = null,
};

fn parametersOf(self: *Checker, signature: Signature, written: []const Ast.Parameter, arity_help: []const u8) Error!Parameters {
    const defaults = try self.arena.alloc(bool, written.len);
    for (written, defaults) |parameter, *has| has.* = parameter.default != null;
    return .{
        .types = signature.parameters,
        .names = signature.parameter_names,
        .has_default = defaults,
        .arity_help = arity_help,
    };
}

/// A call to a named declaration with parameter names: a function, a method, or
/// a type, whether its constructor is generated or its own.
fn checkArguments(
    self: *Checker,
    call: Ast.Expression.Call,
    name: []const u8,
    parameters: Parameters,
) Error!void {
    const bound = try self.arena.alloc(?usize, parameters.names.len);
    const any_default = std.mem.indexOfScalar(bool, parameters.has_default, true) != null;
    // A method's own name, not the whole receiver in front of it, which other
    // diagnostics about a method call already point at the same way.
    const callee_span = if (call.callee.data == .member and !self.facts.qualified.contains(call.callee))
        call.callee.data.member.name_span
    else
        call.callee.span;
    const problem = call_arguments.bind(call, parameters.names, parameters.has_default, bound);
    switch (problem) {
        .none => {},
        .too_many => {
            const expected = parameters.names.len;
            try self.report(
                callee_span,
                "`{s}` takes {s}{d} argument{s}, but this call passes {d}",
                .{ name, if (any_default) "at most " else "", expected, if (expected == 1) "" else "s", call.arguments.len },
                parameters.arity_help,
            );
        },
        .missing => |position| if (call.names.len == 0 and !any_default) {
            const expected = parameters.names.len;
            try self.report(
                callee_span,
                "`{s}` takes {d} argument{s}, but this call passes {d}",
                .{ name, expected, if (expected == 1) "" else "s", call.arguments.len },
                parameters.arity_help,
            );
        } else {
            try self.reportWithHelp(
                callee_span,
                "this call gives `{s}` no value for {s} `{s}`",
                .{ name, parameters.noun, parameters.names[position] },
                "{s}",
                .{if (position + 1 == parameters.names.len and parameters.types[position].kind == .function)
                    try std.fmt.allocPrint(self.arena, "Pass it as a block after the parentheses, or by name as `{s}: ...`.", .{parameters.names[position]})
                else
                    try std.fmt.allocPrint(self.arena, "Pass it by position, or by name as `{s}: ...`.", .{parameters.names[position]})},
            );
        },
        .unknown_name => |index| try self.reportWithHelp(
            call.names[index].?.span,
            "`{s}` has no {s} named `{s}`",
            .{ name, parameters.noun, call.names[index].?.text },
            "{s}",
            .{if (parameters.names.len == 0) "It takes no arguments." else "Check the spelling against the declaration."},
        ),
        .trailing_duplicate => |position| try self.reportWithHelp(
            call.arguments[call.arguments.len - 1].span,
            "the trailing block gives `{s}` a second value",
            .{parameters.names[position]},
            "A block after the parentheses is `{s}`. Remove `{s}:` from inside them, or pass the block there instead.",
            .{ parameters.names[position], parameters.names[position] },
        ),
        .duplicate => |index| try self.report(
            call.names[index].?.span,
            "`{s}` already has a value in this call",
            .{call.names[index].?.text},
            "Pass each value once.",
        ),
        .positional_after_named => |index| try self.report(
            call.arguments[index].span,
            "a value without a name cannot follow a named one",
            .{},
            "Put the values passed by position first, in order, and the named ones after them.",
        ),
    }
    if (problem != .none) return self.typeArguments(call.arguments);

    for (bound, parameters.types, parameters.names) |argument_index, expected, parameter_name| {
        const argument = call.arguments[argument_index orelse continue];
        if (parameters.private_to) |owner| if (Resolver.isPrivate(parameter_name)) {
            const named = if (argument_index.? < call.names.len) call.names[argument_index.?] else null;
            const written = if (named) |label| label.span else argument.span;
            try self.reportWithHelp(
                written,
                "`{s}` is private to `{s}`, so this call cannot set it",
                .{ parameter_name, owner },
                "Leave it to its default, passing any fields after it by name, or give `{s}` a constructor that takes this value.",
                .{owner},
            );
            _ = try self.typeOf(argument);
            continue;
        };
        const actual = try self.typeOfExpected(argument, expected);
        if (!actual.assignableTo(expected)) {
            try self.report(
                argument.span,
                "this is {f}, but {s} `{s}` of `{s}` needs {f}",
                .{ actual, parameters.noun, parameter_name, name, expected },
                mismatchHelp(actual, expected, parameters.mismatch_help),
            );
        }
    }
}

/// Section 7.3's names belong to a declaration's parameters, so a call through
/// a value, to the prelude, or to a built-in method has none to match.
/// Returns whether it reported.
fn rejectNames(self: *Checker, call: Ast.Expression.Call) Error!bool {
    for (call.names) |maybe| {
        const name = maybe orelse continue;
        try self.report(
            name.span,
            "a named argument needs a function, method, or type called by its own name",
            .{},
            "Pass this value by position instead.",
        );
        return true;
    }
    return false;
}

/// A call through a value rather than a name: section 7.4's lambdas and
/// section 7.5's captured functions, once either is stored somewhere.
///
/// `name` is the binding the value came from, when it came from one, so the
/// diagnostic can say which name is not a function.
fn typeOfValueCall(self: *Checker, call: Ast.Expression.Call, callee: Type, name: ?[]const u8) Error!Type {
    if (try self.rejectNames(call) or callee.kind == .invalid) {
        try self.typeArguments(call.arguments);
        return .invalid;
    }
    if (callee.kind != .function) {
        if (name) |written| {
            try self.report(
                call.callee.span,
                "`{s}` is {f}, which is not a function",
                .{ written, callee },
                "Only a function can be called.",
            );
        } else {
            try self.report(
                call.callee.span,
                "this is {f}, which is not a function",
                .{callee},
                "Only a function can be called.",
            );
        }
        try self.typeArguments(call.arguments);
        return .invalid;
    }

    const signature = callee.signature.?;
    if (call.arguments.len != signature.parameters.len) {
        const expected = signature.parameters.len;
        const plural = if (expected == 1) "" else "s";
        if (name) |written| {
            try self.report(
                call.callee.span,
                "`{s}` takes {d} argument{s}, but this call passes {d}",
                .{ written, expected, plural, call.arguments.len },
                "Match the number of arguments to what the function takes.",
            );
        } else {
            try self.report(
                call.callee.span,
                "this takes {d} argument{s}, but this call passes {d}",
                .{ expected, plural, call.arguments.len },
                "Match the number of arguments to what the function takes.",
            );
        }
        try self.typeArguments(call.arguments);
        return signature.return_type;
    }

    for (call.arguments, signature.parameters) |argument, expected| {
        const actual = try self.typeOfExpected(argument, expected);
        if (actual.assignableTo(expected)) continue;
        try self.report(
            argument.span,
            "this is {f}, but {f} is expected here",
            .{ actual, expected },
            mismatchHelp(actual, expected, "Pass a value of the expected type, or convert it first."),
        );
    }
    return signature.return_type;
}

/// Section 15.2's `input(prompt)`: the prompt is optional and is a String.
fn typeOfInput(self: *Checker, call: Ast.Expression.Call, name: []const u8) Error!Type {
    if (call.arguments.len > 1) {
        try self.report(
            call.callee.span,
            "`{s}` takes at most 1 argument, but this call passes {d}",
            .{ name, call.arguments.len },
            "Pass the prompt as one String, as in `input(\"What is your name? \")`.",
        );
        try self.typeArguments(call.arguments);
    } else if (call.arguments.len == 1) {
        const prompt = try self.typeOf(call.arguments[0]);
        if (prompt.kind != .string and prompt.kind != .invalid) {
            try self.report(
                call.arguments[0].span,
                "the prompt is {f}, but `{s}` needs a String",
                .{ prompt, name },
                "Write the prompt as text, as in `input(\"How old are you? \")`.",
            );
        }
    }
    // Section 15.2: `input` raises at the end of the input, while
    // `input_maybe` reports it as absence, which is what makes reading until
    // the input runs out writable.
    return if (std.mem.eql(u8, name, "input_maybe")) Type.string.optionalOf() else .string;
}

/// Types the arguments of a call that has already been reported, so that
/// mistakes inside them are still found. They are typed against `invalid`,
/// which says the context is gone: a block, which would otherwise ask for its
/// parameter types, takes that as already answered rather than reporting a
/// second time.
fn typeArguments(self: *Checker, arguments: []const *const Ast.Expression) Error!void {
    for (arguments) |argument| _ = try self.typeOfExpected(argument, .invalid);
}

// Control-flow shape, computed from the AST alone.

/// Whether control can reach the end of a block, rather than leaving it
/// through `return`, `break`, or `continue`, or looping forever. Once one
/// statement cannot complete, nothing after it runs.
fn blockCompletes(self: *const Checker, statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        if (!self.stmtCompletes(statement)) return false;
    }
    return true;
}

fn stmtCompletes(self: *const Checker, statement: Ast.Statement) bool {
    return switch (statement.data) {
        .return_statement, .break_statement, .continue_statement => false,
        .destructuring, .destructuring_assignment => true,
        .conditional => |conditional| blk: {
            if (self.blockCompletes(conditional.then_block.statements)) break :blk true;
            const otherwise = conditional.otherwise orelse break :blk true;
            break :blk switch (otherwise) {
                .block => |block| self.blockCompletes(block.statements),
                .chained => |chained| self.stmtCompletes(chained.*),
            };
        },
        // Only a `break` ends `while true`. Any other loop can end on its own.
        .while_loop => |loop| !isLiteralTrue(loop.condition) or self.blockBreaks(loop.body.statements),
        .for_loop, .expression, .declaration, .assignment, .function_declaration, .struct_declaration => true,
        // A `case` that may match nothing carries on past it; one that covers
        // everything carries on only through an arm that does.
        .case_statement => |case| blk: {
            if (!self.exhaustive_cases.contains(case)) break :blk true;
            for (case.arms) |arm| {
                if (self.blockCompletes(arm.body.block.statements)) break :blk true;
            }
            const otherwise = case.otherwise orelse break :blk false;
            break :blk self.blockCompletes(otherwise.block.statements);
        },
    };
}

/// Whether a block contains a `break` belonging to the loop it is the body of.
/// A `break` inside a nested loop belongs to that loop instead.
fn blockBreaks(self: *const Checker, statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        if (self.stmtBreaks(statement)) return true;
    }
    return false;
}

fn stmtBreaks(self: *const Checker, statement: Ast.Statement) bool {
    return switch (statement.data) {
        .break_statement => true,
        .conditional => |conditional| blk: {
            if (self.blockBreaks(conditional.then_block.statements)) break :blk true;
            const otherwise = conditional.otherwise orelse break :blk false;
            break :blk switch (otherwise) {
                .block => |block| self.blockBreaks(block.statements),
                .chained => |chained| self.stmtBreaks(chained.*),
            };
        },
        .while_loop, .for_loop, .return_statement, .continue_statement => false,
        .destructuring, .destructuring_assignment => false,
        .expression, .declaration, .assignment, .function_declaration, .struct_declaration => false,
        .case_statement => |case| blk: {
            for (case.arms) |arm| {
                if (self.blockBreaks(arm.body.block.statements)) break :blk true;
            }
            const otherwise = case.otherwise orelse break :blk false;
            break :blk self.blockBreaks(otherwise.block.statements);
        },
    };
}

/// `while true`, written literally. Nothing subtler is recognized, so the rule
/// stays one a reader can apply by eye.
fn isLiteralTrue(expression: *const Ast.Expression) bool {
    return expression.data == .bool_literal and expression.data.bool_literal;
}

/// Whether a body contains a `return` carrying a value anywhere, which decides
/// whether a function without an annotation has anything to infer.
fn blockHasValueReturn(self: *const Checker, statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        if (self.statementHasValueReturn(statement)) return true;
    }
    return false;
}

fn statementHasValueReturn(self: *const Checker, statement: Ast.Statement) bool {
    return switch (statement.data) {
        .return_statement => |return_statement| return_statement.value != null,
        .conditional => |conditional| blk: {
            if (self.blockHasValueReturn(conditional.then_block.statements)) break :blk true;
            const otherwise = conditional.otherwise orelse break :blk false;
            break :blk switch (otherwise) {
                .block => |block| self.blockHasValueReturn(block.statements),
                .chained => |chained| self.statementHasValueReturn(chained.*),
            };
        },
        .while_loop => |loop| self.blockHasValueReturn(loop.body.statements),
        .for_loop => |loop| self.blockHasValueReturn(loop.body.statements),
        .destructuring, .destructuring_assignment => false,
        .expression, .declaration, .assignment, .function_declaration, .struct_declaration => false,
        .break_statement, .continue_statement => false,
        .case_statement => |case| blk: {
            for (case.arms) |arm| {
                if (self.blockHasValueReturn(arm.body.block.statements)) break :blk true;
            }
            const otherwise = case.otherwise orelse break :blk false;
            break :blk self.blockHasValueReturn(otherwise.block.statements);
        },
    };
}
