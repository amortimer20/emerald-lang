//! Close-spelling helpers for diagnostics. Dependency-free, so any stage may
//! use them.

const std = @import("std");

/// The longest word `distance` compares; longer words are never close.
const max_length = 32;

/// Optimal string alignment distance: insertions, deletions, substitutions, and
/// swaps of two neighboring characters each cost one, so `fucn` is one edit
/// from `func`. Case-sensitive. Words longer than 32 bytes are reported as
/// infinitely far, which keeps the work bounded.
pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > max_length or b.len > max_length) return std.math.maxInt(usize);
    var rows: [3][max_length + 1]usize = undefined;
    var before = &rows[0]; // two rows back
    var previous = &rows[1];
    var current = &rows[2];
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |left, i| {
        current[0] = i + 1;
        for (b, 0..) |right, j| {
            const substitution = previous[j] + @intFromBool(left != right);
            var best = @min(substitution, @min(previous[j + 1], current[j]) + 1);
            if (i > 0 and j > 0 and left == b[j - 1] and a[i - 1] == right) {
                best = @min(best, before[j - 1] + 1);
            }
            current[j + 1] = best;
        }
        const reused = before;
        before = previous;
        previous = current;
        current = reused;
    }
    return previous[b.len];
}

/// The candidate nearest to `word` that is at most `max` edits away, or null.
/// The first of equally near candidates wins. A candidate equal to `word` is
/// not a suggestion.
pub fn closest(word: []const u8, candidates: []const []const u8, max: usize) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = max + 1;
    for (candidates) |candidate| {
        if (std.mem.eql(u8, word, candidate)) continue;
        const found = distance(word, candidate);
        if (found < best_distance) {
            best = candidate;
            best_distance = found;
        }
    }
    return best;
}

test "distance counts a swap of neighbors as one edit" {
    try std.testing.expectEqual(@as(usize, 0), distance("func", "func"));
    try std.testing.expectEqual(@as(usize, 1), distance("fucn", "func"));
    try std.testing.expectEqual(@as(usize, 1), distance("retrun", "return"));
    try std.testing.expectEqual(@as(usize, 1), distance("whlie", "while"));
    try std.testing.expectEqual(@as(usize, 1), distance("fnuc", "func"));
    try std.testing.expectEqual(@as(usize, 3), distance("kitten", "sitting"));
    try std.testing.expectEqual(@as(usize, 3), distance("", "abc"));
}

test "closest picks the nearest candidate within the bound" {
    const words = [_][]const u8{ "func", "for", "while" };
    try std.testing.expectEqualStrings("func", closest("fucn", &words, 1).?);
    try std.testing.expect(closest("banana", &words, 2) == null);
    try std.testing.expect(closest("func", &words, 1) == null);
}
