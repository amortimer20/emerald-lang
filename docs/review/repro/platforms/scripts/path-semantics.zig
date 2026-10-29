//! Prints what the std.fs.path functions behind Emerald's Path.name, stem,
//! extension, parent and absolute? return under POSIX and Windows rules, so
//! the Windows result can be predicted from any host. Run with
//! `mise exec -- zig run docs/review/repro/platforms/scripts/path-semantics.zig`.
const std = @import("std");
const p = std.fs.path;

pub fn main() !void {
    const inputs = [_][]const u8{ "a/b/c.txt", "a\\b\\c.txt", "C:\\x\\y.txt", "C:/x/y.txt", "/abs/p", "\\\\server\\share\\f.txt", "rel", "", "/", "a/b/", "a//b", ".hidden", "a.tar.gz", "dir.d/file", "c:", "a\\b/c.d\\e" };
    for (inputs) |in| {
        std.debug.print("[{s}]\n  posix:   name={s} stem={s} ext={s} parent={s} abs?={}\n  windows: name={s} stem={s} ext={s} parent={s} abs?={}\n", .{
            in,
            p.basenamePosix(in),
            stemOf(p.basenamePosix(in)),
            extOf(p.basenamePosix(in)),
            p.dirnamePosix(in) orelse "",
            p.isAbsolutePosix(in),
            p.basenameWindows(in),
            stemOf(p.basenameWindows(in)),
            extOf(p.basenameWindows(in)),
            p.dirnameWindows(in) orelse "",
            p.isAbsoluteWindows(in),
        });
    }
}

fn extOf(base: []const u8) []const u8 {
    const e = p.extension(base);
    return if (e.len == 0) e else e[1..];
}
fn stemOf(base: []const u8) []const u8 {
    return p.stem(base);
}
