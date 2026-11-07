//! The runtime: what a running Emerald program needs, whichever engine runs it
//! (docs/compiler-design-plan.md, decision 4). The interpreter calls it today; a
//! compiled program will link it alone. So nothing here imports the front end
//! (lexer, parser, resolver, checker) or the interpreter, and the build makes it
//! its own module to keep it that way.

pub const Heap = @import("Heap.zig");
pub const Value = @import("Value.zig");
pub const Range = @import("Range.zig");
pub const strings = @import("strings.zig");
pub const unicode = @import("unicode.zig");
pub const FloatMath = @import("FloatMath.zig");
pub const Json = @import("Json.zig");
pub const Csv = @import("Csv.zig");
pub const Regex = @import("Regex.zig");
pub const Http = @import("Http.zig");
pub const TimeZone = @import("TimeZone.zig");
pub const Scheduler = @import("Scheduler.zig");
pub const Module = @import("Module.zig");
pub const Native = @import("Native.zig");
pub const MapMethods = @import("MapMethods.zig");
pub const ListMethods = @import("ListMethods.zig");
pub const RangeMethods = @import("RangeMethods.zig");
pub const NumberMethods = @import("NumberMethods.zig");
pub const BytesMethods = @import("BytesMethods.zig");
pub const StringMethods = @import("StringMethods.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
