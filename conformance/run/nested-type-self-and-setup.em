# Section 14.3: `Self` in a nested type's method means the nested type, and reaching
# a nested type's type-level member sets up that nested type, not its encloser.
# (Constructing the nested type is a finding: docs/review/repro/rules/19.)
func note(text: String): Int {
    print("setting up #{text}")
    return 0
}

class Theme {
    var Theme.count = note("Theme")

    struct Pair {
        var left: Int
        var right: Int

        var Pair.made = note("Pair")

        func swapped(): Self {
            return Theme.Pair(left: self.right, right: self.left)
        }
    }
}

print("start")
print(Theme.Pair.made)
print(Theme.count)
const pair: Theme.Pair = Theme.Pair(left: 3, right: 4).swapped()
print(pair)
