# Sets: membership without duplicates (§3.7)
#
# The third core container, and the one with no literal of its own. The braces another
# language would spend on `{1, 2, 3}` are a block and a trailing lambda here, and the
# bracket already belongs to lists — so a set is written as a list and converted.

var vowels = ["a", "e", "i", "o", "u"].to_set()

print("how many vowels: #{vowels.count()}")
print("is e one?        #{vowels.contains?("e")}")
print("is z one?        #{vowels.contains?("z")}")

# Duplicates collapse on the way in.
var rolls = [3, 1, 3, 2, 1, 2].to_set()
print()
print("rolled: #{rolls.to_list().join(", ")}")

# Insertion order is kept, the same way a dictionary keeps it. Order is not part of what
# a set means — which is exactly why it must not vary between runs, because a difference
# with no cause is one you cannot attribute.

rolls.add(6)
rolls.remove(1)
print("after:  #{rolls.to_list().join(", ")}")

# A set holds one kind of thing, so a loop knows what it gets. A dictionary does not get
# this: it holds pairs, and there is no pair type to bind.
print()
for n in rolls {
    print("  rolled a #{n}")
}

# The operations that are the reason to reach for one.
var monday = ["ada", "bo", "cy"].to_set()
var tuesday = ["bo", "cy", "dee"].to_set()

print()
print("either day:  #{monday.union(tuesday).to_list().join(", ")}")
print("both days:   #{monday.intersect(tuesday).to_list().join(", ")}")
print("monday only: #{monday.difference(tuesday).to_list().join(", ")}")
print("bo and cy came both days: #{["bo", "cy"].to_set().subset_of?(monday)}")

# Remembering what has already been seen — the everyday use.
print()
var seen: Set<String> = [].to_set()

for word in "the cat sat on the mat the end".split(" ") {
    print("  first time: #{word}") unless seen.contains?(word)
    seen.add(word)
}

# Printed with braces, so a set can never be mistaken for a list or a dictionary.
print()
print(monday)

# Members are Int, Float, String, or Bool — finding a value again needs hashing, and a
# type's own equals? is not something the lookup can consult.
