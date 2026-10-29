# Mistake: continue outside a loop (line 4). Source: guide docs/language/core.md.
func check(n: Int) {
    if n < 0 {
        continue
    }
    print(n)
}
check(1)
