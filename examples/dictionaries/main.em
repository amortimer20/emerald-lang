# Dictionaries: keys to values (§3.7)
#
# The second of the three core containers. A literal shares the bracket with a list,
# and the colon says which it is — `{ }` is a block and a trailing lambda here, so
# `{ x: 1 }` could not be told from `{ x => 1 }`.

var ages = ["ada": 36, "bo": 7, "cy": 12]

print("ada is #{ages["ada"].or(0)}")
print("there are #{ages.count()} people")

# Looking one up gives back a maybe — Int? rather than Int. A key that is not there is
# the ordinary case for a lookup, not a mistake, so the type says so and .or(...) is how
# you decide what a miss means.
print("dee is #{ages["dee"].or(0)}")

if ages["bo"] != nothing {
    print("bo is here")
}

# Writing, updating, and removing.
ages["dee"] = 41
ages["ada"] += 1
ages.remove("cy")

print()
print("keys:   #{ages.keys().join(", ")}")
print("values: #{ages.values().join(", ")}")

# Insertion order is kept. .NET's dictionary makes no promise about order, and a program
# whose output shuffles between runs is the worst thing to hand a beginner — they cannot
# tell it from a bug of their own.

print()
print("has ada?  #{ages.has_key?("ada")}")
print("has zoe?  #{ages.has_key?("zoe")}")
print("anyone 7? #{ages.has_value?(7)}")

# Counting is what a dictionary is for, and where the maybe earns its place.
print()
var counts: Dictionary<String, Int> = [:]

for word in "the quick brown fox jumps over the lazy dog the end".split(" ") {
    counts[word] = counts[word].or(0) + 1
}

counts.each { (word, times) =>
    print("#{word} appears #{times} time(s)") if times > 1
}

# Keys are Int, Float, String, or Bool. A user type cannot be a key yet: looking one up
# needs hashing, and a type's own equals? is not something the lookup can consult.
var roman: Dictionary<Int, String> = [1: "I", 5: "V", 10: "X"]
print()
print("5 is #{roman[5].or("?")}")
