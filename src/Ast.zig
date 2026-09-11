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
    };
};

pub const Declaration = struct {
    /// Section 4.3: `var` permits rebinding, `const` does not.
    mutable: bool,
    name: []const u8,
    name_span: Source.Span,
    initializer: *const Expression,
};

pub const Assignment = struct {
    name: []const u8,
    name_span: Source.Span,
    /// The operation a compound assignment applies, or null for a plain `=`.
    /// Section 5.3 lowers `a += b` through the same operation as `a + b`.
    operation: ?BinaryOperator,
    value: *const Expression,
};

pub const If = struct {
    condition: *const Expression,
    then_block: Block,
    otherwise: ?Else,
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
    /// `**`, which always produces a `Float` and associates right to left.
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
