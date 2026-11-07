//! The compiler's intermediate form (docs/compiler-design-plan.md, decision 3).
//!
//! Lowering (`Lower.zig`) turns the checked syntax tree into this, and an
//! emitter (`EmitC.zig`) turns this into another language. It is small on
//! purpose: control flow is explicit, as basic blocks ending in a jump, a
//! branch or a return, and every runtime check the language requires is an
//! instruction of its own, carrying the source location its failure reports.
//! An emitter only translates; it decides nothing about the language.
//!
//! Slice 2 has the scalars (`Int`, `Float`, `Bool`), functions, control flow
//! and `print`. Values on the heap, with explicit reference-count operations,
//! join in slice 3.

const std = @import("std");
const Source = @import("../Source.zig");
const Arithmetic = @import("runtime").Operations.Arithmetic;
const ComparisonOperator = @import("../Ast.zig").ComparisonOperator;

/// A whole program: its functions, the first of which runs the entry file's
/// top-level statements, and the module-level variables they share.
pub const Program = struct {
    functions: []const Function,
    globals: []const Global,
    /// The places a failure or a call can be reported at, by `Site`.
    sites: []const Source.Span,
};

pub const Type = enum {
    nothing,
    int,
    float,
    bool,
};

pub const Global = struct {
    name: []const u8,
    type: Type,
};

pub const Function = struct {
    /// The name a trace prints for a call to it. The entry is never called.
    name: []const u8,
    /// The function's own locals; the first `parameter_count` are its
    /// parameters, in order.
    locals: []const LocalInfo,
    parameter_count: u32,
    result: Type,
    /// The first block is where the function starts.
    blocks: []const Block,
};

pub const LocalInfo = struct {
    /// The name as written, or empty for a temporary.
    name: []const u8,
    type: Type,
};

/// An index into `Function.locals`.
pub const Local = u32;
/// An index into `Program.globals`.
pub const GlobalIndex = u32;
/// An index into `Function.blocks`.
pub const BlockIndex = u32;
/// An index into `Program.functions`.
pub const FunctionIndex = u32;
/// An index into `Program.sites`.
pub const Site = u32;

/// Where a value is stored.
pub const Place = union(enum) {
    local: Local,
    global: GlobalIndex,
};

/// A value an instruction reads.
pub const Operand = union(enum) {
    local: Local,
    global: GlobalIndex,
    int: i64,
    float: f64,
    bool: bool,
};

pub const Block = struct {
    instructions: []const Instruction,
    terminator: Terminator,
};

pub const Instruction = struct {
    /// The source line, for the emitter's line mapping.
    line: u32,
    data: Data,

    pub const Data = union(enum) {
        move: struct { destination: Place, source: Operand },
        /// `Int` arithmetic, raising on overflow or a zero divisor; never
        /// `divide`, which gives a `Float`.
        int_arithmetic: struct { operator: Arithmetic, destination: Place, left: Operand, right: Operand, site: Site },
        /// `Float` arithmetic, raising on a zero divisor.
        float_arithmetic: struct { operator: Arithmetic, destination: Place, left: Operand, right: Operand, site: Site },
        /// `-operand` for an `Int`, which overflows for the minimum.
        negate_int: struct { destination: Place, operand: Operand, site: Site },
        negate_float: struct { destination: Place, operand: Operand },
        not: struct { destination: Place, operand: Operand },
        /// Section 4.4's widening: an `Int` where a `Float` is expected.
        widen: struct { destination: Place, operand: Operand },
        /// One link of a comparison; the operands' types are `kind`'s.
        compare: struct { operator: ComparisonOperator, kind: Comparison, destination: Place, left: Operand, right: Operand },
        /// A call that can fail, reported in a trace at `site`.
        call: struct { function: FunctionIndex, arguments: []const Operand, destination: ?Place, site: Site },
        /// Part of a line of output.
        write: Write,
    };

    pub const Comparison = enum {
        int,
        float,
        bool,
        /// An `Int` on the left and a `Float` on the right, compared exactly.
        int_float,
        float_int,
    };

    pub const Write = union(enum) {
        text: []const u8,
        int: Operand,
        float: Operand,
        bool: Operand,
    };
};

pub const Terminator = union(enum) {
    jump: BlockIndex,
    branch: struct { condition: Operand, then: BlockIndex, otherwise: BlockIndex },
    /// Returns, with the function's result when it has one.
    @"return": ?Operand,
};
