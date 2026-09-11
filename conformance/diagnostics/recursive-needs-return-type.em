# Section 7.2: a recursive function needs an explicit return type, so checking
# does not depend on inferring it from a call to itself.

func factorial(n: Int) {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}
