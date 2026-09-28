# A function body checks against a private copy of only the module variables it
# uses (read or assigned, in its own statements, its lambdas, or its nested
# functions), so narrowing or assignment inside it never leaks to the top
# level, and every variable it does use is known there.
var count = 0
var total = 0
var best: Int? = nothing
var pair = (0, 0)
const label = "scores"
const unused_a = 1
const unused_b = 2
const unused_c = 3

func add(points: Int) {
    count += 1
    total += points
    if best == nothing or points > best.or(0) {
        best = points
    }
}

func summary(): String {
    # Narrowing a module variable inside a body stays inside it.
    if best != nothing {
        return "#{label}: #{count} added, best #{best}"
    }
    return "#{label}: none yet"
}

func through_a_lambda(): Int {
    # The lambda reads `total`; the enclosing body must know it.
    const reader = { => total }
    return reader()
}

func through_a_nested_function(): Int {
    func inner(): Int {
        return count * 10
    }
    return inner()
}

func swap_pair() {
    var first = 0
    var second = 0
    (first, second) = pair
    pair = (second, first)
}

print(summary())
add(5)
add(9)
add(3)
print(summary())
print(through_a_lambda(), through_a_nested_function())
pair = (1, 2)
swap_pair()
print(pair)
print(best.or(0) + unused_a + unused_b + unused_c)
