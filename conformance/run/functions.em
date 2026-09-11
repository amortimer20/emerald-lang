# Section 7. Declarations, calls, returns, recursion, and the module scope.

func add(left: Int, right: Int): Int {
    return left + right
}

print(add(2, 3))

# A function with no result omits its return type.
func greet(times: Int) {
    print(times)
}

greet(1)

# Hoisted: called above its declaration.
print(double(21))

func double(n: Int): Int {
    return n * 2
}

# Recursion needs an explicit return type (section 7.2).
func factorial(n: Int): Int {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

print(factorial(10))

# So does a cycle, however long.
func even?(n: Int): Bool {
    if n == 0 {
        return true
    }
    return odd?(n - 1)
}

func odd?(n: Int): Bool {
    if n == 0 {
        return false
    }
    return even?(n - 1)
}

print(even?(10), odd?(7))

# Without recursion, the return type is inferred, widening where section 4.4
# allows. `1` comes back as a Float because the other return is one.
func pick(flag: Bool) {
    if flag {
        return 1
    }
    return 2.5
}

print(pick(true), pick(false))

# An Int widens to a Float parameter.
func show(value: Float) {
    print(value)
}

show(3)
