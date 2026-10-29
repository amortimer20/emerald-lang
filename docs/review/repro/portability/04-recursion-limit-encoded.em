# 7.2: "The precise limit above the portable minimum is a resource boundary
# rather than program semantics." The interpreter's limit is exactly 1,000, and
# conformance/runtime-errors/recursion-limit.expected and
# constructor-recursion.expected both encode it as "(999 times)".
var deepest = 0
func down(n: Int): Int {
    deepest = n
    return down(n + 1) + 1
}
try {
    print(down(0))
}
catch error: RecursionError {
    print("deepest frame reached:", deepest)
}
