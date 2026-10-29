# Section 14.3: "Reaching a nested type's type-level member sets up that nested type's
# type-level fields (14.1), not its enclosing type's." Section 10.4: setup happens "the
# first time the type is constructed or one of its type-level members is reached".
# Constructing `Theme.Pair` constructs `Pair`, yet `Theme` is set up.
# Expected: start / setting up Pair / constructed. Actual: start / setting up Theme /
# constructed. The wrong type is set up, and `Pair` is not.
func note(text: String): Int {
    print("setting up #{text}")
    return 0
}

class Theme {
    var Theme.count = note("Theme")

    struct Pair {
        var left: Int

        var Pair.made = note("Pair")
    }
}

print("start")
const pair = Theme.Pair(left: 1)
print("constructed")
