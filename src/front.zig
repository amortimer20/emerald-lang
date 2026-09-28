//! The front end on its own (lexing and parsing), without the rest of Emerald,
//! for `tools/prelude_ast.zig`, which parses the prelude when Emerald is
//! built. It cannot import `emerald.zig`, which imports what it generates.

pub const Ast = @import("Ast.zig");
pub const Lexer = @import("Lexer.zig");
pub const Parser = @import("Parser.zig");
pub const Source = @import("Source.zig");
