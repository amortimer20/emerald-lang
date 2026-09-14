//! The syntax tree.
//!
//! Section 19.2 keeps this free of runtime values, so the tree a future backend
//! consumes is the same tree the interpreter consumes. Every node carries the
//! span it came from, which diagnostics, stack traces, and later the formatter
//! and language server all read.

const std = @import("std");
const Source = @import("Source.zig");

/// A whole source file.
pub const Program = struct {
    statements: []const Statement,
    /// Section 14.2's `using` declarations. They are file-local and name no
    /// order of execution, so they are kept beside the statements rather than
    /// among them.
    using: []const Using = &.{},
};

/// Section 14.2: `using Shapes`, which makes that namespace's public names
/// directly visible here, or `using UiColor = Graphics.Color`, which gives one
/// name a short spelling. Either way it is file-local, imports only direct
/// public names, and neither includes nor executes anything.
pub const Using = struct {
    span: Source.Span,
    /// The short name this introduces, empty for the unaliased form, where
    /// every public name of `path` keeps its own spelling.
    alias: []const u8 = "",
    alias_span: Source.Span = .{ .start = 0, .end = 0 },
    /// The dotted path as written: `Graphics.Color` is `.{ "Graphics", "Color" }`.
    path: []const []const u8,
    path_span: Source.Span,
};

/// A brace-delimited sequence of statements. Section 6.1 gives every one its own
/// lexical scope.
pub const Block = struct {
    span: Source.Span,
    statements: []const Statement,
};

pub const Statement = struct {
    span: Source.Span,
    data: Data,

    pub const Data = union(enum) {
        /// An expression evaluated for its effect. Section 5.2 allows this only
        /// for calls; a pure expression whose result is unused is an error.
        expression: *const Expression,
        declaration: Declaration,
        assignment: Assignment,
        conditional: If,
        while_loop: While,
        for_loop: For,
        /// Section 6.4's `break`, holding its keyword's span.
        break_statement: Source.Span,
        /// Section 6.4's `continue`, holding its keyword's span.
        continue_statement: Source.Span,
        function_declaration: FunctionDeclaration,
        /// Section 10's user-defined value type and its stored fields.
        struct_declaration: StructDeclaration,
        return_statement: Return,
        /// Section 8.2's `var (name, age) = entry`.
        destructuring: Destructuring,
        /// Section 8.2's `(left, right) = (right, left)`, which assigns to
        /// names that already exist.
        destructuring_assignment: DestructuringAssignment,
    };
};

