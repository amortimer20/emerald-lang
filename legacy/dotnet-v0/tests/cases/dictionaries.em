## Dictionary — the second compiler-owned container (§3.7).
var ages = ["ada": 36, "bo": 7]

## Looking one up gives back a maybe: a key that is not there is the ordinary case for
## a lookup, where a list position that is not there is a bug.
print(ages["ada"].or(0))
print(ages["nobody"].or(-1))
print(ages.count())

ages["cy"] = 12
ages["ada"] += 1
print(ages["ada"].or(0))

## Insertion order is kept, so output does not change between runs.
print(ages.keys().join(", "))
print(ages.values().join(", "))

print(ages.has_key?("bo"))
print(ages.has_key?("zz"))
print(ages.has_value?(12))

ages.remove("bo")
print(ages.count())

## [:] is the empty dictionary; [] is the empty list, and a bare [] has no key to say
## which was meant.
var empty: Dictionary<String, Int> = [:]
print(empty.empty?())

## Counting, which is what a dictionary is for, and where the maybe pays for itself.
var counts: Dictionary<String, Int> = [:]
for word in "the cat the hat the end".split(" ") {
    counts[word] = counts[word].or(0) + 1
}

counts.each { (word, n) => print("#{word}: #{n}") }
print(counts)
