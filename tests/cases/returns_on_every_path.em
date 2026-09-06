# The forms that do settle it. A throw is a way out even though it returns nothing -
# nobody receives the missing value, because nobody receives anything.

func graded(score: Int): String {
    if score >= 80 { return "pass" } else { return "resit" }
}

func clamped(n: Int): Int {
    return 0 if n < 0
    return n
}

# while true has no way to fall out of it, so it needs nothing after it.
func first_even(from: Int): Int {
    var n = from
    while true {
        return n if n.even?()
        n += 1
    }
}

func refuses(n: Int): Int {
    throw "no"
}

func either_way(text: String): Int {
    try { return text.to_int() } catch problem { return 0 }
}

# Nothing promised, nothing to check.
func announce(n: Int) {
    print("n is #{n}")
}

print(graded(90))
print(clamped(-5))
print(first_even(7))
print(either_way("banana"))
announce(3)

try { print(refuses(1)) } catch problem { print(problem.message()) }
