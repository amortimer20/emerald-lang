//! Lowering: the checked syntax tree to the IR (docs/compiler-design-plan.md,
//! decision 3). The checker has proved the program well typed, so this only
//! decides how each construct runs: which operations, in which blocks, with
//! which checks. Types come from the checker's `expression_types`.
//!
//! What the compiler cannot compile yet stops lowering with `Unsupported`,
//! naming the construct and where it is, so `emerald build` can say so plainly
//! rather than produce a program that behaves differently. Each slice of the
//! plan shrinks what that covers.

const std = @import("std");
const Ast = @import("../Ast.zig");
const Source = @import("../Source.zig");
const Type = @import("../Type.zig");
const Checker = @import("../Checker.zig");
const Resolver = @import("../Resolver.zig");
const Ir = @import("Ir.zig");
const Arithmetic = @import("runtime").Operations.Arithmetic;
const Natives = @import("runtime").Natives;
const ListMethods = @import("runtime").ListMethods;
const MapMethods = @import("runtime").MapMethods;
const call_arguments = @import("../arguments.zig");

const Lower = @This();

arena: std.mem.Allocator,
source: *const Source,
file: u32,
checked: *const Checker.Checked,
facts: *const Resolver.Facts,
functions: std.ArrayList(Ir.Function) = .empty,
function_keys: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
globals: std.ArrayList(Ir.Global) = .empty,
global_keys: std.StringHashMapUnmanaged(Ir.GlobalIndex) = .empty,
sites: std.ArrayList(Source.Span) = .empty,
literals: std.ArrayList([]const u8) = .empty,
/// The element type of each module-level list variable, by key, for an
/// assignment into one of its elements.
global_elements: std.StringHashMapUnmanaged(Ir.Type) = .empty,
/// The checker's type of each module variable whose type is known.
global_checked: std.AutoHashMapUnmanaged(Ir.GlobalIndex, Type) = .empty,
/// The struct type of each module-level struct variable, by its index.
global_structs: std.AutoHashMapUnmanaged(Ir.GlobalIndex, *StructInfo) = .empty,
/// The payload type of each module-level optional variable, by its index.
global_payloads: std.AutoHashMapUnmanaged(Ir.GlobalIndex, Ir.Type) = .empty,
/// Each struct type the program declares, by key.
struct_infos: std.StringHashMapUnmanaged(*StructInfo) = .empty,
struct_types: std.ArrayList(Ir.StructType) = .empty,
/// Each struct method, by its method key (`Point::area`).
methods: std.StringHashMapUnmanaged(MethodInfo) = .empty,
/// The spans of every function and type declaration, where a changing
/// method's receiver could be read behind its back.
bodies: std.ArrayList(Source.Span) = .empty,
/// What stopped lowering, once something has.
unsupported: ?Unsupported = null,

pub const Unsupported = struct {
    span: Source.Span,
    /// What cannot be compiled yet, as a phrase: "a list", "a nested function".
    what: []const u8,
};

pub const Error = error{ OutOfMemory, Unsupported };

const StructInfo = struct {
    key: []const u8,
    index: u32,
    declaration: Ast.StructDeclaration,
    fields: []FieldInfo,
    field_names: []const []const u8,
    has_default: []const bool,
    any_default: bool,
    /// The function that runs the field defaults, given a flag per field.
    defaults: ?FunctionInfo = null,
    constructor: ?FunctionInfo = null,
};

const FieldInfo = struct {
    name: []const u8,
    type: Ir.Type,
    payload: ?Ir.Type,
    element: ?Ir.Type,
};

const MethodInfo = struct {
    function: FunctionInfo,
    /// Section 4.3's changing method, which takes `self` by reference.
    changing: bool,
    declaration: Ast.FunctionDeclaration,
    owner: *StructInfo,
};

const FunctionInfo = struct {
    index: Ir.FunctionIndex,
    parameters: []const Ir.Type,
    /// For each parameter that is a list, its element type.
    elements: []const ?Ir.Type,
    /// For each optional parameter, its payload type, and the result's.
    payloads: []const ?Ir.Type,
    result_payload: ?Ir.Type,
    result: Ir.Type,
    /// The parameters' names, for binding named arguments.
    names: []const []const u8 = &.{},
};

/// Lowers the entry file `file` of a checked project. On `error.Unsupported`,
/// `unsupported` says what and where.
pub fn lower(self: *Lower, program: Ast.Program) Error!Ir.Program {
    // Functions first, so a call can come before the function it calls, and
    // module-level variables, which any function may read.
    try self.functions.append(self.arena, undefined); // the entry, built last
    // Struct names first, so any signature or field can name one.
    for (program.statements) |statement| switch (statement.data) {
        .struct_declaration => |declared| try self.nameStruct(declared),
        .function_declaration => try self.bodies.append(self.arena, statement.span),
        else => {},
    };
    for (program.statements) |statement| {
        if (statement.data == .struct_declaration) {
            try self.bodies.append(self.arena, statement.span);
            try self.declareStruct(statement.data.struct_declaration);
        }
    }
    for (program.statements) |statement| switch (statement.data) {
        .function_declaration => |function| try self.declareFunction(function),
        .declaration => |declaration| try self.declareGlobal(declaration),
        .destructuring => |destructured| try self.declareDestructured(destructured),
        else => {},
    };
    for (program.statements) |statement| {
        if (statement.data == .function_declaration) try self.lowerFunction(statement.data.function_declaration);
        if (statement.data == .struct_declaration) try self.lowerStruct(self.struct_infos.get(self.keyOf(statement.data.struct_declaration.name)).?);
    }
    var entry: Builder = try .init(self, "", .nothing, &.{}, &.{});
    entry.top_level = true;
    for (program.statements) |statement| {
        if (statement.data == .function_declaration) continue;
        try entry.statement(statement);
    }
    self.functions.items[0] = try entry.finish();
    return .{ .functions = self.functions.items, .globals = self.globals.items, .sites = self.sites.items, .literals = self.literals.items, .structs = self.struct_types.items };
}

fn fail(self: *Lower, span: Source.Span, what: []const u8) Error {
    self.unsupported = .{ .span = span, .what = what };
    return error.Unsupported;
}

fn keyOf(self: *Lower, name: []const u8) []const u8 {
    return self.facts.keyFor(self.file, name) orelse name;
}

fn site(self: *Lower, span: Source.Span) Error!Ir.Site {
    try self.sites.append(self.arena, span);
    return @intCast(self.sites.items.len - 1);
}

fn literal(self: *Lower, text: []const u8) Error!Ir.Operand {
    try self.literals.append(self.arena, text);
    return .{ .literal = @intCast(self.literals.items.len - 1) };
}

fn line(self: *Lower, span: Source.Span) u32 {
    return self.source.location(span.start).line;
}

/// The IR type of a checked type, or `null` for one slice 2 cannot hold.
fn irType(checked: Type) ?Ir.Type {
    if (checked.optional) {
        var payload = checked;
        payload.optional = false;
        const inner = irType(payload) orelse return null;
        return if (inner == .nothing) null else .optional;
    }
    return switch (checked.kind) {
        .int => .int,
        .float => .float,
        .bool => .bool,
        .string => .string,
        .struct_value => if (checked.user) |user| if (!user.trait and !user.enumeration and user.base == null and checked.type_arguments.len == 0) .structure else null else null,
        .nothing => .nothing,
        // A list of anything the compiler holds, lists of them included.
        .list => if (irType(checked.element.?.*) != null and irType(checked.element.?.*) != .nothing) .list else null,
        .dictionary => if (scalarOrHeld(checked.key.?.*) and scalarOrHeld(checked.element.?.*)) .map else null,
        .set => if (scalarOrHeld(checked.element.?.*)) .map else null,
        .tuple => for (checked.elements) |element| {
            const inner = irType(element) orelse break null;
            if (inner == .nothing) break null;
        } else .tuple,
        else => null,
    };
}

/// Whether the compiler can hold a value of `checked`, other than `nothing`.
fn scalarOrHeld(checked: Type) bool {
    const inner = irType(checked) orelse return false;
    return inner != .nothing;
}

/// The type a value of `checked` holds when present: the payload of an
/// optional, or itself.
fn payloadType(checked: Type) ?Ir.Type {
    var payload = checked;
    payload.optional = false;
    return irType(payload);
}

fn annotationType(self: *Lower, annotation: Ast.TypeExpression) Error!Ir.Type {
    if (annotation.question_span != null) {
        var plain = annotation;
        plain.question_span = null;
        const inner = try self.annotationType(plain);
        if (inner == .nothing) return self.fail(annotation.span, "a value of this type");
        return .optional;
    }
    if (annotation.positions) |positions| {
        for (positions) |position| {
            if (try self.annotationType(position) == .nothing) return self.fail(annotation.span, "a value of this type");
        }
        return .tuple;
    }
    const plain = annotation.element == null and annotation.key == null and annotation.signature == null and
        annotation.positions == null and annotation.arguments.len == 0 and annotation.question_span == null and
        !annotation.set and !annotation.task and !annotation.channel;
    if (plain) {
        if (std.mem.eql(u8, annotation.name, "Int")) return .int;
        if (std.mem.eql(u8, annotation.name, "Float")) return .float;
        if (std.mem.eql(u8, annotation.name, "Bool")) return .bool;
        if (std.mem.eql(u8, annotation.name, "String")) return .string;
        if (self.struct_infos.contains(self.keyOf(annotation.name))) return .structure;
    }
    // `Dict[K, V]` and `Set[T]`.
    if (annotation.key) |key| {
        if (annotation.element) |element| {
            if (try self.annotationType(key.*) != .nothing and try self.annotationType(element.*) != .nothing) return .map;
        }
    }
    if (annotation.set) {
        if (annotation.element) |element| {
            if (try self.annotationType(element.*) != .nothing) return .map;
        }
    }
    // `List[T]`: an element, and nothing marking another collection.
    if (annotation.element) |element| {
        if (annotation.key == null and !annotation.set and !annotation.task and !annotation.channel and annotation.question_span == null) {
            const inner = try self.annotationType(element.*);
            if (inner != .nothing) return .list;
        }
    }
    return self.fail(annotation.span, "a value of this type");
}

/// The element type a `List[T]` annotation names, or null for any other.
fn annotationElement(self: *Lower, annotation: Ast.TypeExpression) Error!?Ir.Type {
    const type_ = try self.annotationType(annotation);
    if (type_ != .list and !(type_ == .map and annotation.key != null)) return null;
    return try self.annotationType(annotation.element.?.*);
}

/// The payload type a `T?` annotation names, or null for any other.
fn annotationPayload(self: *Lower, annotation: Ast.TypeExpression) Error!?Ir.Type {
    if (annotation.question_span == null) return null;
    var plain = annotation;
    plain.question_span = null;
    return try self.annotationType(plain);
}

/// The payload type of an optional variable `declaration` declares.
fn declaredPayload(self: *Lower, declaration: Ast.Declaration) Error!?Ir.Type {
    if (declaration.annotation) |annotation| return self.annotationPayload(annotation);
    const initializer = declaration.initializer orelse return null;
    const found = self.checked.expression_types.get(initializer) orelse return null;
    if (!found.type.optional) return null;
    return payloadType(found.type);
}

/// The checker's type of the variable `declaration` declares: its
/// initializer's, or for a struct annotation, the struct's.
fn declaredChecked(self: *Lower, declaration: Ast.Declaration) ?Type {
    if (declaration.initializer) |initializer| {
        const found = self.checked.expression_types.get(initializer) orelse return null;
        // A declared `Float` holding an `Int` initializer is a `Float`.
        if (declaration.annotation != null and found.type.kind == .int) return null;
        return found.type;
    }
    const annotation = declaration.annotation orelse return null;
    return self.checked.structs.get(self.keyOf(annotation.name));
}

/// The struct type of a struct variable `declaration` declares.
fn declaredStruct(self: *Lower, declaration: Ast.Declaration) ?*StructInfo {
    const initializer = declaration.initializer orelse {
        const annotation = declaration.annotation orelse return null;
        return self.struct_infos.get(self.keyOf(annotation.name));
    };
    const found = self.checked.expression_types.get(initializer) orelse return null;
    if (found.type.optional) return null;
    const user = found.type.user orelse return null;
    return self.struct_infos.get(user.name);
}

/// The element type of the list an expression gives, from the checker.
fn listElement(self: *Lower, expression: *const Ast.Expression) ?Ir.Type {
    const found = self.checked.expression_types.get(expression) orelse return null;
    if (found.type.optional or (found.type.kind != .list and found.type.kind != .dictionary)) return null;
    return irType(found.type.element.?.*);
}

/// The element type of a list variable `declaration` declares, or the value
/// type of a dictionary variable.
fn declaredElement(self: *Lower, declaration: Ast.Declaration) Error!?Ir.Type {
    if (declaration.annotation) |annotation| return self.annotationElement(annotation);
    if (declaration.initializer) |initializer| return self.listElement(initializer);
    return null;
}

fn expressionType(self: *Lower, expression: *const Ast.Expression) Error!Ir.Type {
    const found = self.checked.expression_types.get(expression) orelse return self.fail(expression.span, "this expression");
    return irType(found.type) orelse self.fail(expression.span, "a value of this type");
}

