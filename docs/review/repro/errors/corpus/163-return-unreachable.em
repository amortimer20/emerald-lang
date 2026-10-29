# Mistake: code after return (line 4). Source: guide docs/language/core.md; rewrite-context 17.1.
func double(n: Int): Int {
    return n * 2
    print("doubled")
}
print(double(3))
