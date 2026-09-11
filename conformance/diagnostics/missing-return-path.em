# Section 7.2: every reachable path in a value-producing function returns a
# value. Without an else, a positive-only branch leaves a path that does not.

func sign(n: Int): Int {
    if n > 0 {
        return 1
    }
}