pub const StructDeclaration = struct {
    /// Section 10.1: a class declares a reference type with the same members a
    /// struct has. Everything that differs follows from sharing.
    class: bool = false,
    /// Section 11.1: a trait declares a contract, whose members are
    /// requirements or defaults, and stores nothing.
    trait: bool = false,
    name: []const u8,
    name_span: Source.Span,
    /// Section 10.7's `extends Animal`: the one base class a class may have.
    base: ?TypeExpression = null,
    /// Section 11.2's `with Swimmer, Flyer`: the traits adopted, or for a
    /// trait, the ones it builds on.
    traits: []const TypeExpression = &.{},
    /// Section 10.7's `@abstract`, which keeps the class from being constructed
    /// and lets its methods leave out their bodies.
    abstract_span: ?Source.Span = null,
    fields: []const Field,
    /// Section 10.2's custom constructor, which replaces the generated one.
    /// A type declares at most one, since overloading is deferred.
    constructor: ?Constructor = null,
    /// Section 10's instance methods. Each sees the instance as `self`.
    methods: []const FunctionDeclaration = &.{},
    /// Section 10.3's computed properties.
    properties: []const Property = &.{},
    /// Section 10.4's `func Vector2.origin()`, which belongs to the type
    /// rather than to each value, and so has no `self`.
    type_functions: []const TypeFunction = &.{},
    /// Section 10.4's `var Player.count = 0`.
    type_fields: []const TypeField = &.{},

    /// The keyword it was declared with, for diagnostics.
    pub fn keyword(self: StructDeclaration) []const u8 {
        return if (self.trait) "trait" else if (self.class) "class" else "struct";
    }

    /// The declaration's own `name` is the whole `Vector2.origin` as written,
    /// which is how a stack trace or a diagnostic about the function reads;
    /// `member` is the part after the dot, which shares the type's member
    /// name space.
    pub const TypeFunction = struct {
        member: []const u8,
        member_span: Source.Span,
        declaration: FunctionDeclaration,
    };

    pub const TypeField = struct {
        mutable: bool,
        name: []const u8,
        name_span: Source.Span,
        /// Optional, as for a module-level binding: the type can come from
        /// the value.
        annotation: ?TypeExpression,
        /// Required: section 10.4's type-level fields "require initial
        /// values", since nothing else runs to assign one.
        initializer: *const Expression,
    };

    pub const Field = struct {
        mutable: bool,
        name: []const u8,
        name_span: Source.Span,
        annotation: TypeExpression,
        /// Section 10.2's default, which runs when construction leaves the
        /// field to it.
        default: ?*const Expression = null,
    };

    /// `const area: Float { ... }`, or `var diameter: Float { get { ... } set
    /// { ... } }`. The parser builds each accessor as an ordinary method
    /// declaration — a getter with no parameters returning the property's
    /// type, a setter taking `value` — so every later pass calls them the way
    /// it calls any method.
    pub const Property = struct {
        mutable: bool,
        name: []const u8,
        name_span: Source.Span,
        annotation: TypeExpression,
        getter: FunctionDeclaration,
        setter: ?FunctionDeclaration,
        /// Section 10.7's `@override`, which replaces a base class's property.
        override_span: ?Source.Span = null,
    };

    /// `constructor(x: Float) { self.x = x }`. It has no name and no return
    /// type: calling the type runs it, and what it produces is always `self`.
    pub const Constructor = struct {
        keyword_span: Source.Span,
        parameters: []const Parameter,
        body: Block,
    };
};

/// Section 8.2's `(name, age)`: the names a tuple is unpacked into. `_`
/// discards its position, exactly as it does elsewhere. A position may itself
/// be a pattern, as in `(id, (x, y))` (7.4).
pub const Pattern = struct {
    span: Source.Span,
    /// One per position of the tuple, in order.
    positions: []const Position,
    /// Every name the pattern binds, nested ones included, in the order
    /// written. What only needs the names, such as declaring them, reads this.
    names: []const Name,

    pub const Name = struct {
        text: []const u8,
        span: Source.Span,
    };

    pub const Position = union(enum) {
        name: Name,
        nested: *const Pattern,
    };
};

/// `var (name, age) = entry`, or `const` (4.3). An annotation applies to the
/// whole tuple, not to one position.
pub const Destructuring = struct {
    mutable: bool,
    pattern: Pattern,
    annotation: ?TypeExpression,
    initializer: *const Expression,
};

/// `(left, right) = (right, left)`. Section 8.2 evaluates the complete right
/// side before any destination changes, which is what makes a swap work.
pub const DestructuringAssignment = struct {
    pattern: Pattern,
    value: *const Expression,
};

/// Section 6.4: `while condition { body }`.
pub const While = struct {
    condition: *const Expression,
    body: Block,
};

/// Section 6.4: `for name in iterable { body }`. The binding is read-only and
/// fresh for every iteration. Only a range can be looped over so far;
/// collections arrive with the collection slice.
pub const For = struct {
    /// `_` discards each value without introducing a binding. Empty when the
    /// loop destructures instead, which section 8.2 allows wherever a binding
    /// is introduced.
    name: []const u8,
    name_span: Source.Span,
    /// Section 8.2's `for (name, age) in entries`; null for a plain binding.
    pattern: ?Pattern = null,
    iterable: *const Expression,
    body: Block,
};

