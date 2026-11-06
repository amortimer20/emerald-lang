//! Every vendor library, in one list. Adding a library is copying
//! `vendor/_template`, filling it in, and adding one line here
//! (`docs/vendor-libraries.md`); `tools/check-vendor.sh` fails when a folder is
//! missing from the list or an item of the recipe is missing from a folder.
const std = @import("std");

pub const Library = struct {
    /// The folder name under `vendor/`, and the library's name in its module.
    name: []const u8,
    /// The names that load the library: its types and namespaces. A program
    /// that writes none of them never loads it.
    names: []const []const u8,
    /// The shared library's name, without `lib` or an extension.
    module: []const u8,
    /// The error type a native's failure raises, declared in the library's `.em`.
    error_type: []const u8,
    /// False for a library that exists to test the mechanism: it is never
    /// installed, and only the test suite can name it.
    ships: bool,
    /// Adds the module (a shared library) to the build.
    add: *const fn (b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile,
};

pub const all = [_]Library{
    @import("selftest/build.zig").library,
};
