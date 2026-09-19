//! Finding and loading the files a program is made of.
//!
//! Section 14.1: a single file is a complete program, and a directory becomes a
//! project only when it contains `main.em`. Running a file outside a project
//! runs that file alone, so a folder of independent exercises works the way a
//! beginner expects — `emerald run ex1.em` never sees `ex2.em`, and two
//! exercises that each declare `func helper` do not collide.
//!
//! Inside a project every `.em` file under the root is included; no import is
//! needed merely to make a project file exist. Directories form the namespaces
//! of section 14.2: `shapes/circle.em` contributes its declarations to `Shapes`.
//! The file itself names nothing. It is the unit of initialization and of
//! privacy, not a unit of naming, which is what settles the question section 24
//! left open — see the decision table in section 22.

const std = @import("std");
const Source = @import("Source.zig");

const Project = @This();

/// The file every project is found by, and the entry point when one is not
/// named explicitly.
pub const entry_file_name = "main.em";

pub const extension = ".em";

/// How deep a project's directories may nest. A namespace no one can read is
/// not worth walking, and a bound keeps a symlink loop from running forever.
pub const max_depth = 16;

/// How many files one project may hold. Far past anything the interpreter is
/// meant for, and it keeps a mistaken root — a home directory, say — from
/// reading the whole disk.
pub const max_files = 4096;

pub const File = struct {
    source: Source,
    /// The namespace the file's directory puts its declarations in, empty at
    /// the project root. `Shapes`, or `Graphics.Ui` for a nested directory.
    namespace: []const u8,
    /// The file `emerald run` was pointed at, the only one whose top level may
    /// hold statements that run (14.1).
    entry: bool,
};

/// A directory name that cannot become a namespace, kept until there is a
/// `Source` to attach the report to.
pub const BadDirectory = struct {
    /// The path below the project root, which is what the reader has to rename.
    path: []const u8,
    /// A file inside it, since a diagnostic always names a file. Filled in once
    /// the files are in their final order.
    file: u32 = 0,
};

files: []File,
/// Index into `files` of the entry.
entry: u32,
/// When the entry runs alone but a directory above it holds `main.em`: that
/// directory. Section 24 asks what happens to a file run on its own inside a
/// project, and this is the answer — it runs alone, and a diagnostic can say
/// so rather than leaving the reader to wonder where the rest of it went.
enclosing_project: ?[]const u8 = null,
bad_directories: []const BadDirectory,

pub const LoadError = std.Io.Dir.ReadFileAllocError || std.mem.Allocator.Error ||
    std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error ||
    error{ TooManyFiles, ProjectTooDeep };

/// Loads `path`, and every other `.em` file under the project root when `path`
/// sits in a project.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Project {
    return loadIn(gpa, io, std.Io.Dir.cwd(), path);
}

/// The same, with `path` relative to `base` rather than to the working
/// directory. `path` is still what the reader sees, so the conformance suite
/// can run cases from its own directory without machine-specific paths
/// appearing in a golden file.
pub fn loadIn(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    path: []const u8,
) LoadError!Project {
    const directory = std.fs.path.dirname(path) orelse "";

    if (!holdsEntryFile(io, base, directory)) {
        var project = try single(gpa, io, base, path);
        project.enclosing_project = try enclosingProject(gpa, io, base, directory);
        return project;
    }

    var root = try base.openDir(io, if (directory.len == 0) "." else directory, .{ .iterate = true });
    defer root.close(io);

    var loader: Loader = .{ .gpa = gpa, .io = io, .prefix = directory };
    errdefer loader.deinit();

    try loader.walk(root, "", "");

    // Walk order is undefined and every later stage reports in file order, so
    // the order a reader sees is fixed here rather than left to the host.
    std.mem.sort(File, loader.files.items, {}, byPath);

    var entry_index: u32 = 0;
    for (loader.files.items, 0..) |file, index| {
        if (std.mem.eql(u8, file.source.path, path)) entry_index = @intCast(index);
    }
    loader.files.items[entry_index].entry = true;

    // Sorting moved the files, so each unusable directory finds its file again
    // by path rather than by the index it had while walking.
    for (loader.bad_directories.items) |*bad| {
        for (loader.files.items, 0..) |file, index| {
            const under = file.source.path[@min(directory.len + @intFromBool(directory.len != 0), file.source.path.len)..];
            if (std.mem.startsWith(u8, under, bad.path)) {
                bad.file = @intCast(index);
                break;
            }
        }
    }

    var project: Project = .{
        .files = try loader.files.toOwnedSlice(gpa),
        .entry = entry_index,
        .bad_directories = &.{},
    };
    errdefer project.deinit(gpa);
    project.bad_directories = try loader.bad_directories.toOwnedSlice(gpa);
    return project;
}

fn byPath(_: void, a: File, b: File) bool {
    return std.mem.order(u8, a.source.path, b.source.path) == .lt;
}

