# Section 6.5: a nested function declared after a `return` is hoisted, so it is not
# unreachable code and may be called before its declaration.
func outer(): Int {
    return helper() + 1

    func helper(): Int {
        return 41
    }
}

print(outer())
