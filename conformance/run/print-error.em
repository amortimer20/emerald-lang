# Section 15.2's `print_error` shows its values exactly as `print` does, then
# ends the line, on standard error. The conformance runner joins standard error
# to standard output, so its lines appear here in the order they were written;
# `emerald.zig`'s own tests check that they go to a stream of their own.
struct Score {
    var points: Int
}

print("first")
print_error("No file named scores.txt")
print_error("several", 1, 2.5, true, nothing, [1, 2], Score(3))
print_error()
print("last")
