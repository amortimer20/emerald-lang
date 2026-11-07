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
//! and `print`; slice 3a adds `String`, the first value on the heap, 3b
//! lists, and 3c optionals and tuples.
//!
//! A heap value is owned by the slot that holds it. Every local and global of
//! a heap type owns one reference, or holds nothing yet; storing into one
//! retains the new value and releases the old, and a function releases all of
//! its own when it returns. An operation's result is a new reference its
//! destination takes over. An emitter applies those rules from the slots'
//! types, so the IR spells out where values go rather than each count.

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
    /// The text of each string literal, by `Operand.literal`.
    literals: []const []const u8,
};

pub const Type = enum {
    nothing,
    int,
    float,
    bool,
    string,
    /// A list of any element these types can hold; the instructions that
    /// read or build one carry the element's type.
    list,
    /// Section 4.2's `T?`: a value of the runtime's tagged kind, absent
    /// when its kind is `nothing`. Reading one the checker has narrowed
    /// unwraps it, with the payload's type.
    optional,
    /// Section 8.2's `(String, Int)`, which never changes once built.
    tuple,

    /// Whether a slot of this type owns a reference on the heap.
    pub fn counted(self: Type) bool {
        return switch (self) {
            .string, .list, .optional, .tuple => true,
            .nothing, .int, .float, .bool => false,
        };
    }
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
    /// A string literal, by its index in `Program.literals`.
    literal: u32,
    /// `nothing`, as an optional.
    nothing,
};

/// An operand with its type, where an instruction takes values of several.
pub const Typed = struct {
    operand: Operand,
    type: Type,
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
        /// Section 9's `+` on two strings.
        concat: struct { destination: Place, left: Operand, right: Operand },
        /// A string built from parts: an interpolation, or a `to_string`.
        format: struct { destination: Place, parts: []const Write },
        /// A method of the runtime's `Natives.zig`, by family and method
        /// index, giving `result`, or nothing to keep when `destination` is
        /// null.
        native: struct { family: u32, method: u32, receiver: Typed, arguments: []const Typed, destination: ?Place, result: Type, site: Site },
        /// Section 9.2's `count` of a string's characters.
        string_count: struct { destination: Place, operand: Operand },
        /// Section 9.1's `text[position]`.
        string_index: struct { destination: Place, operand: Operand, position: Operand, site: Site },
        /// Section 5.4's `text[start..end]`, with either bound left out.
        string_slice: struct { destination: Place, operand: Operand, start: ?Operand, end: ?Operand, inclusive: bool, site: Site },
        /// Section 8.2's `[a, b, c]`, each item widened to `element`.
        list_new: struct { destination: Place, element: Type, items: []const Typed },
        list_count: struct { destination: Place, list: Operand },
        /// Section 5.4's `list[position]`, an `element`.
        list_get: struct { destination: Place, list: Operand, position: Operand, element: Type, site: Site },
        /// `list[position] = value`, changing the list `target` holds, which
        /// is copied first if anything else shares it.
        list_set: struct { target: Place, position: Operand, value: Typed, site: Site },
        /// One of `ListMethods.Mutation`'s methods on the list `target`
        /// holds, copied first as `list_set`'s is.
        list_mutate: struct { target: Place, method: u32, arguments: []const Typed, destination: ?Place, result: Type, site: Site },
        /// A value as an optional that holds it.
        wrap: struct { destination: Place, value: Typed },
        /// The value an optional holds, which the checker has proved is
        /// there, as `payload`.
        unwrap: struct { destination: Place, operand: Operand, payload: Type },
        /// Whether an optional holds a value.
        present: struct { destination: Place, operand: Operand },
        /// Section 8.2's `(a, b)`.
        tuple_new: struct { destination: Place, items: []const Typed },
        /// Section 8.2's `entry.0`, a `type`.
        tuple_get: struct { destination: Place, tuple: Operand, position: u32, type: Type },
    };

    pub const Comparison = enum {
        int,
        float,
        bool,
        /// Two strings, by their normalized forms.
        string,
        /// Two optionals, which every other value compared by `==` and
        /// `!=` alone (lists, tuples) is wrapped as, compared as the
        /// interpreter compares values.
        value,
        /// An `Int` on the left and a `Float` on the right, compared exactly.
        int_float,
        float_int,
    };

    pub const Write = union(enum) {
        text: []const u8,
        int: Operand,
        float: Operand,
        bool: Operand,
        string: Operand,
        /// Any other value, as `print` shows it.
        value: Typed,
    };
};

pub const Terminator = union(enum) {
    jump: BlockIndex,
    branch: struct { condition: Operand, then: BlockIndex, otherwise: BlockIndex },
    /// Returns, with the function's result when it has one.
    @"return": ?Operand,
};