/// Section 7.1. Parameters are read-only, and require an explicit type this
/// slice rather than the defaults section 7.2 allows for public API guidance.
/// Nested function declarations, defaults, and named arguments are deferred; a
/// name declares at most one function, per section 7.3. Anonymous functions are
/// `Expression.Lambda`.
pub const FunctionDeclaration = struct {
    name: []const u8,
    name_span: Source.Span,
    parameters: []const Parameter,
    /// Omitted for a function with no result, whose return type is then
    /// `Nothing`, exactly as if `: Nothing` were written (section 7.2).
    return_annotation: ?TypeExpression,
    body: Block,
    /// Section 10.7's `@override`, which replaces a base class's method.
    override_span: ?Source.Span = null,
    /// Section 10.7's `@abstract`, on a method with no body for a subclass to
    /// supply, or for a trait's method written without a body, which is a
    /// requirement (11.1), its name. Its `body` is empty.
    abstract_span: ?Source.Span = null,
};

pub const Parameter = struct {
    name: []const u8,
    name_span: Source.Span,
    annotation: TypeExpression,
    /// Section 7.3's default, evaluated when a call omits this parameter.
    default: ?*const Expression = null,
};

pub const Return = struct {
    keyword_span: Source.Span,
    /// Null for a bare `return`, which section 7.1 allows for a function with
    /// no result.
    value: ?*const Expression,
};

pub const Declaration = struct {
    /// Section 4.3: `var` permits rebinding, `const` does not.
    mutable: bool,
    name: []const u8,
    name_span: Source.Span,
    /// Section 4.1 infers the type from the initializer when there is no
    /// annotation, and requires an annotation when there is no initializer.
    annotation: ?TypeExpression,
    initializer: ?*const Expression,
};

/// A type as written in the source: a name, section 8.2's `[T]`, or section
/// 7.1's `func(Int): String`. The dictionary and set spellings arrive with
/// those collections.
pub const TypeExpression = struct {
    span: Source.Span,
    /// The name, or empty for a list or function type.
    name: []const u8,
    /// The element type of a list type, `T` in `[T]`, the value type of a
    /// dictionary, or the member type of a set; null otherwise.
    element: ?*const TypeExpression = null,
    /// The key type of a dictionary type, `K` in `[K: V]`; null otherwise.
    key: ?*const TypeExpression = null,
    /// Whether `element` is section 8.2's `{T}` rather than `[T]`.
    set: bool = false,
    /// The shape of a function type; null otherwise.
    signature: ?*const SignatureExpression = null,
    /// The position types of a tuple type, `(A, B)`; null otherwise.
    positions: ?[]const TypeExpression = null,
    /// The `?` that marks an optional, split from the name by the parser as
    /// section 4.2 describes. Null when the type is not optional.
    question_span: ?Source.Span,
};

/// `name = value`, or an assignment reached through a path of indices and
/// fields, `name[i].field[j] = value`.
pub const Assignment = struct {
    /// The binding assigned, or the one whose place is reached through
    /// `steps`.
    name: []const u8,
    name_span: Source.Span,
    /// The path from outermost to innermost, empty for a plain assignment.
    /// `grid[0][1] = 5` has two index steps; `point.x = 1` has one field step.
    steps: []const Step = &.{},
    /// The whole destination as written, for diagnostics.
    target_span: Source.Span,
    /// The operation a compound assignment applies, or null for a plain `=`.
    /// Section 5.3 lowers `a += b` through the same operation as `a + b`.
    operation: ?BinaryOperator,
    value: *const Expression,
};

/// One step of an assignment path: an index into a list or dictionary, or a
/// named struct field. `entry.0` never appears here — a tuple position can
/// never be assigned to, which the parser rejects before building one.
pub const Step = union(enum) {
    index: *const Expression,
    field: struct { name: []const u8, span: Source.Span },
};

/// `func(Int, String): Bool` as written. The result is null when the type
/// omits it, which section 7.1 makes the same as writing `Nothing`.
pub const SignatureExpression = struct {
    parameters: []const TypeExpression,
    result: ?*const TypeExpression,
};

