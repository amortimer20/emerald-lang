## A pair takes part in the shared operations, not only in printing and member access.
##
## Two of these were broken when Pair was built. Equality fell through to host equality,
## so a pair of structs was unequal to an identical pair even though the structs compared
## equal on their own -- and because list search uses ==, a list could not find a pair it
## visibly contained. Runtime overload selection had no Pair arm either, so a function
## taking a Pair matched nothing the moment it was overloaded.
##
## The same hand-written switch was missing function-shaped parameters, found by asking
## what else had never been added rather than by fixing what was reported.

struct Point {
    var x: Int
}

print(Point(1) == Point(1))
print(Pair(Point(1), 0) == Pair(Point(1), 0))
print(Pair(1, 2) == Pair(1, 2))
print(Pair([1], 0) == Pair([1], 0))
print(Pair(1, 2) == Pair(1, 3))

# List search uses ==, so this only works if a pair compares by value.
print([Pair(1, 2), Pair(3, 4)].contains?(Pair(3, 4)))

# A dictionary walks in pairs, and its entries compare the same way.
var scores = ["a": 1]
print(scores.to_list().contains?(Pair("a", 1)))

func describe(n: Int): String { return "an int" }
func describe(p: Pair<Int, Int>): String { return "a pair of #{p.first()} and #{p.second()}" }

print(describe(5))
print(describe(Pair(1, 2)))

func apply(n: Int): String { return "a number" }
func apply(f: func(): Int): String { return "a function giving #{f()}" }

func five(): Int { return 5 }

print(apply(3))
print(apply(five))