/// Registers a struct's key, before any field or signature names it.
fn nameStruct(self: *Lower, declared: Ast.StructDeclaration) Error!void {
    // A class without a base class is a struct whose values are shared; one
    // that extends another, or is abstract, needs inheritance, not here yet.
    // A class that others extend fails with them, at theirs.
    const unsupported = declared.trait or declared.enumeration or declared.type_parameters.len != 0 or
        declared.base != null or declared.abstract_span != null or declared.traits.len != 0 or declared.properties.len != 0 or
        declared.type_functions.len != 0 or declared.type_fields.len != 0 or declared.types.len != 0;
    if (unsupported) return self.fail(declared.name_span, "a type declaration of this kind");
    const info = try self.arena.create(StructInfo);
    info.* = .{
        .key = self.keyOf(declared.name),
        .index = @intCast(self.struct_infos.count()),
        .declaration = declared,
        .fields = &.{},
        .field_names = &.{},
        .has_default = &.{},
        .any_default = false,
    };
    try self.struct_infos.put(self.arena, info.key, info);
}

/// The kind the runtime records for a field of `type_` (a payload's for an
/// optional), as the interpreter's descriptors do.
fn fieldKind(type_: Ir.Type, payload: ?Ir.Type) Ir.Type {
    return if (type_ == .optional) payload orelse .nothing else type_;
}

/// A struct's fields, methods, constructor and defaults, and its descriptor.
fn declareStruct(self: *Lower, declared: Ast.StructDeclaration) Error!void {
    const info = self.struct_infos.get(self.keyOf(declared.name)).?;
    const checked = self.checked.structs.get(info.key) orelse return self.fail(declared.name_span, "this type");
    const user = checked.user orelse return self.fail(declared.name_span, "this type");
    info.fields = try self.arena.alloc(FieldInfo, declared.fields.len);
    const names = try self.arena.alloc([]const u8, declared.fields.len);
    const defaults = try self.arena.alloc(bool, declared.fields.len);
    const kinds = try self.arena.alloc(Ir.Type, declared.fields.len);
    for (declared.fields, info.fields, names, defaults, kinds) |field, *out, *name, *defaulted, *kind| {
        out.* = .{
            .name = field.name,
            .type = try self.annotationType(field.annotation),
            .payload = try self.annotationPayload(field.annotation),
            .element = try self.annotationElement(field.annotation),
        };
        if (out.type == .optional and out.payload == null) return self.fail(field.name_span, "a field of this type");
        name.* = field.name;
        defaulted.* = field.default != null;
        info.any_default = info.any_default or defaulted.*;
        kind.* = fieldKind(out.type, out.payload);
    }
    info.field_names = names;
    info.has_default = defaults;
    try self.struct_types.append(self.arena, .{ .name = info.key, .display_name = user.display_name, .class = declared.class, .field_names = names, .field_kinds = kinds });

    if (info.any_default) {
        const flags = try self.arena.alloc(Ir.Type, declared.fields.len);
        @memset(flags, .bool);
        info.defaults = try self.newFunctionInfo(flags, null);
    }
    if (declared.constructor) |constructor| {
        for (constructor.parameters) |parameter| if (parameter.default != null) return self.fail(parameter.name_span, "a parameter with a default");
        info.constructor = try self.signature(constructor.parameters, null);
    }
    for (declared.methods) |method| {
        if (method.type_parameters.len != 0 or method.operator != null or method.abstract_span != null) return self.fail(method.name_span, "a method of this kind");
        const key = try Resolver.methodKey(self.arena, info.key, method.name);
        const changing = self.checked.changing_methods.contains(key);
        // A method that does not change `self` takes it as its first
        // parameter; a changing one takes it by reference instead.
        var parameters: std.ArrayList(Ast.Parameter) = .empty;
        if (!changing) try parameters.append(self.arena, .{ .name = "self", .name_span = method.name_span, .annotation = .{ .span = method.name_span, .name = declared.name, .question_span = null } });
        try parameters.appendSlice(self.arena, method.parameters);
        try self.methods.put(self.arena, key, .{ .function = try self.signature(parameters.items, method.return_annotation), .changing = changing, .declaration = method, .owner = info });
    }
}

/// A new function's slot and signature, for the parameters written.
fn signature(self: *Lower, parameters: []const Ast.Parameter, return_annotation: ?Ast.TypeExpression) Error!FunctionInfo {
    const types = try self.arena.alloc(Ir.Type, parameters.len);
    const elements = try self.arena.alloc(?Ir.Type, parameters.len);
    const payloads = try self.arena.alloc(?Ir.Type, parameters.len);
    for (parameters, types, elements, payloads) |parameter, *type_, *element, *payload| {
        if (parameter.default != null) return self.fail(parameter.name_span, "a parameter with a default");
        type_.* = try self.annotationType(parameter.annotation);
        element.* = try self.annotationElement(parameter.annotation);
        payload.* = try self.annotationPayload(parameter.annotation);
    }
    var info = try self.newFunctionInfo(types, if (return_annotation) |annotation| try self.annotationType(annotation) else null);
    info.elements = elements;
    info.payloads = payloads;
    info.result_payload = if (return_annotation) |annotation| try self.annotationPayload(annotation) else null;
    return info;
}

fn newFunctionInfo(self: *Lower, parameters: []const Ir.Type, result: ?Ir.Type) Error!FunctionInfo {
    const none = try self.arena.alloc(?Ir.Type, parameters.len);
    @memset(none, null);
    const info: FunctionInfo = .{
        .index = @intCast(self.functions.items.len),
        .parameters = parameters,
        .elements = none,
        .payloads = none,
        .result = result orelse .nothing,
        .result_payload = null,
    };
    try self.functions.append(self.arena, undefined);
    return info;
}

/// A struct's methods, constructor and field defaults, as functions.
fn lowerStruct(self: *Lower, info: *StructInfo) Error!void {
    const display = self.struct_types.items[info.index].display_name;
    var methods = self.methods.iterator();
    while (methods.next()) |entry| {
        const method = entry.value_ptr.*;
        if (method.owner != info) continue;
        var names: std.ArrayList([]const u8) = .empty;
        if (!method.changing) try names.append(self.arena, "self");
        for (method.declaration.parameters) |parameter| try names.append(self.arena, parameter.name);
        const key = try Resolver.methodKey(self.arena, info.key, method.declaration.name);
        try self.lowerBody(method.declaration.name, method.function, names.items, method.declaration.body, method.changing, true, null, info, try self.methodParameterTypes(info, key, method.changing));
    }
    if (info.constructor) |constructor| {
        const names = try self.arena.alloc([]const u8, info.declaration.constructor.?.parameters.len);
        for (info.declaration.constructor.?.parameters, names) |parameter, *name| name.* = parameter.name;
        const frame = try std.fmt.allocPrint(self.arena, "the constructor of `{s}`", .{display});
        try self.lowerBody(frame, constructor, names, info.declaration.constructor.?.body, true, false, null, info, if (self.checked.signatures.get(info.key)) |found| found.parameters else null);
    }
    if (info.defaults) |defaults| {
        const names = try self.arena.alloc([]const u8, info.fields.len);
        for (names, 0..) |*name, position| name.* = try std.fmt.allocPrint(self.arena, "(default {d})", .{position});
        const frame = try std.fmt.allocPrint(self.arena, "the field defaults of `{s}`", .{display});
        try self.lowerBody(frame, defaults, names, .{ .span = info.declaration.name_span, .statements = &.{} }, true, false, info, info, null);
    }
}

/// One function's body: a method, constructor or defaults when `self_ref`.
/// For a struct's field defaults, `defaults_of` names the struct, whose
/// defaults run where their flags say.
fn lowerBody(self: *Lower, name: []const u8, info: FunctionInfo, names: []const []const u8, body: Ast.Block, self_ref: bool, named: bool, defaults_of: ?*StructInfo, self_struct: ?*StructInfo, checked_parameters: ?[]const Type) Error!void {
    var builder: Builder = try .init(self, name, info.result, info.parameters, names);
    builder.self_ref = self_ref;
    for (info.elements, info.payloads, 0..) |element, payload, position| {
        if (element) |known| try builder.element_types.put(self.arena, @intCast(position), known);
        if (payload) |known| try builder.payload_types.put(self.arena, @intCast(position), known);
    }
    builder.result_payload = info.result_payload;
    builder.self_struct = self_struct;
    if (!self_ref and self_struct != null) try builder.struct_types.put(self.arena, 0, self_struct.?);
    if (checked_parameters) |types| {
        for (types, 0..) |checked, position| try builder.checked_types.put(self.arena, @intCast(position), checked);
    }
    if (defaults_of) |struct_info| {
        for (struct_info.declaration.fields, struct_info.fields, 0..) |field, field_info, position| {
            const default = field.default orelse continue;
            const run = try builder.newBlock();
            const after = try builder.newBlock();
            builder.terminate(.{ .branch = .{ .condition = .{ .local = @intCast(position) }, .then = run, .otherwise = after } });
            builder.switchTo(run);
            const value = try builder.convertTo(try builder.expression(default), field_info.type, field_info.payload, default.span);
            try builder.emit(default.span, .{ .struct_set = .{ .target = .self_ref, .position = @intCast(position), .value = .{ .operand = value, .type = field_info.type } } });
            builder.terminate(.{ .jump = after });
            builder.switchTo(after);
        }
    } else try builder.block(body);
    var function = try builder.finish();
    function.self_ref = self_ref;
    function.named = named;
    self.functions.items[info.index] = function;
}

/// The checker's types of a method's parameters, `self` first when the
/// method takes it as one.
fn methodParameterTypes(self: *Lower, info: *StructInfo, key: []const u8, changing: bool) Error!?[]const Type {
    const found = self.checked.signatures.get(key) orelse return null;
    if (changing) return found.parameters;
    const types = try self.arena.alloc(Type, found.parameters.len + 1);
    types[0] = self.checked.structs.get(info.key) orelse return null;
    @memcpy(types[1..], found.parameters);
    return types;
}

/// Whether the program's text mentions `name` inside any function or type
/// declaration: where a changing method's receiver, a module variable, could
/// be read or changed while the method holds it. The interpreter reports that
/// as an error; a compiled program would not, so such a call is not compiled.
fn mentionedInBodies(self: *Lower, name: []const u8) bool {
    for (self.bodies.items) |span| {
        const text = self.source.text[span.start..span.end];
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, name)) |at| {
            from = at + 1;
            const before_ok = at == 0 or !isNameByte(text[at - 1]);
            const after = at + name.len;
            const after_ok = after >= text.len or !isNameByte(text[after]);
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '?' or byte == '!' or byte >= 0x80;
}

fn declareFunction(self: *Lower, function: Ast.FunctionDeclaration) Error!void {
    if (function.type_parameters.len != 0) return self.fail(function.name_span, "a generic function");
    if (function.test_span != null) return self.fail(function.name_span, "a test");
    const parameters = try self.arena.alloc(Ir.Type, function.parameters.len);
    const elements = try self.arena.alloc(?Ir.Type, function.parameters.len);
    const payloads = try self.arena.alloc(?Ir.Type, function.parameters.len);
    for (function.parameters, parameters, elements, payloads) |parameter, *type_, *element, *payload| {
        if (parameter.default != null) return self.fail(parameter.name_span, "a parameter with a default");
        type_.* = try self.annotationType(parameter.annotation);
        element.* = try self.annotationElement(parameter.annotation);
        payload.* = try self.annotationPayload(parameter.annotation);
    }
    const result: Ir.Type = if (function.return_annotation) |annotation| try self.annotationType(annotation) else .nothing;
    try self.function_keys.put(self.arena, self.keyOf(function.name), .{
        .index = @intCast(self.functions.items.len),
        .parameters = parameters,
        .elements = elements,
        .payloads = payloads,
        .result = result,
        .result_payload = if (function.return_annotation) |annotation| try self.annotationPayload(annotation) else null,
        .names = blk: {
            const names = try self.arena.alloc([]const u8, function.parameters.len);
            for (function.parameters, names) |parameter, *name| name.* = parameter.name;
            break :blk names;
        },
    });
    try self.functions.append(self.arena, undefined);
}

/// The module variables a top-level `const (a, b) = ...` declares.
fn declareDestructured(self: *Lower, destructured: Ast.Destructuring) Error!void {
    const types = try self.patternTypes(destructured.pattern, destructured.initializer);
    for (destructured.pattern.positions, types) |position, type_| {
        try self.global_keys.put(self.arena, self.keyOf(position.name.text), @intCast(self.globals.items.len));
        try self.globals.append(self.arena, .{ .name = position.name.text, .type = type_ });
    }
}

/// The type of each position a flat pattern takes from a tuple.
fn patternTypes(self: *Lower, pattern: Ast.Pattern, value: *const Ast.Expression) Error![]const Ir.Type {
    const found = self.checked.expression_types.get(value) orelse return self.fail(pattern.span, "this destructuring");
    if (found.type.kind != .tuple or found.type.optional or found.type.elements.len != pattern.positions.len) return self.fail(pattern.span, "this destructuring");
    const types = try self.arena.alloc(Ir.Type, pattern.positions.len);
    for (pattern.positions, found.type.elements, types) |position, element, *type_| {
        if (position != .name) return self.fail(pattern.span, "a nested pattern");
        type_.* = irType(element) orelse return self.fail(pattern.span, "this destructuring");
        if (type_.* == .nothing) return self.fail(pattern.span, "this destructuring");
    }
    return types;
}

fn declareGlobal(self: *Lower, declaration: Ast.Declaration) Error!void {
    const type_: Ir.Type = if (declaration.annotation) |annotation|
        try self.annotationType(annotation)
    else if (declaration.initializer) |initializer|
        try self.expressionType(initializer)
    else
        return self.fail(declaration.name_span, "a declaration without a type");
    if (try self.declaredElement(declaration)) |element| try self.global_elements.put(self.arena, self.keyOf(declaration.name), element);
    if (try self.declaredPayload(declaration)) |payload| try self.global_payloads.put(self.arena, @intCast(self.globals.items.len), payload);
    if (self.declaredStruct(declaration)) |info| try self.global_structs.put(self.arena, @intCast(self.globals.items.len), info);
    if (self.declaredChecked(declaration)) |checked| try self.global_checked.put(self.arena, @intCast(self.globals.items.len), checked);
    try self.global_keys.put(self.arena, self.keyOf(declaration.name), @intCast(self.globals.items.len));
    try self.globals.append(self.arena, .{ .name = declaration.name, .type = type_ });
}

