# A branch that always returns is left out of definite assignment, so the
# guard-clause shape works: `label` is only read on the path that assigned it.

func classify(n: Int): Int {
    var label: Int
    if n > 0 {
        label = 1
    }
    else {
        return 0
    }
    return label
}

print(classify(5), classify(-5))

# Every path returns, through an else-if chain.
func sign(n: Int): Int {
    if n > 0 {
        return 1
    }
    else if n < 0 {
        return -1
    }
    else {
        return 0
    }
}

print(sign(7), sign(-7), sign(0))
