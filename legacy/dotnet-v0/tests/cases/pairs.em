# Pair: two values travelling together. Compiler-owned like List and Dictionary, so
# §5.3's deferral of declarable generics is untouched -- and it needs no new type
# syntax, since Pair<A, B> is the generic grammar that already exists.

var best: Pair<String, Int> = Pair("ada", 95)
print(best)
print(best.first())
print(best.second())

# A record underneath, so two pairs holding the same things are the same pair
print(Pair("a", 1) == Pair("a", 1))
print(Pair("a", 1) == Pair("a", 2))

# Taking one apart, which is the only reason a pair is worth having
var (name, score) = best
print("#{name} scored #{score}")

var scores = ["ada": 95, "alan": 88, "grace": 91]

# A dictionary walks in pairs, and now there is a type for one
for (who, mark) in scores {
    print("#{who}: #{mark}")
}

# The members that hand an element back work on a dictionary now. This was three
# separate features waiting on one missing type.
print(scores.to_list())
print(scores.find { (who, mark) => mark < 90 })

var (top, highest) = scores.max_by { (who, mark) => mark }.must()
print("top: #{top} #{highest}")

# zip had nowhere to put what it joined
var names = ["ada", "alan"]
var marks = [95, 88]
print(names.zip(marks))
for (n, m) in names.zip(marks) {
    print("#{n} -> #{m}")
}

# Stops at the shorter side rather than padding with nothing
print(names.zip([1, 2, 3]))
print([1, 2, 3].zip(names))