fn lowerFunction(self: *Lower, function: Ast.FunctionDeclaration) Error!void {
    const info = self.function_keys.get(self.keyOf(function.name)).?;
    const names = try self.arena.alloc([]const u8, function.parameters.len);
    for (function.parameters, names) |parameter, *name| name.* = parameter.name;
    var builder: Builder = try .init(self, function.name, info.result, info.parameters, names);
    for (info.elements, info.payloads, 0..) |element, payload, position| {
        if (element) |known| try builder.element_types.put(self.arena, @intCast(position), known);
        if (payload) |known| try builder.payload_types.put(self.arena, @intCast(position), known);
    }
    if (self.checked.signatures.get(self.keyOf(function.name))) |found| {
        for (found.parameters, 0..) |checked, position| try builder.checked_types.put(self.arena, @intCast(position), checked);
    }
    builder.result_payload = info.result_payload;
    try builder.block(function.body);
    self.functions.items[info.index] = try builder.finish();
}

/// What a value evaluates to: where to read it, and its type.
const Value = struct {
    operand: Ir.Operand,
    type: Ir.Type,
};

const Loop = struct {
    break_to: Ir.BlockIndex,
    continue_to: Ir.BlockIndex,
};

const BlockBuilder = struct {
    instructions: std.ArrayList(Ir.Instruction) = .empty,
    terminator: ?Ir.Terminator = null,
};

