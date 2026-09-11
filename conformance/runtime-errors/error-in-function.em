# Section 13.2: an unhandled error reports the calls that led to it, innermost
# first.

func divide(left: Int, right: Int): Float {
    return left / right
}

func ratio(n: Int): Float {
    return divide(n, 0)
}

print(ratio(4))
