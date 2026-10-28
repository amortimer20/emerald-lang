# Mistake: changing a parameter (line 5). Source: guide docs/language/core.md.
func countdown(n: Int) {
    while n > 0 {
        print(n)
        n -= 1
    }
}
countdown(3)