/// A file that is not in a project is the whole program, exactly as it was
/// before projects existed.
fn single(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir, path: []const u8) LoadError!Project {
    const bytes = try base.readFileAlloc(io, path, gpa, .limited(Source.max_bytes));
    defer gpa.free(bytes);

    var source = try Source.init(gpa, path, bytes);
    errdefer source.deinit(gpa);

    const files = try gpa.alloc(File, 1);
    files[0] = .{ .source = source, .namespace = "", .entry = true };
    return .{ .files = files, .entry = 0, .bad_directories = &.{} };
}

/// Section 14.1's whole test for whether a file is part of a project: does the
/// directory it sits in contain `main.em`? Only that directory is consulted.
/// Searching upward as well would pull a folder of exercises into whatever
/// project happens to be above it, which is exactly the surprise 14.1 avoids.
/// The nearest directory above `directory` that holds `main.em`, or null. Only
/// asked once, and only for a file that is running alone.
fn enclosingProject(
    gpa: std.mem.Allocator,
    io: std.Io,
    base: std.Io.Dir,
    directory: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    var at = directory;
    var levels: u32 = 0;
    while (levels <= max_depth) : (levels += 1) {
        const parent = std.fs.path.dirname(at) orelse {
            if (at.len == 0) return null;
            break;
        };
        at = parent;
        if (holdsEntryFile(io, base, at)) {
            const owned: []const u8 = try gpa.dupe(u8, at);
            return owned;
        }
    }
    // The working directory itself, which has no name to take a `dirname` of.
    if (holdsEntryFile(io, base, "")) {
        const owned: []const u8 = try gpa.dupe(u8, ".");
        return owned;
    }
    return null;
}

fn holdsEntryFile(io: std.Io, base: std.Io.Dir, directory: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const candidate = std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{
        directory,
        if (directory.len == 0) "" else std.fs.path.sep_str,
        entry_file_name,
    }) catch return false;
    base.access(io, candidate, .{}) catch return false;
    return true;
}

/// Accumulates the walk, so `load` stays about the decision and this stays
/// about the recursion.
const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The directory the entry was named through, so every display path reads
    /// the way the reader typed it: `emerald run game/main.em` reports
    /// `game/shapes/circle.em`, not `shapes/circle.em`.
    prefix: []const u8,
    files: std.ArrayList(File) = .empty,
    bad_directories: std.ArrayList(BadDirectory) = .empty,
    depth: u32 = 0,

    fn deinit(self: *Loader) void {
        for (self.files.items) |*file| {
            file.source.deinit(self.gpa);
            self.gpa.free(file.namespace);
        }
        self.files.deinit(self.gpa);
        for (self.bad_directories.items) |bad| self.gpa.free(bad.path);
        self.bad_directories.deinit(self.gpa);
    }

    /// `relative` is the path below the project root, and `namespace` the name
    /// the directories walked so far have built.
    fn walk(self: *Loader, directory: std.Io.Dir, relative: []const u8, namespace: []const u8) LoadError!void {
        if (self.depth > max_depth) return error.ProjectTooDeep;

        // `Entry.name` is only valid until the iterator moves on, and both
        // branches below allocate and recurse, so each name is copied first.
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            const name = try self.gpa.dupe(u8, entry.name);
            defer self.gpa.free(name);

            switch (entry.kind) {
                .file => {
                    if (!std.mem.endsWith(u8, name, extension)) continue;
                    if (self.files.items.len >= max_files) return error.TooManyFiles;

                    const display = try self.join(self.prefix, relative, name);
                    defer self.gpa.free(display);

                    const bytes = try directory.readFileAlloc(self.io, name, self.gpa, .limited(Source.max_bytes));
                    defer self.gpa.free(bytes);

                    var source = try Source.init(self.gpa, display, bytes);
                    errdefer source.deinit(self.gpa);

                    const file_namespace = try self.gpa.dupe(u8, namespace);
                    errdefer self.gpa.free(file_namespace);

                    try self.files.append(self.gpa, .{
                        .source = source,
                        .namespace = file_namespace,
                        .entry = false,
                    });
                },
                .directory => {
                    // A dot directory is the host's, not the program's.
                    if (std.mem.startsWith(u8, name, ".")) continue;

                    const segment = try namespaceSegment(self.gpa, name);
                    defer if (segment) |written| self.gpa.free(written);

                    const nested_namespace = if (segment) |written|
                        try self.qualify(namespace, written)
                    else
                        try self.gpa.dupe(u8, namespace);
                    defer self.gpa.free(nested_namespace);

                    const nested_relative = try self.join("", relative, name);
                    defer self.gpa.free(nested_relative);

                    var nested = directory.openDir(self.io, name, .{ .iterate = true }) catch continue;
                    defer nested.close(self.io);

                    const before = self.files.items.len;
                    self.depth += 1;
                    try self.walk(nested, nested_relative, nested_namespace);
                    self.depth -= 1;

                    // Reported only when the directory actually holds source,
                    // and against the first file in it, so the report has
                    // something to point at.
                    if (segment == null and self.files.items.len > before) {
                        const bad_path = try self.gpa.dupe(u8, nested_relative);
                        errdefer self.gpa.free(bad_path);
                        try self.bad_directories.append(self.gpa, .{
                            .path = bad_path,
                        });
                    }
                },
                else => {},
            }
        }
    }

    fn join(self: *Loader, prefix: []const u8, relative: []const u8, name: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer out.deinit();
        for ([_][]const u8{ prefix, relative }) |part| {
            if (part.len == 0) continue;
            out.writer.writeAll(part) catch return error.OutOfMemory;
            out.writer.writeByte('/') catch return error.OutOfMemory;
        }
        out.writer.writeAll(name) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    fn qualify(self: *Loader, namespace: []const u8, segment: []const u8) ![]u8 {
        if (namespace.len == 0) return self.gpa.dupe(u8, segment);
        return std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ namespace, segment });
    }
};