pub const If = struct {
    condition: *const Expression,
    then_block: Block,
    otherwise: ?Else,
    /// Section 6.2's trailing form, `statement if condition`, which guards one
    /// statement and has no `else`. Its `then_block` holds that one statement.
    /// Kept distinct so the source shape survives for the formatter; nothing
    /// else treats it differently from a block `if`.
    trailing: bool = false,
};

pub const Else = union(enum) {
    block: Block,
    /// An `else if`, kept distinct from a block holding one `if` so the source
    /// shape survives for the formatter.
    chained: *const Statement,
};

pub const Expression = struct {
    span: Source.Span,
    data: Data,
    /// The height of this expression's tree. Every pass walks expressions
    /// recursively, so the parser bounds this to keep them all within the host
    /// stack; see `Parser.max_expression_depth`.
    depth: u32 = 1,

    pub const Data = union(enum) {
        int_literal: i64,
        float_literal: f64,
        bool_literal: bool,
        /// Section 4.2's `nothing`, the single value of the absence-only type.
        nothing_literal: void,
        name: []const u8,
        unary: Unary,
        binary: Binary,
        logical: Logical,
        comparison: Comparison,
        call: Call,
        range: Range,
        /// A string whose text is fully known, with every escape and, for a
        /// triple-quoted string, its indentation already applied (5.1).
        string_literal: []const u8,
        /// Section 5.1's `"text #{expression} text"`, in order.
        interpolation: []const Part,
        /// Section 8.2's `[a, b, c]`. A set literal shares this spelling, and
        /// is told apart by the type expected where it is written.
        list_literal: []const *const Expression,
        /// Section 8.2's `["Ava": 12]`, recognized by its `key: value` entries.
        dictionary_literal: []const Entry,
        /// Section 5.4's zero-based `base[index]`.
        index: Index,
        /// `base.name`: a property, or a method when it is the callee of a call.
        member: Member,
        /// Section 7.4's `{ value => value * 2 }`.
        lambda: Lambda,
        /// Section 8.2's `("score", 10)`, which always has at least two
        /// positions; one parenthesized expression is a group.
        tuple_literal: []const *const Expression,
        /// Section 4.4's `animal is Dog`.
        type_test: TypeTest,
    };

    /// `value is Type`, which asks what the value is at runtime.
    pub const TypeTest = struct {
        value: *const Expression,
        target: TypeExpression,
    };

    /// Section 7.4. A lambda has no return annotation: its result type comes
    /// from its body, and its parameter types from their annotations or from
    /// the callable type expected where it is written.
    pub const Lambda = struct {
        parameters: []const LambdaParameter,
        body: Body,

        /// A single-expression lambda returns its expression; a block-bodied one
        /// uses `return`. The parser decides by what follows `=>`: a newline
        /// begins a block, and anything else is the one expression.
        pub const Body = union(enum) {
            expression: *const Expression,
            block: Block,
        };
    };

    /// Unlike a named function's parameter, a lambda's annotation is optional
    /// (7.2). `_` discards the argument and binds nothing.
    pub const LambdaParameter = struct {
        name: []const u8,
        name_span: Source.Span,
        annotation: ?TypeExpression,
        /// Section 8.6's `{ (name, age) => ... }`, where the one item a block
        /// receives is a tuple unpacked in the header; null for a plain
        /// parameter.
        pattern: ?Pattern = null,
    };

    /// One `key: value` of a dictionary literal.
    pub const Entry = struct {
        key: *const Expression,
        value: *const Expression,
    };

    /// One piece of an interpolated string: finished text, or an expression
    /// whose displayed value goes there.
    pub const Part = union(enum) {
        text: []const u8,
        expression: *const Expression,
    };

    pub const Index = struct {
        base: *const Expression,
        index: *const Expression,
    };

    pub const Member = struct {
        base: *const Expression,
        name: []const u8,
        name_span: Source.Span,
        /// Section 8.2's `entry.0`, the zero-based position of a tuple member.
        /// Null when the member was written as a name.
        position: ?u32 = null,
    };

    /// Section 6.4's `start..end`, which includes both bounds, or
    /// `start..<end`, which excludes the end. Ranges count upward only.
    pub const Range = struct {
        start: *const Expression,
        end: *const Expression,
        inclusive: bool,
    };

    pub const Unary = struct {
        operator: UnaryOperator,
        operand: *const Expression,
    };

    /// `and` and `or`, which short-circuit and so cannot be ordinary binaries.
    pub const Logical = struct {
        operator: LogicalOperator,
        left: *const Expression,
        right: *const Expression,
    };

    /// A comparison chain such as `0 <= score <= 100`.
    ///
    /// Section 5.2 requires the middle expression to be evaluated once and the
    /// chain to short-circuit as if joined by `and`. Holding the whole chain in
    /// one node is what makes both properties natural rather than something the
    /// evaluator has to reconstruct. `operands.len` is always
    /// `operators.len + 1`.
    pub const Comparison = struct {
        operands: []const *const Expression,
        operators: []const ComparisonOperator,
    };

    pub const Binary = struct {
        operator: BinaryOperator,
        left: *const Expression,
        right: *const Expression,
    };

    pub const Call = struct {
        callee: *const Expression,
        arguments: []const *const Expression,
        /// Section 7.3's named arguments, one per argument and null for a
        /// positional one. Empty when no argument is named.
        names: []const ?ArgumentName = &.{},
        /// Whether the last argument is section 7.4's trailing block, written
        /// after the parentheses. It always fills the final parameter.
        trailing: bool = false,

        pub const ArgumentName = struct {
            text: []const u8,
            span: Source.Span,
        };
    };
};

