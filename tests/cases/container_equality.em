## A container is a value in the same sense a struct is, so two holding the same things
## are the same thing. Before this `[1, 2] == [1, 2]` was false — and §3.7's promise that
## list search uses == made that answer spread, so a list of lists could not find a list
## it visibly contained.
print([1, 2] == [1, 2])
print([1, 2] == [2, 1])
print([1, 2] == [1, 2, 3])

## Which is what makes searching a nested list work at all.
print([[1, 2], [3]].contains?([3]))
print([[1], [2]].index_of([2]))

## A set ignores order, because order is not part of what a set is.
print([1, 2].to_set() == [2, 1].to_set())
print([1, 2].to_set() == [1].to_set())

## A dictionary compares its pairs. §3.7 keeps insertion order, but two dictionaries with
## the same pairs answer every question the same way, so order is not part of sameness.
print(["a": 1, "b": 2] == ["b": 2, "a": 1])
print(["a": 1] == ["a": 2])

## All the way down, and through a struct.
struct P { var x: Int }
print([[P(1)]] == [[P(1)]])

## has_value? asks the same question contains? does, and now gets the same answer. It
## used to go through .NET's own equality, so a dictionary said it did not hold a struct
## that a list beside it found without trouble.
var d: Dictionary<String, P> = [:]
d["a"] = P(1)
print(d.has_value?(P(1)))
print([P(1)].contains?(P(1)))

## A class is still compared by identity: that is what == means for one, and nothing has
## said otherwise.
class C { var n: Int = 1 }
print(C() == C())