/// The namespace one directory contributes, or null when its name cannot be
/// one. Section 14.2 derives the name from the path, and Emerald writes
/// directories in the `snake_case` of section 3.2 and namespaces in
/// `PascalCase`, so `ui_kit` becomes `UiKit`.
pub fn namespaceSegment(gpa: std.mem.Allocator, directory: []const u8) !?[]u8 {
    if (directory.len == 0) return null;
    if (!std.ascii.isAlphabetic(directory[0])) return null;

    var written: std.ArrayList(u8) = .empty;
    errdefer written.deinit(gpa);

    var capitalize = true;
    for (directory) |byte| {
        if (byte == '_' or byte == '-') {
            capitalize = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte)) {
            written.deinit(gpa);
            return null;
        }
        try written.append(gpa, if (capitalize) std.ascii.toUpper(byte) else std.ascii.toLower(byte));
        capitalize = false;
    }

    if (written.items.len == 0) {
        written.deinit(gpa);
        return null;
    }
    const owned: []u8 = try written.toOwnedSlice(gpa);
    return owned;
}

pub fn deinit(self: *Project, gpa: std.mem.Allocator) void {
    for (self.files) |*file| {
        file.source.deinit(gpa);
        gpa.free(file.namespace);
    }
    gpa.free(self.files);
    if (self.enclosing_project) |enclosing| gpa.free(enclosing);
    for (self.bad_directories) |bad| gpa.free(bad.path);
    gpa.free(self.bad_directories);
    self.* = undefined;
}

/// The sources, in the order diagnostics index them.
pub fn sources(self: Project, gpa: std.mem.Allocator) ![]Source {
    const out = try gpa.alloc(Source, self.files.len);
    for (self.files, out) |file, *slot| slot.* = file.source;
    return out;
}

const testing = std.testing;

test "a directory name becomes a namespace segment" {
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "shapes", "Shapes" },
        .{ "ui_kit", "UiKit" },
        .{ "ui-kit", "UiKit" },
        .{ "Shapes", "Shapes" },
        .{ "a", "A" },
        .{ "shapes2", "Shapes2" },
        .{ "2shapes", null },
        .{ "_private", null },
        .{ "with space", null },
        .{ "", null },
    };
    for (cases) |case| {
        const produced = try namespaceSegment(testing.allocator, case[0]);
        defer if (produced) |written| testing.allocator.free(written);
        if (case[1]) |want| {
            try testing.expectEqualStrings(want, produced.?);
        } else {
            try testing.expect(produced == null);
        }
    }
}

test "project loading releases every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.em", .data = "var answer = 42\n" });
    try tmp.dir.createDirPath(testing.io, "shapes");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shapes/square.em", .data = "struct Square {}\n" });
    try tmp.dir.createDirPath(testing.io, "2bad");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "2bad/circle.em", .data = "struct Circle {}\n" });

    const Work = struct {
        fn run(gpa: std.mem.Allocator, io: std.Io, base: std.Io.Dir) !void {
            var project = try loadIn(gpa, io, base, "main.em");
            defer project.deinit(gpa);
        }
    };

    try testing.checkAllAllocationFailures(testing.allocator, Work.run, .{ testing.io, tmp.dir });
}

test "project loading keeps invalid directories tracked without dropping their files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.em", .data = "var answer = 42\n" });
    try tmp.dir.createDirPath(testing.io, "2bad");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "2bad/helper.em", .data = "var helper = 1\n" });

    var project = try loadIn(testing.allocator, testing.io, tmp.dir, "main.em");
    defer project.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), project.files.len);
    try testing.expectEqual(@as(usize, 1), project.bad_directories.len);
    try testing.expectEqualStrings("2bad", project.bad_directories[0].path);
}

test "project loading keeps nested invalid directories tracked with their full path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main.em", .data = "var answer = 42\n" });
    try tmp.dir.createDirPath(testing.io, "good/2bad");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "good/main.em", .data = "var helper = 1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "good/2bad/extra.em", .data = "var nested = 2\n" });

    var project = try loadIn(testing.allocator, testing.io, tmp.dir, "main.em");
    defer project.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), project.files.len);
    try testing.expectEqual(@as(usize, 1), project.bad_directories.len);
    try testing.expectEqualStrings("good/2bad", project.bad_directories[0].path);
    try testing.expectEqual(@as(u32, 0), project.bad_directories[0].file);
}