/// Builds one function's blocks.
const Builder = struct {
    owner: *Lower,
    name: []const u8,
    result: Ir.Type,
    parameter_count: u32,
    locals: std.ArrayList(Ir.LocalInfo) = .empty,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    current: Ir.BlockIndex = 0,
    /// Each scope maps a name written in it to its local, innermost last.
    scopes: std.ArrayList(std.StringHashMapUnmanaged(Ir.Local)) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    /// The element type of each local that holds a list, where it is known.
    element_types: std.AutoHashMapUnmanaged(Ir.Local, Ir.Type) = .empty,
    /// The struct type of each local that holds a struct.
    struct_types: std.AutoHashMapUnmanaged(Ir.Local, *StructInfo) = .empty,
    /// The checker's type of each variable whose type is known, for walking
    /// a path through it.
    checked_types: std.AutoHashMapUnmanaged(Ir.Local, Type) = .empty,
    /// The struct `self` is, in a method, constructor or defaults.
    self_struct: ?*StructInfo = null,
    /// The payload type of each local that holds an optional.
    payload_types: std.AutoHashMapUnmanaged(Ir.Local, Ir.Type) = .empty,
    /// The payload type of the function's result, when it is optional.
    result_payload: ?Ir.Type = null,
    /// The payload type of the `if` expression whose arms are being lowered.
    arm_payload: ?Ir.Type = null,
    /// Whether this function was given its `self` struct by reference.
    self_ref: bool = false,
    /// Whether this is the entry, whose outermost declarations are the
    /// module's variables.
    top_level: bool = false,

    fn init(owner: *Lower, name: []const u8, result: Ir.Type, parameters: []const Ir.Type, names: []const []const u8) Error!Builder {
        var self: Builder = .{ .owner = owner, .name = name, .result = result, .parameter_count = @intCast(parameters.len) };
        try self.blocks.append(owner.arena, .{});
        try self.scopes.append(owner.arena, .empty);
        for (parameters, names) |type_, written| {
            const local = try self.newLocal(written, type_);
            try self.scopes.items[0].put(owner.arena, written, local);
        }
        return self;
    }

    fn finish(self: *Builder) Error!Ir.Function {
        // Falling off the end returns nothing; the checker has proved a
        // function with a result returns before it gets there.
        self.terminate(.{ .@"return" = null });
        const blocks = try self.owner.arena.alloc(Ir.Block, self.blocks.items.len);
        for (self.blocks.items, blocks) |built, *out| out.* = .{
            .instructions = built.instructions.items,
            .terminator = built.terminator.?,
        };
        return .{
            .name = self.name,
            .locals = self.locals.items,
            .parameter_count = self.parameter_count,
            .result = self.result,
            .blocks = blocks,
        };
    }

    fn arena(self: *Builder) std.mem.Allocator {
        return self.owner.arena;
    }

    fn newLocal(self: *Builder, name: []const u8, type_: Ir.Type) Error!Ir.Local {
        try self.locals.append(self.arena(), .{ .name = name, .type = type_ });
        return @intCast(self.locals.items.len - 1);
    }

    fn temporary(self: *Builder, type_: Ir.Type) Error!Ir.Local {
        return self.newLocal("", type_);
    }

    fn newBlock(self: *Builder) Error!Ir.BlockIndex {
        try self.blocks.append(self.arena(), .{});
        return @intCast(self.blocks.items.len - 1);
    }

    fn switchTo(self: *Builder, index: Ir.BlockIndex) void {
        self.current = index;
    }

    /// Ends the current block, unless something already ended it, as a
    /// `return` inside an `if` does.
    fn terminate(self: *Builder, terminator: Ir.Terminator) void {
        const current = &self.blocks.items[self.current];
        if (current.terminator == null) current.terminator = terminator;
    }

    fn emit(self: *Builder, span: Source.Span, data: Ir.Instruction.Data) Error!void {
        const current = &self.blocks.items[self.current];
        // Code after a `return`, `break` or `continue` cannot run.
        if (current.terminator != null) return;
        try current.instructions.append(self.arena(), .{ .line = self.owner.line(span), .data = data });
    }

    fn pushScope(self: *Builder) Error!void {
        try self.scopes.append(self.arena(), .empty);
    }

    fn popScope(self: *Builder) void {
        _ = self.scopes.pop();
    }

    fn find(self: *Builder, name: []const u8) ?Ir.Local {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].get(name)) |local| return local;
        }
        return null;
    }

    /// The place a name written here refers to.
    fn place(self: *Builder, name: []const u8, span: Source.Span) Error!struct { place: Ir.Place, type: Ir.Type } {
        if (self.self_ref and std.mem.eql(u8, name, "self")) return .{ .place = .self_ref, .type = .structure };
        if (self.find(name)) |local| return .{ .place = .{ .local = local }, .type = self.locals.items[local].type };
        if (self.owner.global_keys.get(self.owner.keyOf(name))) |global| {
            return .{ .place = .{ .global = global }, .type = self.owner.globals.items[global].type };
        }
        return self.owner.fail(span, "this name");
    }

    fn block(self: *Builder, body: Ast.Block) Error!void {
        try self.pushScope();
        defer self.popScope();
        for (body.statements) |one| try self.statement(one);
    }

    fn statement(self: *Builder, one: Ast.Statement) Error!void {
        switch (one.data) {
            .expression => |called| {
                if (called.data != .call) return self.owner.fail(called.span, "this statement");
                _ = try self.call(called, called.data.call, true);
            },
            .declaration => |declared| try self.declaration(declared),
            .assignment => |assigned| try self.assignment(one.span, assigned),
            .conditional => |branching| try self.conditional(branching),
            .while_loop => |loop| try self.whileLoop(loop),
            .for_loop => |loop| try self.forLoop(loop),
            .break_statement => {
                self.terminate(.{ .jump = self.loops.items[self.loops.items.len - 1].break_to });
            },
            .continue_statement => {
                self.terminate(.{ .jump = self.loops.items[self.loops.items.len - 1].continue_to });
            },
            .return_statement => |returned| {
                if (returned.value) |value| {
                    const result = try self.convertTo(try self.expression(value), self.result, self.result_payload, value.span);
                    self.terminate(.{ .@"return" = result });
                } else self.terminate(.{ .@"return" = null });
            },
            .function_declaration => |function| return self.owner.fail(function.name_span, "a nested function"),
            .struct_declaration => |declared| if (!self.top_level or self.scopes.items.len != 1) return self.owner.fail(declared.name_span, "a nested type declaration"),
            .raise_statement => |raised| return self.owner.fail(raised.keyword_span, "`raise`"),
            .try_statement => |tried| return self.owner.fail(tried.keyword_span, "`try`"),
            .assert_statement => |assertion| return self.owner.fail(assertion.keyword_span, "`assert`"),
            .case_statement => |case| return self.owner.fail(case.keyword_span, "`case`"),
            .destructuring => |destructured| try self.destructuring(destructured),
            .destructuring_assignment => |destructured| try self.destructuringAssignment(one.span, destructured),
        }
    }

    fn declaration(self: *Builder, declaration_: Ast.Declaration) Error!void {
        // The entry's outermost declarations are module variables, which
        // functions can read; every other declaration is a local.
        if (self.top_level and self.scopes.items.len == 1) {
            const global = self.owner.global_keys.get(self.owner.keyOf(declaration_.name)).?;
            if (declaration_.initializer) |initializer| {
                const type_ = self.owner.globals.items[global].type;
                const value = try self.convertTo(try self.expression(initializer), type_, self.owner.global_payloads.get(global), initializer.span);
                try self.emit(initializer.span, .{ .move = .{ .destination = .{ .global = global }, .source = value } });
            }
            return;
        }
        const type_: Ir.Type = if (declaration_.annotation) |annotation|
            try self.owner.annotationType(annotation)
        else if (declaration_.initializer) |initializer|
            try self.owner.expressionType(initializer)
        else
            return self.owner.fail(declaration_.name_span, "a declaration without a type");
        // The initializer is evaluated before the name exists, so it reads
        // any outer variable of the same name.
        const payload = try self.owner.declaredPayload(declaration_);
        const initial = if (declaration_.initializer) |initializer|
            try self.convertTo(try self.expression(initializer), type_, payload, initializer.span)
        else
            null;
        const local = try self.newLocal(declaration_.name, type_);
        if (payload) |known| try self.payload_types.put(self.arena(), local, known);
        if (self.owner.declaredStruct(declaration_)) |info| try self.struct_types.put(self.arena(), local, info);
        if (self.owner.declaredChecked(declaration_)) |checked| try self.checked_types.put(self.arena(), local, checked);
        if (try self.owner.declaredElement(declaration_)) |element| try self.element_types.put(self.arena(), local, element);
        try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), declaration_.name, local);
        if (initial) |value| try self.emit(declaration_.name_span, .{ .move = .{ .destination = .{ .local = local }, .source = value } });
    }

    fn assignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment) Error!void {
        if (assignment_.steps.len != 0) return self.elementAssignment(span, assignment_);
        const target = try self.place(assignment_.name, assignment_.name_span);
        if (assignment_.operation) |operation| {
            // Read once, before the right side runs, which could change it.
            const current = try self.read(target.place, target.type, span);
            const right = try self.expression(assignment_.value);
            const result = try self.binary(span, operation, current, right);
            const stored = try self.convertTo(result, target.type, self.payloadOf(target.place), span);
            try self.emit(span, .{ .move = .{ .destination = target.place, .source = stored } });
            return;
        }
        const value = try self.convertTo(try self.expression(assignment_.value), target.type, self.payloadOf(target.place), assignment_.value.span);
        try self.emit(span, .{ .move = .{ .destination = target.place, .source = value } });
    }

    fn conditional(self: *Builder, branch: Ast.If) Error!void {
        const condition = try self.expression(branch.condition);
        const then_block = try self.newBlock();
        const after = try self.newBlock();
        const otherwise_block = if (branch.otherwise != null) try self.newBlock() else after;
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = then_block, .otherwise = otherwise_block } });

        self.switchTo(then_block);
        try self.block(branch.then_block);
        self.terminate(.{ .jump = after });

        if (branch.otherwise) |otherwise| {
            self.switchTo(otherwise_block);
            switch (otherwise) {
                .block => |body| try self.block(body),
                .chained => |chained| try self.statement(chained.*),
            }
            self.terminate(.{ .jump = after });
        }
        self.switchTo(after);
    }

    fn whileLoop(self: *Builder, loop: Ast.While) Error!void {
        const head = try self.newBlock();
        const body = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .jump = head });
        self.switchTo(head);
        const condition = try self.expression(loop.condition);
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = body, .otherwise = after } });
        self.switchTo(body);
        try self.loops.append(self.arena(), .{ .break_to = after, .continue_to = head });
        try self.block(loop.body);
        _ = self.loops.pop();
        self.terminate(.{ .jump = head });
        self.switchTo(after);
    }

    /// Section 6.4's `for` over a written range. The counter stops on
    /// reaching the last value rather than stepping past it, so a range that
    /// ends at the largest `Int` does not overflow, as `Range` itself does.
    fn forLoop(self: *Builder, loop: Ast.For) Error!void {
        if (loop.iterable.data != .range) {
            switch (self.checkedType(loop.iterable) orelse return self.owner.fail(loop.iterable.span, "a `for` over this")) {
                .list => return self.forList(loop),
                .map => return self.forMap(loop),
                .string => return self.forString(loop),
                else => return self.owner.fail(loop.iterable.span, "a `for` over this"),
            }
        }
        if (loop.pattern != null) return self.owner.fail(loop.name_span, "a `for` with a pattern");
        const range = loop.iterable.data.range;
        const start = try self.convert(try self.expression(range.start), .int, range.start.span);
        const end = try self.convert(try self.expression(range.end), .int, range.end.span);
        const span = loop.iterable.span;

        // `first` and `last`, or an empty range: `a..b` holds `b`, `a..<b`
        // stops before it.
        const current = try self.temporary(.int);
        const last = try self.temporary(.int);
        try self.emit(span, .{ .move = .{ .destination = .{ .local = current }, .source = start } });
        const empty = try self.temporary(.bool);
        try self.emit(span, .{ .compare = .{
            .operator = if (range.inclusive) .greater else .greater_equal,
            .kind = .int,
            .destination = .{ .local = empty },
            .left = start,
            .right = end,
        } });
        const setup = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = .{ .local = empty }, .then = after, .otherwise = setup } });
        self.switchTo(setup);
        if (range.inclusive) {
            try self.emit(span, .{ .move = .{ .destination = .{ .local = last }, .source = end } });
        } else {
            // `end` is above `start`, so this cannot overflow.
            try self.emit(span, .{ .int_arithmetic = .{ .operator = .subtract, .destination = .{ .local = last }, .left = end, .right = .{ .int = 1 }, .site = try self.owner.site(span) } });
        }
        const body = try self.newBlock();
        const step = try self.newBlock();
        self.terminate(.{ .jump = body });

        self.switchTo(body);
        try self.pushScope();
        const variable = try self.newLocal(loop.name, .int);
        try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), loop.name, variable);
        try self.emit(loop.name_span, .{ .move = .{ .destination = .{ .local = variable }, .source = .{ .local = current } } });
        try self.loops.append(self.arena(), .{ .break_to = after, .continue_to = step });
        try self.block(loop.body);
        _ = self.loops.pop();
        self.popScope();
        self.terminate(.{ .jump = step });

        self.switchTo(step);
        const done = try self.temporary(.bool);
        try self.emit(span, .{ .compare = .{ .operator = .equal, .kind = .int, .destination = .{ .local = done }, .left = .{ .local = current }, .right = .{ .local = last } } });
        const advance = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = .{ .local = done }, .then = after, .otherwise = advance } });
        self.switchTo(advance);
        try self.emit(span, .{ .int_arithmetic = .{ .operator = .add, .destination = .{ .local = current }, .left = .{ .local = current }, .right = .{ .int = 1 }, .site = try self.owner.site(span) } });
        self.terminate(.{ .jump = body });

        self.switchTo(after);
    }

    /// The value at `place` now. A module variable is copied, since a call
    /// later in the same expression could change it before it is used; a
    /// local cannot change that way until slice 3 compiles closures.
    fn read(self: *Builder, at: Ir.Place, type_: Ir.Type, span: Source.Span) Error!Value {
        switch (at) {
            .local => |local| return .{ .operand = .{ .local = local }, .type = type_ },
            .global => |global| {
                const copy = try self.temporary(type_);
                try self.emit(span, .{ .move = .{ .destination = .{ .local = copy }, .source = .{ .global = global } } });
                return .{ .operand = .{ .local = copy }, .type = type_ };
            },
            // A changing call later in the expression could change it too.
            .self_ref => {
                const copy = try self.temporary(type_);
                try self.emit(span, .{ .move = .{ .destination = .{ .local = copy }, .source = .self_ref } });
                return .{ .operand = .{ .local = copy }, .type = type_ };
            },
        }
    }

    /// `value` as `target`, widening an `Int` where a `Float` is expected.
    fn convert(self: *Builder, value: Value, target: Ir.Type, span: Source.Span) Error!Ir.Operand {
        if (value.type == target) return value.operand;
        if (value.type == .int and target == .float) {
            if (value.operand == .int) return .{ .float = @floatFromInt(value.operand.int) };
            const widened = try self.temporary(.float);
            try self.emit(span, .{ .widen = .{ .destination = .{ .local = widened }, .operand = value.operand } });
            return .{ .local = widened };
        }
        if (target == .optional) return self.wrapAs(value, null, span);
        return self.owner.fail(span, "this conversion");
    }

    /// `value` as `target`, where an optional target holds a `payload`: an
    /// `Int` stored in a `Float?` is widened first, as the interpreter widens
    /// what it stores (4.4).
    fn convertTo(self: *Builder, value: Value, target: Ir.Type, payload: ?Ir.Type, span: Source.Span) Error!Ir.Operand {
        if (target == .optional and value.type != .optional) return self.wrapAs(value, payload, span);
        return self.convert(value, target, span);
    }

    /// `value` as an optional holding it. Without the payload's type, an
    /// `Int` might belong in a `Float?`, so the build stops rather than guess.
    fn wrapAs(self: *Builder, value: Value, payload: ?Ir.Type, span: Source.Span) Error!Ir.Operand {
        if (value.type == .nothing) return .nothing;
        if (value.type == .optional) return value.operand;
        const inner_type = payload orelse if (value.type == .int) return self.owner.fail(span, "an Int stored as an optional here") else value.type;
        const inner: Value = .{ .operand = try self.convert(value, inner_type, span), .type = inner_type };
        const wrapped = try self.temporary(.optional);
        try self.emit(span, .{ .wrap = .{ .destination = .{ .local = wrapped }, .value = .{ .operand = inner.operand, .type = inner.type } } });
        return .{ .local = wrapped };
    }

    /// The payload type of the optional a variable holds, as its declaration
    /// settled it.
    fn payloadOf(self: *Builder, at: Ir.Place) ?Ir.Type {
        return switch (at) {
            .local => |local| self.payload_types.get(local),
            .global => |global| self.owner.global_payloads.get(global),
            .self_ref => null,
        };
    }

    /// The payload of an optional the checker has proved holds one.
    fn unwrap(self: *Builder, span: Source.Span, operand: Ir.Operand, payload: Ir.Type) Error!Value {
        const result = try self.temporary(payload);
        try self.emit(span, .{ .unwrap = .{ .destination = .{ .local = result }, .operand = operand, .payload = payload } });
        return .{ .operand = .{ .local = result }, .type = payload };
    }

    fn expression(self: *Builder, expression_: *const Ast.Expression) Error!Value {
        return switch (expression_.data) {
            .int_literal => |value| .{ .operand = .{ .int = value }, .type = .int },
            .float_literal => |value| .{ .operand = .{ .float = value }, .type = .float },
            .bool_literal => |value| .{ .operand = .{ .bool = value }, .type = .bool },
            .name => |name| blk: {
                const found = try self.place(name, expression_.span);
                const value = try self.read(found.place, found.type, expression_.span);
                // Section 4.5: where the checker has narrowed an optional to
                // its payload, the read is of the payload.
                if (found.type == .optional) {
                    if (self.checkedType(expression_)) |narrowed| if (narrowed != .optional) {
                        break :blk try self.unwrap(expression_.span, value.operand, narrowed);
                    };
                }
                break :blk value;
            },
            .unary => |operation| self.unary(expression_.span, operation),
            .binary => |operation| blk: {
                if (self.owner.checked.operator_calls.contains(expression_)) return self.owner.fail(expression_.span, "an operator defined by a type");
                const left = try self.expression(operation.left);
                const right = try self.expression(operation.right);
                break :blk self.binary(expression_.span, operation.operator, left, right);
            },
            .logical => |operation| self.logical(expression_, operation),
            .comparison => |chain| self.comparison(expression_, chain),
            .if_expression => |choice| self.ifExpression(expression_, choice),
            .call => |call_| (try self.call(expression_, call_, false)) orelse self.owner.fail(expression_.span, "using the result of this call"),
            .string_literal => |text| .{ .operand = try self.owner.literal(text), .type = .string },
            .interpolation => |pieces| self.interpolation(expression_, pieces),
            .nothing_literal => .{ .operand = .nothing, .type = .nothing },
            .list_literal => |items| self.listLiteral(expression_, items),
            .dictionary_literal => |entries| self.dictionaryLiteral(expression_, entries),
            .tuple_literal => |items| self.tupleLiteral(expression_, items),
            .range => self.owner.fail(expression_.span, "a range outside a `for`"),
            .lambda => self.owner.fail(expression_.span, "a block"),
            .member => |accessed| self.memberAccess(expression_, accessed),
            .index => |indexed| self.indexing(expression_, indexed),
            .slice => |sliced| self.slicing(expression_, sliced),
            .case_expression => self.owner.fail(expression_.span, "`case`"),
            .enum_value, .type_literal => self.owner.fail(expression_.span, "a type's value"),
            .type_test => self.owner.fail(expression_.span, "`is`"),
        };
    }

    fn unary(self: *Builder, span: Source.Span, unary_: Ast.Expression.Unary) Error!Value {
        const operand = try self.expression(unary_.operand);
        switch (unary_.operator) {
            .not => {
                const result = try self.temporary(.bool);
                try self.emit(span, .{ .not = .{ .destination = .{ .local = result }, .operand = operand.operand } });
                return .{ .operand = .{ .local = result }, .type = .bool };
            },
            .negate => {
                const result = try self.temporary(operand.type);
                switch (operand.type) {
                    .int => try self.emit(span, .{ .negate_int = .{ .destination = .{ .local = result }, .operand = operand.operand, .site = try self.owner.site(span) } }),
                    .float => try self.emit(span, .{ .negate_float = .{ .destination = .{ .local = result }, .operand = operand.operand } }),
                    else => return self.owner.fail(span, "negating this value"),
                }
                return .{ .operand = .{ .local = result }, .type = operand.type };
            },
        }
    }

    /// Section 5.3: two `Int`s give an `Int`, except under `/`; any `Float`
    /// makes the operation a `Float` one.
    fn binary(self: *Builder, span: Source.Span, operator: Arithmetic, left: Value, right: Value) Error!Value {
        if (left.type == .string and right.type == .string and operator == .add) {
            const result = try self.temporary(.string);
            try self.emit(span, .{ .concat = .{ .destination = .{ .local = result }, .left = left.operand, .right = right.operand } });
            return .{ .operand = .{ .local = result }, .type = .string };
        }
        if (!isNumber(left.type) or !isNumber(right.type)) return self.owner.fail(span, "this operation");
        if (left.type == .int and right.type == .int and operator != .divide) {
            const result = try self.temporary(.int);
            try self.emit(span, .{ .int_arithmetic = .{ .operator = operator, .destination = .{ .local = result }, .left = left.operand, .right = right.operand, .site = try self.owner.site(span) } });
            return .{ .operand = .{ .local = result }, .type = .int };
        }
        const left_float = try self.convert(left, .float, span);
        const right_float = try self.convert(right, .float, span);
        const result = try self.temporary(.float);
        try self.emit(span, .{ .float_arithmetic = .{ .operator = operator, .destination = .{ .local = result }, .left = left_float, .right = right_float, .site = try self.owner.site(span) } });
        return .{ .operand = .{ .local = result }, .type = .float };
    }

    /// `and` and `or`, which evaluate the right side only when the left
    /// does not decide the answer.
    fn logical(self: *Builder, expression_: *const Ast.Expression, logical_: Ast.Expression.Logical) Error!Value {
        const result = try self.temporary(.bool);
        const left = try self.expression(logical_.left);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = left.operand } });
        const right_block = try self.newBlock();
        const after = try self.newBlock();
        switch (logical_.operator) {
            .conjunction => self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = right_block, .otherwise = after } }),
            .disjunction => self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = after, .otherwise = right_block } }),
        }
        self.switchTo(right_block);
        const right = try self.expression(logical_.right);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = right.operand } });
        self.terminate(.{ .jump = after });
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = .bool };
    }

    /// Section 5.2's chain, `a < b < c`: each middle operand evaluated once,
    /// and the chain stopping at the first link that is false.
    fn comparison(self: *Builder, expression_: *const Ast.Expression, comparison_: Ast.Expression.Comparison) Error!Value {
        const result = try self.temporary(.bool);
        const after = try self.newBlock();
        var left = try self.expression(comparison_.operands[0]);
        for (comparison_.operators, comparison_.operands[1..], 0..) |operator, operand, position| {
            const right = try self.expression(operand);
            const kind: Ir.Instruction.Comparison = switch (left.type) {
                .int => switch (right.type) {
                    .int => .int,
                    .float => .int_float,
                    .optional, .nothing => if (operator.isEquality()) .value else return self.owner.fail(expression_.span, "this comparison"),
                    else => return self.owner.fail(expression_.span, "this comparison"),
                },
                .float => switch (right.type) {
                    .float => .float,
                    .int => .float_int,
                    .optional, .nothing => if (operator.isEquality()) .value else return self.owner.fail(expression_.span, "this comparison"),
                    else => return self.owner.fail(expression_.span, "this comparison"),
                },
                .bool => if (right.type == .bool and operator.isEquality()) .bool else if ((right.type == .optional or right.type == .nothing) and operator.isEquality()) .value else return self.owner.fail(expression_.span, "this comparison"),
                .string => if (right.type == .string) .string else if (operator.isEquality()) .value else return self.owner.fail(expression_.span, "this comparison"),
                .list, .optional, .tuple, .map, .structure, .nothing => if (operator.isEquality()) .value else return self.owner.fail(expression_.span, "this comparison"),
            };
            // Compared as values, both sides are wrapped as optionals.
            const left_operand = if (kind == .value) try self.wrapAs(left, left.type, expression_.span) else left.operand;
            const right_operand = if (kind == .value) try self.wrapAs(right, right.type, expression_.span) else right.operand;
            try self.emit(expression_.span, .{ .compare = .{ .operator = operator, .kind = kind, .destination = .{ .local = result }, .left = left_operand, .right = right_operand } });
            if (position + 1 < comparison_.operators.len) {
                const next = try self.newBlock();
                self.terminate(.{ .branch = .{ .condition = .{ .local = result }, .then = next, .otherwise = after } });
                self.switchTo(next);
            }
            left = right;
        }
        self.terminate(.{ .jump = after });
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = .bool };
    }

    fn ifExpression(self: *Builder, expression_: *const Ast.Expression, choice: Ast.Expression.IfExpression) Error!Value {
        const type_ = try self.owner.expressionType(expression_);
        self.arm_payload = payloadType(self.owner.checked.expression_types.get(expression_).?.type);
        const result = try self.temporary(type_);
        const condition = try self.expression(choice.condition);
        const then_block = try self.newBlock();
        const else_block = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = condition.operand, .then = then_block, .otherwise = else_block } });
        try self.arm(then_block, choice.then_value, result, type_, after);
        try self.arm(else_block, choice.else_value, result, type_, after);
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = type_ };
    }

    fn arm(self: *Builder, start: Ir.BlockIndex, value: *const Ast.Expression, result: Ir.Local, type_: Ir.Type, after: Ir.BlockIndex) Error!void {
        self.switchTo(start);
        const converted = try self.convertTo(try self.expression(value), type_, self.arm_payload, value.span);
        try self.emit(value.span, .{ .move = .{ .destination = .{ .local = result }, .source = converted } });
        self.terminate(.{ .jump = after });
    }

    /// A call to `print`, `write` or a function of the program. Gives the
    /// result, or null when the call gives nothing.
    fn call(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, discarded: bool) Error!?Value {
        if (call_.callee.data == .member) {
            // A struct's own methods bind named arguments as constructions do.
            if (self.owner.checked.method_calls.get(call_.callee)) |key| {
                if (self.owner.methods.get(key)) |method_info| return try self.structMethod(expression_, call_, call_.callee.data.member, method_info, discarded);
            }
            if (call_.names.len != 0) return self.owner.fail(expression_.span, "named arguments");
            return self.method(expression_, call_, call_.callee.data.member, discarded);
        }
        if (call_.callee.data == .name and self.find(call_.callee.data.name) == null) {
            if (self.owner.struct_infos.get(self.owner.keyOf(call_.callee.data.name))) |info| return try self.construct(expression_, call_, info);
        }
        if (call_.callee.data != .name) return self.owner.fail(call_.callee.span, "calling this");
        const name = call_.callee.data.name;
        if (self.find(name) == null) {
            if (self.owner.struct_infos.get(self.owner.keyOf(name))) |info| return try self.construct(expression_, call_, info);
            if (self.owner.function_keys.get(self.owner.keyOf(name))) |info| {
                // Evaluated in the order written, then placed by parameter,
                // as the interpreter binds positional and named arguments.
                const positions = try self.bindArguments(call_, info.names, try self.arena().alloc(bool, info.names.len));
                const written = try self.arena().alloc(Value, call_.arguments.len);
                for (call_.arguments, written) |argument, *value| value.* = try self.expression(argument);
                const arguments = try self.arena().alloc(Ir.Operand, info.parameters.len);
                for (positions, info.parameters, info.payloads, arguments) |position, parameter, payload, *out| {
                    const value = written[position orelse return self.owner.fail(expression_.span, "leaving out an argument")];
                    out.* = try self.convertTo(value, parameter, payload, expression_.span);
                }
                const destination: ?Ir.Local = if (info.result == .nothing or discarded) null else try self.temporary(info.result);
                try self.emit(expression_.span, .{ .call = .{
                    .function = info.index,
                    .arguments = arguments,
                    .destination = if (destination) |local| .{ .local = local } else null,
                    .site = try self.owner.site(expression_.span),
                } });
                return if (destination) |local| .{ .operand = .{ .local = local }, .type = info.result } else null;
            }
            // Section 15.2's `print` and `write` are built in rather than
            // declared, so the resolver keys them only when the program
            // declares a name of its own that hides them.
            if (self.owner.facts.keyFor(self.owner.file, name) == null) {
                if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "write")) {
                    try self.print(expression_, call_, std.mem.eql(u8, name, "print"));
                    return null;
                }
            }
        }
        return self.owner.fail(expression_.span, "calling this function");
    }

    /// Section 15.2: the arguments' display, separated by spaces, and for
    /// `print` the end of the line. Every argument is evaluated before any of
    /// the line is written, as the interpreter builds the line first, so a
    /// call among the arguments prints its own output ahead of it.
    fn print(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, newline: bool) Error!void {
        var parts: std.ArrayList(Ir.Instruction.Write) = .empty;
        for (call_.arguments, 0..) |argument, position| {
            if (position != 0) try parts.append(self.arena(), .{ .text = " " });
            switch (argument.data) {
                .interpolation => |pieces| for (pieces) |piece| switch (piece) {
                    .text => |text| try parts.append(self.arena(), .{ .text = text }),
                    .expression => |inner| try parts.append(self.arena(), try self.display(inner)),
                },
                else => try parts.append(self.arena(), try self.display(argument)),
            }
        }
        if (newline) try parts.append(self.arena(), .{ .text = "\n" });
        for (parts.items) |part| try self.emit(expression_.span, .{ .write = part });
    }

    fn display(self: *Builder, expression_: *const Ast.Expression) Error!Ir.Instruction.Write {
        if (expression_.data == .string_literal) return .{ .text = expression_.data.string_literal };
        const value = try self.expression(expression_);
        return switch (value.type) {
            .int => .{ .int = value.operand },
            .float => .{ .float = value.operand },
            .bool => .{ .bool = value.operand },
            .string => .{ .string = value.operand },
            .list, .optional, .tuple, .map, .structure => .{ .value = .{ .operand = value.operand, .type = value.type } },
            .nothing => .{ .text = "nothing" },
        };
    }

    /// The element type of the list `expression_` gives, from the checker.
    fn elementType(self: *Builder, expression_: *const Ast.Expression) ?Ir.Type {
        const found = self.owner.checked.expression_types.get(expression_) orelse return null;
        if (found.type.kind != .list) return null;
        return irType(found.type.element.?.*);
    }

    /// Section 8.2's list literal, whose element type the checker settled:
    /// whole numbers in a `[Float]` are widened as they are stored.
    fn listLiteral(self: *Builder, expression_: *const Ast.Expression, items: []const *const Ast.Expression) Error!Value {
        const checked_type = self.owner.checked.literal_types.get(expression_) orelse
            (self.owner.checked.expression_types.get(expression_) orelse return self.owner.fail(expression_.span, "this list")).type;
        // Section 8.2: the same brackets are a set where a set was expected,
        // and an empty `[]` is whichever of the three was.
        if (checked_type.kind == .set or checked_type.kind == .dictionary) return self.mapLiteral(expression_, checked_type, items, &.{});
        if (checked_type.kind != .list) return self.owner.fail(expression_.span, "this list");
        const element = irType(checked_type.element.?.*) orelse return self.owner.fail(expression_.span, "a list of this type");
        if (element == .nothing) return self.owner.fail(expression_.span, "a list of this type");
        const typed = try self.arena().alloc(Ir.Typed, items.len);
        const element_payload = payloadType(checked_type.element.?.*);
        for (items, typed) |item, *out| {
            out.* = .{ .operand = try self.convertTo(try self.expression(item), element, element_payload, item.span), .type = element };
        }
        const result = try self.temporary(.list);
        // The runtime's list records the kind its elements have when present.
        const kind = if (element == .optional) element_payload orelse return self.owner.fail(expression_.span, "a list of this type") else element;
        try self.emit(expression_.span, .{ .list_new = .{ .destination = .{ .local = result }, .element = kind, .items = typed } });
        return .{ .operand = .{ .local = result }, .type = .list };
    }

    /// Section 5.1's interpolation, as a value: a new string built from its
    /// parts, each shown as `print` shows it.
    fn interpolation(self: *Builder, expression_: *const Ast.Expression, pieces: []const Ast.Expression.Part) Error!Value {
        var parts: std.ArrayList(Ir.Instruction.Write) = .empty;
        for (pieces) |piece| switch (piece) {
            .text => |text| try parts.append(self.arena(), .{ .text = text }),
            .expression => |inner| try parts.append(self.arena(), try self.display(inner)),
        };
        const result = try self.temporary(.string);
        try self.emit(expression_.span, .{ .format = .{ .destination = .{ .local = result }, .parts = parts.items } });
        return .{ .operand = .{ .local = result }, .type = .string };
    }

    /// The type the checker gave `expression_`, if slice 3a can hold it.
    fn checkedType(self: *Builder, expression_: *const Ast.Expression) ?Ir.Type {
        const found = self.owner.checked.expression_types.get(expression_) orelse return null;
        return irType(found.type);
    }

    /// A property: section 9.2's `count` of a string's characters.
    fn memberAccess(self: *Builder, expression_: *const Ast.Expression, member_: Ast.Expression.Member) Error!Value {
        if (member_.optional) return self.owner.fail(expression_.span, "this member");
        if (self.checkedType(member_.base) == .structure or self.fieldOf(member_.base, member_.name) != null) return self.fieldRead(expression_, member_);
        if (member_.position) |position| {
            if (self.checkedType(member_.base) != .tuple) return self.owner.fail(expression_.span, "this member");
            const type_ = self.checkedType(expression_) orelse return self.owner.fail(expression_.span, "this member");
            const tuple = try self.expression(member_.base);
            const result = try self.temporary(type_);
            try self.emit(expression_.span, .{ .tuple_get = .{ .destination = .{ .local = result }, .tuple = tuple.operand, .position = position, .type = type_ } });
            return .{ .operand = .{ .local = result }, .type = type_ };
        }
        const base_type = self.checkedType(member_.base);
        if ((base_type != .string and base_type != .list and base_type != .map) or !std.mem.eql(u8, member_.name, "count")) return self.owner.fail(expression_.span, "this member");
        const base = try self.expression(member_.base);
        if (base_type == .map) {
            const counted = try self.temporary(.int);
            try self.emit(expression_.span, .{ .map_count = .{ .destination = .{ .local = counted }, .map = base.operand } });
            return .{ .operand = .{ .local = counted }, .type = .int };
        }
        if (base_type == .list) {
            const counted = try self.temporary(.int);
            try self.emit(expression_.span, .{ .list_count = .{ .destination = .{ .local = counted }, .list = base.operand } });
            return .{ .operand = .{ .local = counted }, .type = .int };
        }
        const result = try self.temporary(.int);
        try self.emit(expression_.span, .{ .string_count = .{ .destination = .{ .local = result }, .operand = base.operand } });
        return .{ .operand = .{ .local = result }, .type = .int };
    }

    fn indexing(self: *Builder, expression_: *const Ast.Expression, index_: Ast.Expression.Index) Error!Value {
        if (self.checkedType(index_.base) == .map) {
            const map = try self.expression(index_.base);
            const key = try self.expression(index_.index);
            const result = try self.temporary(.optional);
            try self.emit(expression_.span, .{ .map_get = .{ .destination = .{ .local = result }, .map = map.operand, .key = .{ .operand = key.operand, .type = key.type }, .site = try self.owner.site(index_.index.span) } });
            return .{ .operand = .{ .local = result }, .type = .optional };
        }
        if (self.checkedType(index_.base) == .list) {
            const element = self.checkedType(expression_) orelse return self.owner.fail(expression_.span, "indexing this");
            const list = try self.expression(index_.base);
            const at = try self.convert(try self.expression(index_.index), .int, index_.index.span);
            const result = try self.temporary(element);
            try self.emit(expression_.span, .{ .list_get = .{ .destination = .{ .local = result }, .list = list.operand, .position = at, .element = element, .site = try self.owner.site(expression_.span) } });
            return .{ .operand = .{ .local = result }, .type = element };
        }
        if (self.checkedType(index_.base) != .string) return self.owner.fail(expression_.span, "indexing this");
        const base = try self.expression(index_.base);
        const position = try self.convert(try self.expression(index_.index), .int, index_.index.span);
        const result = try self.temporary(.string);
        try self.emit(expression_.span, .{ .string_index = .{ .destination = .{ .local = result }, .operand = base.operand, .position = position, .site = try self.owner.site(expression_.span) } });
        return .{ .operand = .{ .local = result }, .type = .string };
    }

    fn slicing(self: *Builder, expression_: *const Ast.Expression, slice_: Ast.Expression.Slice) Error!Value {
        if (self.checkedType(slice_.base) != .string) return self.owner.fail(expression_.span, "slicing this");
        const base = try self.expression(slice_.base);
        const start: ?Ir.Operand = if (slice_.start) |bound| try self.convert(try self.expression(bound), .int, bound.span) else null;
        const end: ?Ir.Operand = if (slice_.end) |bound| try self.convert(try self.expression(bound), .int, bound.span) else null;
        const result = try self.temporary(.string);
        try self.emit(expression_.span, .{ .string_slice = .{
            .destination = .{ .local = result },
            .operand = base.operand,
            .start = start,
            .end = end,
            .inclusive = slice_.inclusive,
            .site = try self.owner.site(expression_.span),
        } });
        return .{ .operand = .{ .local = result }, .type = .string };
    }

    /// Section 8.2's `["Ava": 90, "Ben": 85]`.
    fn dictionaryLiteral(self: *Builder, expression_: *const Ast.Expression, entries: []const Ast.Expression.Entry) Error!Value {
        const checked_type = self.owner.checked.literal_types.get(expression_) orelse
            (self.owner.checked.expression_types.get(expression_) orelse return self.owner.fail(expression_.span, "this dictionary")).type;
        if (checked_type.kind != .dictionary) return self.owner.fail(expression_.span, "this dictionary");
        return self.mapLiteral(expression_, checked_type, &.{}, entries);
    }

    /// A dictionary or set built from a literal: a new map, then each entry
    /// put into it in order, the key and then the value evaluated as the
    /// interpreter evaluates them.
    fn mapLiteral(self: *Builder, expression_: *const Ast.Expression, checked_type: Type, members: []const *const Ast.Expression, entries: []const Ast.Expression.Entry) Error!Value {
        const set = checked_type.kind == .set;
        const key_checked = if (set) checked_type.element.?.* else checked_type.key.?.*;
        const key_type = payloadType(key_checked) orelse return self.owner.fail(expression_.span, "a dictionary of this type");
        const value_type: Ir.Type = if (set) .nothing else payloadType(checked_type.element.?.*) orelse return self.owner.fail(expression_.span, "a dictionary of this type");
        if (key_type == .nothing) return self.owner.fail(expression_.span, "a dictionary of this type");
        const result = try self.temporary(.map);
        try self.emit(expression_.span, .{ .map_new = .{ .destination = .{ .local = result }, .key = key_type, .value = value_type, .set = set } });
        for (members) |member| {
            const key = try self.expression(member);
            try self.emit(member.span, .{ .map_put = .{ .map = .{ .local = result }, .key = .{ .operand = key.operand, .type = key.type }, .value = .{ .operand = .nothing, .type = .optional }, .site = try self.owner.site(member.span) } });
        }
        for (entries) |entry| {
            const key = try self.expression(entry.key);
            const value = try self.expression(entry.value);
            try self.emit(entry.key.span, .{ .map_put = .{ .map = .{ .local = result }, .key = .{ .operand = key.operand, .type = key.type }, .value = .{ .operand = value.operand, .type = value.type }, .site = try self.owner.site(entry.key.span) } });
        }
        return .{ .operand = .{ .local = result }, .type = .map };
    }

    /// `dictionary[key] = value`, or `dictionary[key] += value`, on a
    /// dictionary a variable holds; a compound assignment needs the entry to
    /// be there already. The runtime widens what it stores to the map's kinds.
    fn entryAssignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment, target: Ir.Place) Error!void {
        const key_expression = assignment_.steps[0].index;
        const key = try self.expression(key_expression);
        const typed_key: Ir.Typed = .{ .operand = key.operand, .type = key.type };
        const value: Value = if (assignment_.operation) |operation| blk: {
            const value_type = self.elementOfPlace(assignment_) orelse return self.owner.fail(assignment_.target_span, "assigning into this");
            const current = try self.temporary(value_type);
            try self.emit(span, .{ .map_get_existing = .{ .destination = .{ .local = current }, .map = operandOf(target), .key = typed_key, .payload = value_type, .site = try self.owner.site(key_expression.span) } });
            const right = try self.expression(assignment_.value);
            break :blk try self.binary(assignment_.target_span, operation, .{ .operand = .{ .local = current }, .type = value_type }, right);
        } else try self.expression(assignment_.value);
        if (value.type == .nothing) return self.owner.fail(assignment_.value.span, "storing `nothing` here");
        try self.emit(span, .{ .map_set = .{ .target = target, .key = typed_key, .value = .{ .operand = value.operand, .type = value.type }, .site = try self.owner.site(key_expression.span) } });
    }

    /// One of section 8.5's methods that change a dictionary or set, on a
    /// variable that holds one. A failure is reported at the first argument.
    fn mapChange(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, member_: Ast.Expression.Member, change: MapMethods.Change, result_type: Ir.Type, discarded: bool) Error!?Value {
        if (call_.arguments.len == 0 or call_.arguments.len > 8) return self.owner.fail(expression_.span, "this call");
        const path = try self.preparePath(member_.base);
        const arguments = try self.arena().alloc(Ir.Typed, call_.arguments.len);
        for (call_.arguments, arguments) |argument, *out| {
            const value = try self.expression(argument);
            if (value.type == .nothing) return self.owner.fail(argument.span, "this argument");
            out.* = .{ .operand = value.operand, .type = value.type };
        }
        const destination: ?Ir.Local = if (discarded or result_type == .nothing) null else try self.temporary(result_type);
        const opened = try self.openPath(path);
        try self.emit(expression_.span, .{ .map_change = .{
            .target = opened.place,
            .method = @backingInt(change),
            .arguments = arguments,
            .destination = if (destination) |local| .{ .local = local } else null,
            .result = result_type,
            .site = try self.owner.site(call_.arguments[0].span),
        } });
        try self.closePath(path, opened);
        return if (destination) |local| .{ .operand = .{ .local = local }, .type = result_type } else null;
    }

    /// The struct a field step names, its info and the field's position.
    fn fieldOf(self: *Builder, base: *const Ast.Expression, name: []const u8) ?struct { info: *StructInfo, position: u32 } {
        // `self` is the struct being built or changed, which the checker may
        // not have typed as an expression of its own (a field default's).
        const info = if (base.data == .name and std.mem.eql(u8, base.data.name, "self") and self.self_struct != null)
            self.self_struct.?
        else blk: {
            const found = self.owner.checked.expression_types.get(base) orelse return null;
            const user = found.type.user orelse return null;
            break :blk self.owner.struct_infos.get(user.name) orelse return null;
        };
        for (info.fields, 0..) |field, position| {
            if (std.mem.eql(u8, field.name, name)) return .{ .info = info, .position = @intCast(position) };
        }
        return null;
    }

    /// Section 10.1's `value.field`.
    fn fieldRead(self: *Builder, expression_: *const Ast.Expression, member_: Ast.Expression.Member) Error!Value {
        const field = self.fieldOf(member_.base, member_.name) orelse return self.owner.fail(expression_.span, "this member");
        const type_ = self.checkedType(expression_) orelse field.info.fields[field.position].type;
        const base = try self.expression(member_.base);
        const stored = field.info.fields[field.position].type;
        const result = try self.temporary(stored);
        try self.emit(expression_.span, .{ .struct_get = .{ .destination = .{ .local = result }, .operand = base.operand, .position = field.position, .type = stored } });
        // A narrowed optional field is read as its payload (4.5).
        if (stored == .optional and type_ != .optional) return self.unwrap(expression_.span, .{ .local = result }, type_);
        return .{ .operand = .{ .local = result }, .type = stored };
    }

    /// `value.field = new`, or `value.field += new`, on a struct a variable
    /// (or `self`, in a changing method) holds.
    fn fieldAssignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment) Error!void {
        const target = try self.place(assignment_.name, assignment_.name_span);
        if (target.type != .structure) return self.owner.fail(assignment_.target_span, "assigning into this");
        const step = assignment_.steps[0].field;
        // The struct's type, from the declaration of what holds it.
        const info = self.structOfPlace(assignment_.name, target.place) orelse return self.owner.fail(assignment_.target_span, "assigning into this");
        const position: u32 = for (info.fields, 0..) |field, at| {
            if (std.mem.eql(u8, field.name, step.name)) break @intCast(at);
        } else return self.owner.fail(step.span, "assigning into this");
        const field = info.fields[position];
        const value: Ir.Operand = if (assignment_.operation) |operation| blk: {
            const current = try self.temporary(field.type);
            try self.emit(span, .{ .struct_get = .{ .destination = .{ .local = current }, .operand = operandOf(target.place), .position = position, .type = field.type } });
            const right = try self.expression(assignment_.value);
            const result = try self.binary(assignment_.target_span, operation, .{ .operand = .{ .local = current }, .type = field.type }, right);
            break :blk try self.convertTo(result, field.type, field.payload, span);
        } else try self.convertTo(try self.expression(assignment_.value), field.type, field.payload, assignment_.value.span);
        try self.emit(span, .{ .struct_set = .{ .target = target.place, .position = position, .value = .{ .operand = value, .type = field.type } } });
    }

    /// The struct type a variable holding a struct has: `self`'s for a
    /// method, or its declaration's.
    fn structOfPlace(self: *Builder, name: []const u8, at: Ir.Place) ?*StructInfo {
        if (at == .self_ref or (std.mem.eql(u8, name, "self") and self.self_struct != null)) return self.self_struct;
        return switch (at) {
            .local => |local| self.struct_types.get(local),
            .global => |global| self.owner.global_structs.get(global),
            .self_ref => self.self_struct,
        };
    }

    /// Section 10.2: a struct built from its fields, by position or by name,
    /// with each left-out field's default run afterwards; or by its own
    /// constructor, after every default has run.
    fn construct(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, info: *StructInfo) Error!Value {
        const result = try self.temporary(.structure);
        // The arguments are evaluated first, in the order written.
        const written = try self.arena().alloc(Value, call_.arguments.len);
        for (call_.arguments, written) |argument, *value| value.* = try self.expression(argument);
        const call_site = try self.owner.site(expression_.span);

        if (info.constructor) |constructor| {
            const declared = info.declaration.constructor.?.parameters;
            const names = try self.arena().alloc([]const u8, declared.len);
            for (declared, names) |parameter, *name| name.* = parameter.name;
            const positions = try self.bindArguments(call_, names, try self.arena().alloc(bool, declared.len));
            const fields = try self.unsetFields(info);
            try self.emit(expression_.span, .{ .struct_new = .{ .destination = .{ .local = result }, .type_index = info.index, .fields = fields } });
            if (info.defaults) |defaults| try self.runDefaults(expression_.span, defaults, result, info.has_default, call_site);
            const arguments = try self.arena().alloc(Ir.Operand, declared.len);
            for (positions, constructor.parameters, constructor.payloads, arguments) |position, parameter, payload, *out| {
                const value = written[position orelse return self.owner.fail(expression_.span, "leaving out an argument")];
                out.* = try self.convertTo(value, parameter, payload, expression_.span);
            }
            try self.emit(expression_.span, .{ .call = .{ .function = constructor.index, .arguments = arguments, .destination = null, .site = call_site, .self_slot = .{ .local = result } } });
            return .{ .operand = .{ .local = result }, .type = .structure };
        }

        const positions = try self.bindArguments(call_, info.field_names, info.has_default);
        const fields = try self.arena().alloc(Ir.Typed, info.fields.len);
        const omitted = try self.arena().alloc(bool, info.fields.len);
        var any_omitted = false;
        for (positions, info.fields, fields, omitted) |position, field, *out, *left| {
            left.* = position == null;
            any_omitted = any_omitted or left.*;
            out.* = if (position) |index|
                .{ .operand = try self.convertTo(written[index], field.type, field.payload, expression_.span), .type = field.type }
            else
                .{ .operand = .nothing, .type = .optional };
        }
        try self.emit(expression_.span, .{ .struct_new = .{ .destination = .{ .local = result }, .type_index = info.index, .fields = fields } });
        if (any_omitted) try self.runDefaults(expression_.span, info.defaults.?, result, omitted, call_site);
        return .{ .operand = .{ .local = result }, .type = .structure };
    }

    /// Which written argument fills each parameter, as the interpreter binds
    /// them (`arguments.zig`): positional first, then by name.
    fn bindArguments(self: *Builder, call_: Ast.Expression.Call, names: []const []const u8, has_default: []const bool) Error![]const ?usize {
        const positions = try self.arena().alloc(?usize, names.len);
        if (call_arguments.isPlain(call_, names.len)) {
            for (positions, 0..) |*position, index| position.* = index;
            return positions;
        }
        if (call_arguments.bind(call_, names, has_default, positions) != .none) return self.owner.fail(call_.callee.span, "this call");
        return positions;
    }

    fn unsetFields(self: *Builder, info: *StructInfo) Error![]const Ir.Typed {
        const fields = try self.arena().alloc(Ir.Typed, info.fields.len);
        @memset(fields, .{ .operand = .nothing, .type = .optional });
        return fields;
    }

    /// Runs the field defaults whose flags are set, on the struct in `local`.
    fn runDefaults(self: *Builder, span: Source.Span, defaults: FunctionInfo, local: Ir.Local, which: []const bool, call_site: Ir.Site) Error!void {
        const flags = try self.arena().alloc(Ir.Operand, which.len);
        for (which, flags) |runs, *flag| flag.* = .{ .bool = runs };
        // A site of its own: each call's trace frame is its own.
        _ = call_site;
        try self.emit(span, .{ .call = .{ .function = defaults.index, .arguments = flags, .destination = null, .site = try self.owner.site(span), .self_slot = .{ .local = local } } });
    }

    /// A struct's own method. One that changes `self` is given the struct by
    /// reference, from the variable that holds it.
    fn structMethod(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, member_: Ast.Expression.Member, called: MethodInfo, discarded: bool) Error!?Value {
        const method_info = called;
        const declared = method_info.declaration.parameters;
        const names = try self.arena().alloc([]const u8, declared.len);
        for (declared, names) |parameter, *name| name.* = parameter.name;
        const positions = try self.bindArguments(call_, names, try self.arena().alloc(bool, declared.len));
        var self_slot: ?Ir.Place = null;
        var receiver: ?Ir.Operand = null;
        if (method_info.changing) {
            if (member_.base.data != .name) return self.owner.fail(expression_.span, "changing a struct that is not a variable");
            const name = member_.base.data.name;
            const target = try self.place(name, member_.base.span);
            if (target.place == .global and self.owner.mentionedInBodies(name)) return self.owner.fail(expression_.span, "this changing method on a module variable another function names");
            self_slot = target.place;
        } else receiver = (try self.expression(member_.base)).operand;
        const offset: usize = if (method_info.changing) 0 else 1;
        const arguments = try self.arena().alloc(Ir.Operand, offset + declared.len);
        if (receiver) |operand| arguments[0] = operand;
        // Evaluated in the order written, then placed by parameter.
        const written = try self.arena().alloc(Value, call_.arguments.len);
        for (call_.arguments, written) |argument, *value| value.* = try self.expression(argument);
        for (positions, method_info.function.parameters[offset..], method_info.function.payloads[offset..], arguments[offset..]) |position, parameter, payload, *out| {
            const value = written[position orelse return self.owner.fail(expression_.span, "leaving out an argument")];
            out.* = try self.convertTo(value, parameter, payload, expression_.span);
        }
        const result = method_info.function.result;
        const destination: ?Ir.Local = if (result == .nothing or discarded) null else try self.temporary(result);
        try self.emit(expression_.span, .{ .call = .{
            .function = method_info.function.index,
            .arguments = arguments,
            .destination = if (destination) |local| .{ .local = local } else null,
            .site = try self.owner.site(expression_.span),
            .self_slot = self_slot,
        } });
        return if (destination) |local| .{ .operand = .{ .local = local }, .type = result } else null;
    }

    /// Section 4.5's `value.or(default)`: the optional's value when it holds
    /// one, else the default, which is evaluated only then.
    fn orDefault(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, member_: Ast.Expression.Member) Error!?Value {
        const result_type = self.checkedType(expression_) orelse return self.owner.fail(expression_.span, "this `or`");
        const found = self.owner.checked.expression_types.get(member_.base) orelse return self.owner.fail(expression_.span, "this `or`");
        const payload = payloadType(found.type) orelse return self.owner.fail(expression_.span, "this `or`");
        const optional = try self.expression(member_.base);
        const result = try self.temporary(result_type);
        const holds = try self.temporary(.bool);
        try self.emit(expression_.span, .{ .present = .{ .destination = .{ .local = holds }, .operand = optional.operand } });
        const present_block = try self.newBlock();
        const absent_block = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .branch = .{ .condition = .{ .local = holds }, .then = present_block, .otherwise = absent_block } });

        self.switchTo(present_block);
        const value = try self.unwrap(expression_.span, optional.operand, payload);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = try self.convert(value, result_type, expression_.span) } });
        self.terminate(.{ .jump = after });

        self.switchTo(absent_block);
        const default = try self.expression(call_.arguments[0]);
        try self.emit(expression_.span, .{ .move = .{ .destination = .{ .local = result }, .source = try self.convert(default, result_type, call_.arguments[0].span) } });
        self.terminate(.{ .jump = after });
        self.switchTo(after);
        return .{ .operand = .{ .local = result }, .type = result_type };
    }

    /// Section 8.2's `(a, b)`, each item as the checker typed its position.
    fn tupleLiteral(self: *Builder, expression_: *const Ast.Expression, items: []const *const Ast.Expression) Error!Value {
        const found = self.owner.checked.expression_types.get(expression_) orelse return self.owner.fail(expression_.span, "this tuple");
        if (found.type.kind != .tuple or found.type.elements.len != items.len) return self.owner.fail(expression_.span, "this tuple");
        const typed = try self.arena().alloc(Ir.Typed, items.len);
        for (items, found.type.elements, typed) |item, element, *out| {
            const type_ = irType(element) orelse return self.owner.fail(item.span, "a tuple holding this");
            out.* = .{ .operand = try self.convertTo(try self.expression(item), type_, payloadType(element), item.span), .type = type_ };
        }
        const result = try self.temporary(.tuple);
        try self.emit(expression_.span, .{ .tuple_new = .{ .destination = .{ .local = result }, .items = typed } });
        return .{ .operand = .{ .local = result }, .type = .tuple };
    }

    /// Section 8.2's `var (name, age) = entry`: each position into a new
    /// variable, or at the top of the entry file, a module variable.
    fn destructuring(self: *Builder, destructured: Ast.Destructuring) Error!void {
        const types = try self.owner.patternTypes(destructured.pattern, destructured.initializer);
        const tuple = try self.expression(destructured.initializer);
        for (destructured.pattern.positions, types, 0..) |position, type_, index| {
            const name = position.name.text;
            const destination: Ir.Place = if (self.top_level and self.scopes.items.len == 1)
                .{ .global = self.owner.global_keys.get(self.owner.keyOf(name)).? }
            else blk: {
                const local = try self.newLocal(name, type_);
                try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), name, local);
                break :blk .{ .local = local };
            };
            const item = try self.temporary(type_);
            try self.emit(position.name.span, .{ .tuple_get = .{ .destination = .{ .local = item }, .tuple = tuple.operand, .position = @intCast(index), .type = type_ } });
            try self.emit(position.name.span, .{ .move = .{ .destination = destination, .source = .{ .local = item } } });
        }
    }

    /// Section 8.2's `(left, right) = (right, left)`: the whole value first,
    /// then each position into the variable named there.
    fn destructuringAssignment(self: *Builder, span: Source.Span, destructured: Ast.DestructuringAssignment) Error!void {
        const types = try self.owner.patternTypes(destructured.pattern, destructured.value);
        const tuple = try self.expression(destructured.value);
        for (destructured.pattern.positions, types, 0..) |position, type_, index| {
            const target = try self.place(position.name.text, position.name.span);
            const item = try self.temporary(type_);
            try self.emit(span, .{ .tuple_get = .{ .destination = .{ .local = item }, .tuple = tuple.operand, .position = @intCast(index), .type = type_ } });
            const stored = try self.convert(.{ .operand = .{ .local = item }, .type = type_ }, target.type, span);
            try self.emit(span, .{ .move = .{ .destination = target.place, .source = stored } });
        }
    }

    /// One of section 8's methods that change a list, on a variable that holds
    /// one; the runtime copies the list first if anything else shares it.
    fn listMutation(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, member_: Ast.Expression.Member, mutation: ListMethods.Mutation, result_type: Ir.Type, discarded: bool) Error!?Value {
        if (call_.arguments.len > 8) return self.owner.fail(expression_.span, "this many arguments");
        const path = try self.preparePath(member_.base);
        const arguments = try self.arena().alloc(Ir.Typed, call_.arguments.len);
        for (call_.arguments, arguments) |argument, *out| {
            const value = try self.expression(argument);
            if (value.type == .nothing) return self.owner.fail(argument.span, "this argument");
            out.* = .{ .operand = value.operand, .type = value.type };
        }
        const destination: ?Ir.Local = if (discarded or result_type == .nothing) null else try self.temporary(result_type);
        const opened = try self.openPath(path);
        try self.emit(expression_.span, .{ .list_mutate = .{
            .target = opened.place,
            .method = @backingInt(mutation),
            .arguments = arguments,
            .destination = if (destination) |local| .{ .local = local } else null,
            .result = result_type,
            .site = try self.owner.site(expression_.span),
        } });
        try self.closePath(path, opened);
        return if (destination) |local| .{ .operand = .{ .local = local }, .type = result_type } else null;
    }

    /// The checker's type of what a variable holds.
    fn checkedOf(self: *Builder, at: Ir.Place) ?Type {
        const found = switch (at) {
            .local => |local| self.checked_types.get(local),
            .global => |global| self.owner.global_checked.get(global),
            .self_ref => if (self.self_struct) |info| self.owner.checked.structs.get(info.key) else null,
        } orelse return null;
        // A declaration's initializer can have a narrower type than the
        // variable holds, such as a `Point` in a `Point?`; a path is walked
        // only from the type the variable's slot actually has.
        const slot: Ir.Type = switch (at) {
            .local => |local| self.locals.items[local].type,
            .global => |global| self.owner.globals.items[global].type,
            .self_ref => .structure,
        };
        if (irType(found) != slot) return null;
        return found;
    }

    /// One step of a path: where it goes in the container before it.
    const Hop = struct {
        step: Ir.Instruction.PathStep,
        container: Ir.Type,
        /// The checker's type of what the step reaches.
        child: Type,
        site: Ir.Site,
    };

    /// A path's root variable and the steps from it, each index evaluated.
    const PreparedPath = struct {
        root: Ir.Place,
        hops: []const Hop,
    };

    /// The steps of a path from its root, from the checker's types: each
    /// index is evaluated in order, as the interpreter evaluates them before
    /// it walks the path.
    fn resolvePath(self: *Builder, root_type: Type, steps: []const Ast.Step) Error![]const Hop {
        const hops = try self.arena().alloc(Hop, steps.len);
        var current = root_type;
        for (steps, hops) |step, *hop| {
            if (current.optional) return self.owner.fail(stepSpan(step), "a path through an optional");
            switch (current.kind) {
                .struct_value => {
                    if (step != .field) return self.owner.fail(stepSpan(step), "this path");
                    const user = current.user orelse return self.owner.fail(stepSpan(step), "this path");
                    if (self.owner.struct_infos.get(user.name) == null) return self.owner.fail(stepSpan(step), "a path through this type");
                    const position = for (user.fields, 0..) |field, at| {
                        if (std.mem.eql(u8, field.name, step.field.name)) break at;
                    } else return self.owner.fail(step.field.span, "this path");
                    hop.* = .{ .step = .{ .field = @intCast(position) }, .container = .structure, .child = user.fields[position].type, .site = try self.owner.site(step.field.span) };
                },
                .list => {
                    if (step != .index) return self.owner.fail(stepSpan(step), "this path");
                    const position = try self.convert(try self.expression(step.index), .int, step.index.span);
                    hop.* = .{ .step = .{ .index = position }, .container = .list, .child = current.element.?.*, .site = try self.owner.site(step.index.span) };
                },
                .dictionary => {
                    if (step != .index) return self.owner.fail(stepSpan(step), "this path");
                    const key = try self.expression(step.index);
                    hop.* = .{ .step = .{ .key = .{ .operand = key.operand, .type = key.type } }, .container = .map, .child = current.element.?.*, .site = try self.owner.site(step.index.span) };
                },
                else => return self.owner.fail(stepSpan(step), "a path through this value"),
            }
            if (irType(hop.child) == null) return self.owner.fail(stepSpan(step), "a path through this value");
            current = hop.child;
        }
        return hops;
    }

    fn stepSpan(step: Ast.Step) Source.Span {
        return switch (step) {
            .index => |index| index.span,
            .field => |field| field.span,
        };
    }

    /// A receiver written as a path, such as `self.items` or `grid[row]`:
    /// its root variable and its steps, each index evaluated in order.
    fn preparePath(self: *Builder, receiver: *const Ast.Expression) Error!PreparedPath {
        var steps: std.ArrayList(Ast.Step) = .empty;
        var at = receiver;
        while (true) switch (at.data) {
            .name => break,
            .member => |member_| {
                if (member_.optional or member_.position != null) return self.owner.fail(receiver.span, "changing a value through this path");
                try steps.insert(self.arena(), 0, .{ .field = .{ .name = member_.name, .span = member_.name_span } });
                at = member_.base;
            },
            .index => |index_| {
                try steps.insert(self.arena(), 0, .{ .index = index_.index });
                at = index_.base;
            },
            else => return self.owner.fail(receiver.span, "changing a value through this path"),
        };
        const target = try self.place(at.data.name, at.span);
        if (steps.items.len == 0) return .{ .root = target.place, .hops = &.{} };
        const root_type = self.checkedOf(target.place) orelse return self.owner.fail(receiver.span, "changing a value through this path");
        return .{ .root = target.place, .hops = try self.resolvePath(root_type, steps.items) };
    }

    const OpenedPath = struct {
        /// The innermost container, ready to change.
        place: Ir.Place,
        temporaries: []const Ir.Local,
    };

    /// Takes each container on the path out of the one holding it, ending
    /// with the place of what the last step reaches.
    fn openPath(self: *Builder, path: PreparedPath) Error!OpenedPath {
        const temporaries = try self.arena().alloc(Ir.Local, path.hops.len);
        var container = path.root;
        for (path.hops, temporaries) |hop, *temporary_| {
            temporary_.* = try self.temporary(irType(hop.child).?);
            try self.emit(self.owner.sites.items[hop.site], .{ .take = .{ .destination = .{ .local = temporary_.* }, .container = container, .container_type = hop.container, .step = hop.step, .site = hop.site } });
            container = .{ .local = temporary_.* };
        }
        return .{ .place = container, .temporaries = temporaries };
    }

    /// Puts back what `openPath` took, innermost first.
    fn closePath(self: *Builder, path: PreparedPath, opened: OpenedPath) Error!void {
        var index = path.hops.len;
        while (index > 0) {
            index -= 1;
            const hop = path.hops[index];
            const container: Ir.Place = if (index == 0) path.root else .{ .local = opened.temporaries[index - 1] };
            const value: Ir.Typed = .{ .operand = .{ .local = opened.temporaries[index] }, .type = irType(hop.child).? };
            try self.emit(self.owner.sites.items[hop.site], .{ .put = .{ .container = container, .container_type = hop.container, .step = hop.step, .value = value, .site = hop.site } });
        }
    }

    /// Reads what `hop` reaches in `container`, into a new temporary.
    fn readHop(self: *Builder, container: Ir.Operand, hop: Hop) Error!Ir.Operand {
        const type_ = irType(hop.child).?;
        const result = try self.temporary(type_);
        const span = self.owner.sites.items[hop.site];
        try self.emit(span, switch (hop.step) {
            .field => |position| .{ .struct_get = .{ .destination = .{ .local = result }, .operand = container, .position = position, .type = type_ } },
            .index => |position| .{ .list_get = .{ .destination = .{ .local = result }, .list = container, .position = position, .element = type_, .site = hop.site } },
            .key => |key| .{ .map_get_existing = .{ .destination = .{ .local = result }, .map = container, .key = key, .payload = type_, .site = hop.site } },
        });
        return .{ .local = result };
    }

    /// Section 8 and 10's assignment through a path of two or more steps,
    /// `line.start.x = 9.5` or `grid[row][column] += 1`, in the interpreter's
    /// order: every index, then for a compound assignment the current value,
    /// then the right side, then the store along the path.
    fn pathAssignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment) Error!void {
        const target = try self.place(assignment_.name, assignment_.name_span);
        const root_type = self.checkedOf(target.place) orelse return self.owner.fail(assignment_.target_span, "assigning through this path");
        const hops = try self.resolvePath(root_type, assignment_.steps);
        const last = hops[hops.len - 1];
        const final_type = irType(last.child).?;
        const final_payload = if (last.child.optional) payloadType(last.child) else null;
        const value: Ir.Operand = if (assignment_.operation) |operation| blk: {
            var current: Ir.Operand = operandOf(target.place);
            for (hops) |hop| current = try self.readHop(current, hop);
            const right = try self.expression(assignment_.value);
            const result = try self.binary(assignment_.target_span, operation, .{ .operand = current, .type = final_type }, right);
            break :blk try self.convertTo(result, final_type, final_payload, span);
        } else try self.convertTo(try self.expression(assignment_.value), final_type, final_payload, assignment_.value.span);
        const path: PreparedPath = .{ .root = target.place, .hops = hops[0 .. hops.len - 1] };
        const opened = try self.openPath(path);
        const typed: Ir.Typed = .{ .operand = value, .type = final_type };
        try self.emit(span, switch (last.step) {
            .field => |position| .{ .struct_set = .{ .target = opened.place, .position = position, .value = typed } },
            .index => |position| .{ .list_set = .{ .target = opened.place, .position = position, .value = typed, .site = last.site } },
            .key => |key| .{ .map_set = .{ .target = opened.place, .key = key, .value = typed, .site = last.site } },
        });
        try self.closePath(path, opened);
    }

    /// `items[position] = value`, or `items[position] += value`, on a list a
    /// variable holds.
    fn elementAssignment(self: *Builder, span: Source.Span, assignment_: Ast.Assignment) Error!void {
        if (assignment_.steps.len > 1) return self.pathAssignment(span, assignment_);
        if (assignment_.steps.len == 1 and assignment_.steps[0] == .field) return self.fieldAssignment(span, assignment_);
        if (assignment_.steps.len != 1 or assignment_.steps[0] != .index) return self.owner.fail(assignment_.target_span, "assigning into a nested collection or a field");
        const target = try self.place(assignment_.name, assignment_.name_span);
        if (target.type == .map) return self.entryAssignment(span, assignment_, target.place);
        if (target.type != .list) return self.owner.fail(assignment_.target_span, "assigning into this");
        const index_expression = assignment_.steps[0].index;
        const at = try self.convert(try self.expression(index_expression), .int, index_expression.span);
        // The element's type, which the checker knows as the value's target.
        const element = self.elementOfPlace(assignment_) orelse return self.owner.fail(assignment_.target_span, "assigning into this");
        const value: Ir.Operand = if (assignment_.operation) |operation| blk: {
            const current = try self.temporary(element);
            try self.emit(span, .{ .list_get = .{ .destination = .{ .local = current }, .list = operandOf(target.place), .position = at, .element = element, .site = try self.owner.site(index_expression.span) } });
            const right = try self.expression(assignment_.value);
            const result = try self.binary(assignment_.target_span, operation, .{ .operand = .{ .local = current }, .type = element }, right);
            break :blk try self.convert(result, element, span);
        } else try self.convert(try self.expression(assignment_.value), element, assignment_.value.span);
        try self.emit(span, .{ .list_set = .{ .target = target.place, .position = at, .value = .{ .operand = value, .type = element }, .site = try self.owner.site(index_expression.span) } });
    }

    /// The element type of the list variable an element assignment changes,
    /// as its declaration settled it.
    fn elementOfPlace(self: *Builder, assignment_: Ast.Assignment) ?Ir.Type {
        if (self.find(assignment_.name)) |local| return self.element_types.get(local);
        return self.owner.global_elements.get(self.owner.keyOf(assignment_.name));
    }

    /// Section 6.4's `for` over a list: over the list as it was when the loop
    /// began, which the loop holds, so changing the variable inside does not
    /// change what it visits.
    fn forList(self: *Builder, loop: Ast.For) Error!void {
        const element = self.elementType(loop.iterable) orelse return self.owner.fail(loop.iterable.span, "a `for` over this list");
        const iterated = try self.expression(loop.iterable);
        const item_type = self.owner.checked.expression_types.get(loop.iterable).?.type.element.?.*;
        return self.forItems(loop, iterated.operand, element, item_type);
    }

    /// Section 8.4's `for` over a dictionary or set: over its items as they
    /// were when the loop began, in insertion order, a set's members or a
    /// dictionary's `(key, value)` tuples.
    fn forMap(self: *Builder, loop: Ast.For) Error!void {
        const checked_type = self.owner.checked.expression_types.get(loop.iterable).?.type;
        const map = try self.expression(loop.iterable);
        const items = try self.temporary(.list);
        try self.emit(loop.iterable.span, .{ .map_items = .{ .destination = .{ .local = items }, .map = map.operand } });
        if (checked_type.kind == .set) {
            const element = irType(checked_type.element.?.*) orelse return self.owner.fail(loop.iterable.span, "a `for` over this set");
            return self.forItems(loop, .{ .local = items }, element, checked_type.element.?.*);
        }
        const positions = try self.arena().dupe(Type, &.{ checked_type.key.?.*, checked_type.element.?.* });
        return self.forItems(loop, .{ .local = items }, .tuple, .{ .kind = .tuple, .elements = positions });
    }

    /// Section 9.1's `for` over a string: each character, a string of its own.
    fn forString(self: *Builder, loop: Ast.For) Error!void {
        if (loop.pattern != null) return self.owner.fail(loop.name_span, "a `for` with a pattern");
        const text = try self.expression(loop.iterable);
        const characters = try self.temporary(.list);
        try self.emit(loop.iterable.span, .{ .string_characters = .{ .destination = .{ .local = characters }, .operand = text.operand } });
        return self.forItems(loop, .{ .local = characters }, .string, .{ .kind = .string });
    }

    /// The loop over a list's items that every `for` but a range's becomes;
    /// `item_type` is the checker's type of one item, for a pattern.
    fn forItems(self: *Builder, loop: Ast.For, iterated: Ir.Operand, element: Ir.Type, item_type: Type) Error!void {
        const span = loop.iterable.span;
        const list = try self.temporary(.list);
        try self.emit(span, .{ .move = .{ .destination = .{ .local = list }, .source = iterated } });
        const count = try self.temporary(.int);
        try self.emit(span, .{ .list_count = .{ .destination = .{ .local = count }, .list = .{ .local = list } } });
        const position = try self.temporary(.int);
        try self.emit(span, .{ .move = .{ .destination = .{ .local = position }, .source = .{ .int = 0 } } });

        const head = try self.newBlock();
        const body = try self.newBlock();
        const step = try self.newBlock();
        const after = try self.newBlock();
        self.terminate(.{ .jump = head });
        self.switchTo(head);
        const more = try self.temporary(.bool);
        try self.emit(span, .{ .compare = .{ .operator = .less, .kind = .int, .destination = .{ .local = more }, .left = .{ .local = position }, .right = .{ .local = count } } });
        self.terminate(.{ .branch = .{ .condition = .{ .local = more }, .then = body, .otherwise = after } });

        self.switchTo(body);
        try self.pushScope();
        const variable = try self.newLocal(if (loop.pattern != null) "" else loop.name, element);
        try self.checked_types.put(self.arena(), variable, item_type);
        if (loop.pattern == null) try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), loop.name, variable);
        try self.emit(loop.name_span, .{ .list_get = .{ .destination = .{ .local = variable }, .list = .{ .local = list }, .position = .{ .local = position }, .element = element, .site = try self.owner.site(span) } });
        // `for (name, score) in pairs`: each tuple taken apart into locals.
        if (loop.pattern) |pattern| {
            const tuple_type = item_type;
            if (tuple_type.kind != .tuple or tuple_type.optional or tuple_type.elements.len != pattern.positions.len) return self.owner.fail(pattern.span, "this destructuring");
            for (pattern.positions, tuple_type.elements, 0..) |pattern_position, position_type, index| {
                if (pattern_position != .name) return self.owner.fail(pattern.span, "a nested pattern");
                const type_ = irType(position_type) orelse return self.owner.fail(pattern.span, "this destructuring");
                const local = try self.newLocal(pattern_position.name.text, type_);
                try self.scopes.items[self.scopes.items.len - 1].put(self.arena(), pattern_position.name.text, local);
                try self.emit(pattern.span, .{ .tuple_get = .{ .destination = .{ .local = local }, .tuple = .{ .local = variable }, .position = @intCast(index), .type = type_ } });
            }
        }
        try self.loops.append(self.arena(), .{ .break_to = after, .continue_to = step });
        try self.block(loop.body);
        _ = self.loops.pop();
        self.popScope();
        self.terminate(.{ .jump = step });

        self.switchTo(step);
        try self.emit(span, .{ .int_arithmetic = .{ .operator = .add, .destination = .{ .local = position }, .left = .{ .local = position }, .right = .{ .int = 1 }, .site = try self.owner.site(span) } });
        self.terminate(.{ .jump = head });
        self.switchTo(after);
    }

    /// A method on a string or a number, which the runtime's `Natives.zig`
    /// answers as it does for the interpreter, or `to_string` on a scalar,
    /// which is its display.
    fn method(self: *Builder, expression_: *const Ast.Expression, call_: Ast.Expression.Call, member_: Ast.Expression.Member, discarded: bool) Error!?Value {
        if (member_.optional or member_.position != null) return self.owner.fail(expression_.span, "this call");
        if (self.owner.checked.method_calls.get(call_.callee)) |key| {
            if (self.owner.methods.get(key)) |method_info| return try self.structMethod(expression_, call_, member_, method_info, discarded);
            return self.owner.fail(expression_.span, "a method of this type");
        }
        const receiver_type = self.checkedType(member_.base) orelse return self.owner.fail(expression_.span, "a method of this value");
        if (receiver_type == .optional) {
            if (!std.mem.eql(u8, member_.name, "or") or call_.arguments.len != 1) return self.owner.fail(expression_.span, "this method on an optional");
            return try self.orDefault(expression_, call_, member_);
        }
        const result_type = self.checkedType(expression_) orelse return self.owner.fail(expression_.span, "a method giving this value");
        const name = member_.name;

        // `to_string` with no arguments on an `Int`, a `Float` or a `Bool` is
        // its display; `Int`'s with a base, and `format`, take named
        // arguments the interpreter binds itself.
        const scalar = receiver_type == .int or receiver_type == .float or receiver_type == .bool;
        if (scalar and std.mem.eql(u8, name, "to_string")) {
            if (call_.arguments.len != 0) return self.owner.fail(expression_.span, "`to_string` with a base");
            const value = try self.expression(member_.base);
            const result = try self.temporary(.string);
            const part: Ir.Instruction.Write = switch (receiver_type) {
                .int => .{ .int = value.operand },
                .float => .{ .float = value.operand },
                else => .{ .bool = value.operand },
            };
            try self.emit(expression_.span, .{ .format = .{ .destination = .{ .local = result }, .parts = try self.arena().dupe(Ir.Instruction.Write, &.{part}) } });
            return .{ .operand = .{ .local = result }, .type = .string };
        }
        if (std.mem.eql(u8, name, "format")) return self.owner.fail(expression_.span, "`format`");

        if (receiver_type == .list) {
            if (std.meta.stringToEnum(ListMethods.Mutation, name)) |mutation| return self.listMutation(expression_, call_, member_, mutation, result_type, discarded);
        }
        if (receiver_type == .map) {
            if (std.meta.stringToEnum(MapMethods.Change, name)) |change| return self.mapChange(expression_, call_, member_, change, result_type, discarded);
        }
        const id: Natives.Id = switch (receiver_type) {
            .map => Natives.lookup(.map, name),
            .list => Natives.lookup(.list, name),
            .string => Natives.lookup(.string, name),
            .int => Natives.lookup(.int, name),
            .float => Natives.lookup(.float, name),
            else => null,
        } orelse return self.owner.fail(expression_.span, "this method");
        if (call_.arguments.len > 8) return self.owner.fail(expression_.span, "this many arguments");

        const receiver = try self.expression(member_.base);
        const arguments = try self.arena().alloc(Ir.Typed, call_.arguments.len);
        for (call_.arguments, arguments) |argument, *out| {
            const value = try self.expression(argument);
            if (value.type == .nothing) return self.owner.fail(argument.span, "this argument");
            out.* = .{ .operand = value.operand, .type = value.type };
        }
        const destination: ?Ir.Local = if (discarded or result_type == .nothing) null else try self.temporary(result_type);
        try self.emit(expression_.span, .{ .native = .{
            .family = @backingInt(std.meta.activeTag(id)),
            .method = switch (id) {
                inline else => |which| @backingInt(which),
            },
            .receiver = .{ .operand = receiver.operand, .type = receiver.type },
            .arguments = arguments,
            .destination = if (destination) |local| .{ .local = local } else null,
            .result = result_type,
            .site = try self.owner.site(expression_.span),
        } });
        return if (destination) |local| .{ .operand = .{ .local = local }, .type = result_type } else null;
    }
};

fn operandOf(place: Ir.Place) Ir.Operand {
    return switch (place) {
        .local => |local| .{ .local = local },
        .global => |global| .{ .global = global },
        .self_ref => .self_ref,
    };
}

fn isNumber(type_: Ir.Type) bool {
    return type_ == .int or type_ == .float;
}
