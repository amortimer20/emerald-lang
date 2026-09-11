//! The syntax tree.
//!
//! Section 19.2 keeps this free of runtime values, so the tree a future backend
//! consumes is the same tree the interpreter consumes. Every node carries the
//! span it came from, which diagnostics, stack traces, and later the formatter
//! and language server all read.

const std = @import("std");
const Source = @import("Source.zig");

/// A whole source file. Only expression statements exist so far; `var`, `const`,
/// assignment, blocks, and `if` arrive with the statement slice.
pub const Program = struct {
    statements: []const Statement,
};

pub const Statement = struct {
    span: Source.Span,
    data: Data,

    pub const Data = union(enum) {
        /// An expression evaluated for its effect. Section 5.2 allows this only
        /// for calls; a pure expression whose result is unused is an error.
        expression: *const Expression,
    };
};

pub const Expression = struct {
    span: Source.Span,
    data: Data,

    pub const Data = union(enum) {
        int_literal: i64,
        float_literal: f64,
        name: []const u8,
        unary: Unary,
        binary: Binary,
        call: Call,
    };

    pub const Unary = struct {
        operator: UnaryOperator,
        operand: *const Expression,
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

    pub fn lexeme(self: UnaryOperator) []const u8 {
        return switch (self) {
            .negate => "-",
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
