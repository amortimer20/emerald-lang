# Mistake: misspelled named argument (line 7). Source: guide docs/language/core.md.
func greet(name: String, times: Int = 1) {
    for _ in 1..times {
        print("Hello " + name)
    }
}
greet("Ava", tims: 2)
