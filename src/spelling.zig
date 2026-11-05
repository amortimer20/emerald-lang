//! Close-spelling suggestions for diagnostics (section 17.2). Dependency-free,
//! so the parser, resolver, and checker share one rule.

const std = @import("std");

/// Section 17.2's close spellings: collects candidates and answers with the one
/// name a writer most likely meant, or null when none is close or several are.
/// A candidate qualifies when it differs only in case, or, for a name of three
/// letters or more, is one edit away (two for a name of ten letters or more).
/// Among those, only the closest counts, and it must be alone at that distance.
/// Only the error paths build one.
pub const Spelling = struct {
    name: []const u8,
    case_match: ?[]const u8 = null,
    case_count: usize = 0,
    near: ?[]const u8 = null,
    near_distance: usize = std.math.maxInt(usize),
    near_count: usize = 0,

    pub fn init(name: []const u8) Spelling {
        return .{ .name = name };
    }

    pub fn offer(self: *Spelling, candidate: []const u8) void {
        if (candidate.len == 0 or std.mem.eql(u8, candidate, self.name)) return;
        // A method key (`Type::name`) is never a name a writer meant.
        if (std.mem.indexOf(u8, candidate, "::") != null) return;
        if (std.ascii.eqlIgnoreCase(candidate, self.name)) {
            if (self.case_match) |earlier| if (std.mem.eql(u8, earlier, candidate)) return;
            self.case_match = candidate;
            self.case_count += 1;
            return;
        }
        if (self.name.len < 3) return;
        // Two edits are tolerated only in long names: between short ones they
        // are usually different words (`shout` and `sort`, `decrement` and
        // `increment`), and a wrong suggestion is worse than none.
        const limit: usize = if (self.name.len < 10) 1 else 2;
        const found = distance(self.name, candidate, limit);
        if (found > limit or found > self.near_distance) return;
        if (found < self.near_distance) {
            self.near = candidate;
            self.near_distance = found;
            self.near_count = 1;
            return;
        }
        if (self.near) |earlier| if (std.mem.eql(u8, earlier, candidate)) return;
        self.near_count += 1;
    }

    pub fn suggestion(self: Spelling) ?[]const u8 {
        if (self.case_count == 1) return self.case_match;
        if (self.case_count == 0 and self.near_count == 1) return self.near;
        return null;
    }
};

/// The optimal-string-alignment distance between two names: insertions,
/// deletions, substitutions, and a swap of neighbours each cost one. Anything
/// beyond `limit` may be reported as `limit + 1`, so a long or far-off name is
/// rejected without the full table.
pub fn distance(a: []const u8, b: []const u8, limit: usize) usize {
    const max_len = 64;
    if (a.len > max_len or b.len > max_len) return limit + 1;
    const gap = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (gap > limit) return limit + 1;

    var before: [max_len + 1]usize = undefined;
    var previous: [max_len + 1]usize = undefined;
    var current: [max_len + 1]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |left, i| {
        current[0] = i + 1;
        for (b, 0..) |right, j| {
            const cost: usize = if (left == right) 0 else 1;
            var best = @min(@min(previous[j + 1] + 1, current[j] + 1), previous[j] + cost);
            if (i > 0 and j > 0 and left == b[j - 1] and a[i - 1] == right) {
                best = @min(best, before[j - 1] + 1);
            }
            current[j + 1] = best;
        }
        before = previous;
        previous = current;
    }
    return previous[b.len];
}

test "close spellings need one clear candidate" {
    var typo = Spelling.init("totl");
    typo.offer("total");
    typo.offer("count");
    try std.testing.expectEqualStrings("total", typo.suggestion().?);

    var swapped = Spelling.init("pritn");
    swapped.offer("print");
    swapped.offer("print");
    try std.testing.expectEqualStrings("print", swapped.suggestion().?);

    var cased = Spelling.init("username");
    cased.offer("userName");
    try std.testing.expectEqualStrings("userName", cased.suggestion().?);

    // The closer of two candidates wins; two equally close ones do not.
    var closer = Spelling.init("pritn");
    closer.offer("write");
    closer.offer("print");
    try std.testing.expectEqualStrings("print", closer.suggestion().?);

    var ambiguous = Spelling.init("tota");
    ambiguous.offer("toty");
    ambiguous.offer("totb");
    try std.testing.expect(ambiguous.suggestion() == null);

    // A short name tolerates one edit only, and a name under three letters none.
    var short = Spelling.init("nme");
    short.offer("name");
    try std.testing.expectEqualStrings("name", short.suggestion().?);
    var two = Spelling.init("ab");
    two.offer("ac");
    try std.testing.expect(two.suggestion() == null);
    var far = Spelling.init("tot");
    far.offer("title");
    try std.testing.expect(far.suggestion() == null);
    var longer = Spelling.init("calculte_totl");
    longer.offer("calculate_total");
    try std.testing.expectEqualStrings("calculate_total", longer.suggestion().?);
}
