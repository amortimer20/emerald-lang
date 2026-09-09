## A primitive satisfies the operator traits it has always behaved as. None of the
## arithmetic below is new — `1 + 2` and `"apple" < "banana"` worked before any of it was
## written down. What is new is the type system agreeing: a trait named as a parameter type
## used to refuse an Int, so the same question had one answer from the operator and the
## opposite from the checker.

func bigger?(a: Ordered, b: Ordered): Bool {
    return true
}

func joined(a: Addable): String {
    return "took one"
}

print(bigger?(3, 9))
print(bigger?("apple", "banana"))
print(bigger?(2.5, 1.0))
print(joined(1))
print(joined("text"))

## Bool is Equatable and deliberately not Ordered: there is no meaningful order on true
## and false, and inventing one for symmetry is tidiness a student would have to unlearn.
func same?(a: Equatable): Bool {
    return true
}

print(same?(true))