pub const UnaryOperator = enum {
    negate,
    /// Section 5.2 spells negation `not`. There is no `!` alternative.
    not,

    pub fn lexeme(self: UnaryOperator) []const u8 {
        return switch (self) {
            .negate => "-",
            .not => "not",
        };
    }
};

pub const LogicalOperator = enum {
    conjunction,
    disjunction,

    pub fn lexeme(self: LogicalOperator) []const u8 {
        return switch (self) {
            .conjunction => "and",
            .disjunction => "or",
        };
    }
};

pub const ComparisonOperator = enum {
    equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,

    pub fn lexeme(self: ComparisonOperator) []const u8 {
        return switch (self) {
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
        };
    }

    /// `==` and `!=` work on any two values of the same type; the rest need
    /// an order, which only numbers have.
    pub fn isEquality(self: ComparisonOperator) bool {
        return self == .equal or self == .not_equal;
    }

    /// Whether the operator holds for a given ordering. Operands that are not
    /// ordered at all, meaning a NaN is involved, never reach here: section 5.3
    /// gives them IEEE behavior, which the interpreter applies first.
    pub fn holds(self: ComparisonOperator, order: std.math.Order) bool {
        return switch (self) {
            .equal => order == .eq,
            .not_equal => order != .eq,
            .less => order == .lt,
            .less_equal => order != .gt,
            .greater => order == .gt,
            .greater_equal => order != .lt,
        };
    }
};

/// The arithmetic set from section 5.3. Comparison and the word operators arrive
/// with the statement slice, which is the first place a `Bool` is useful.
pub const BinaryOperator = enum {
    add,
    subtract,
    multiply,
    /// `/`, which always produces a `Float`.
    divide,
    /// `//`, which rounds toward negative infinity.
    floor_divide,
    /// `%`, paired with floor division by the law `a == (a // b) * b + (a % b)`.
    remainder,
    /// `**`, which gives an `Int` for two `Int`s and associates right to left.
    power,

    pub fn lexeme(self: BinaryOperator) []const u8 {
        return switch (self) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .floor_divide => "//",
            .remainder => "%",
            .power => "**",
        };
    }

    /// How the operator reads in a diagnostic, in the user's vocabulary.
    pub fn describe(self: BinaryOperator) []const u8 {
        return switch (self) {
            .add => "addition",
            .subtract => "subtraction",
            .multiply => "multiplication",
            .divide => "division",
            .floor_divide => "floor division",
            .remainder => "remainder",
            .power => "exponentiation",
        };
    }
};
