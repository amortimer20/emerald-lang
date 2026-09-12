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
        return_statement: Return,
    };
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
    /// `_` discards each value without introducing a binding.
    name: []const u8,
    name_span: Source.Span,
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
};

pub const Parameter = struct {
    name: []const u8,
    name_span: Source.Span,
    annotation: TypeExpression,
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
    /// The element type of a list type, `T` in `[T]`; null otherwise.
    element: ?*const TypeExpression = null,
    /// The shape of a function type; null otherwise.
    signature: ?*const SignatureExpression = null,
    /// The `?` that marks an optional, split from the name by the parser as
    /// section 4.2 describes. Null when the type is not optional.
    question_span: ?Source.Span,
};

/// `name = value`, or an assignment into a list, `name[i][j] = value`.
pub const Assignment = struct {
    /// The binding assigned, or the one whose list is changed through
    /// `indices`.
    name: []const u8,
    name_span: Source.Span,
    /// The index expressions from outermost to innermost, empty for a plain
    /// assignment. `grid[0][1] = 5` has `[0, 1]`.
    indices: []const *const Expression = &.{},
    /// The whole destination as written, for diagnostics.
    target_span: Source.Span,
    /// The operation a compound assignment applies, or null for a plain `=`.
    /// Section 5.3 lowers `a += b` through the same operation as `a + b`.
    operation: ?BinaryOperator,
    value: *const Expression,
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
        /// Section 8.2's `[a, b, c]`. Dictionary and set literals share the
        /// bracket spelling and arrive with those collections.
        list_literal: []const *const Expression,
        /// Section 5.4's zero-based `base[index]`.
        index: Index,
        /// `base.name`: a property, or a method when it is the callee of a call.
        member: Member,
        /// Section 7.4's `{ value => value * 2 }`.
        lambda: Lambda,
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
