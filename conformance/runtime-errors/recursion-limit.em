# Section 7.2: repeated frames in a trace are summarized. The recursion stops at
# a fixed depth and raises its own error, so the case does not depend on the
# call limit, which 7.2 says is not part of the language.

func descend(n: Int): Int {
    if n == 0 {
        raise Error("reached the bottom")
    }
    return descend(n - 1)
}

print(descend(40))
