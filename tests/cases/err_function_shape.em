# A function value is the one thing with a whole shape written down, and it used to be
# compared only on how many parameters it had - so this was accepted, g was called with
# an Int, and its answer used as a String.

func take(f: func(Int): Int): Int {
    return f(1)
}

func g(s: String): String {
    return s
}

print(take(g))
