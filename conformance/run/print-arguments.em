# Section 5.2 evaluates a call's arguments left to right, all of them before the
# call happens. `print` is a call like any other, so the two lines each argument
# prints come first, and then the line `print` builds from their results.

func first(): Int {
    print(10)
    return 1
}

func second(): Int {
    print(20)
    return 2
}

print(first(), second())
