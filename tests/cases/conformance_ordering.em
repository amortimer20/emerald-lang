## The second conformance vector: every place the backend chooses a comparer or an
## iteration order, and could choose a different one than the interpreter did.
##
## This file exists because sort and < disagreed. sort used .NET's default comparer,
## which for strings is culture-sensitive, so ["b", "A", "a", "B"].sort() answered
## a, A, b, B while "a" < "B" answered false -- two orders in one language. Worse, the
## sorted one depended on the machine's locale, so the same program could print
## different output on a different computer, which is exactly what a beginner cannot
## tell apart from a bug of their own.

## One order, and it is ordinal: uppercase sorts before lowercase because that is where
## the code points are.
print(["b", "A", "a", "B"].sort().join(","))
print(["b", "A", "a", "B"].min())
print(["b", "A", "a", "B"].max())
print(["bb", "A", "ccc"].sort_by { s => s }.join(","))
print(["apple", "Fig", "date"].min_by { s => s })

## And the operators agree with it, which is the property that was broken.
print("a" < "B")
print("Z" < "a")
print("A" < "a")
print(["b", "A", "a", "B"].sort().first() == ["b", "A", "a", "B"].min())

## Numbers keep their own order inside the same comparer.
print([3, -1, 10, 2].sort().join(","))
print([3.5, -1.5, 10.0].sort().join(","))

## Insertion order, promised by the design and the reason a dictionary cannot be the
## BCL's. A backend emitting System.Collections.Generic.Dictionary would pass this by
## luck today and stop passing it after the first removal.
var scores = ["zeta": 1, "alpha": 2, "middle": 3]
print(scores.keys().join(","))
scores.remove("alpha")
scores["beta"] = 4
print(scores.keys().join(","))

var seen = [3, 1, 2, 1].to_set()
print(seen.to_list().join(","))
