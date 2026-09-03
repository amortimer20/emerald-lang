## Set — the third core container (§3.7). No literal of its own: the braces another
## language would use are a block and a trailing lambda here, and the bracket is a
## list's. So a set is written as a list and converted.
var vowels = ["a", "e", "i", "o", "u"].to_set
print(vowels.count)
print(vowels.contains?("e"))
print(vowels.contains?("z"))

## Duplicates collapse. Order is what you put them in, and stays that way between runs.
var repeated = [3, 1, 3, 2, 1].to_set
print(repeated.to_list.join(", "))

repeated.add(9)
repeated.remove(1)
print(repeated.to_list.join(", "))

## A set holds one kind of thing, so a loop knows what it gets — unlike a dictionary,
## which holds pairs and has no pair type to bind.
for n in repeated { print(n * 10) }

## The operations that are the point of having one.
var a = [1, 2, 3].to_set
var b = [3, 4].to_set
print(a.union(b).to_list.join(","))
print(a.intersect(b).to_list.join(","))
print(a.difference(b).to_list.join(","))
print([1, 2].to_set.subset_of?(a))
print(b.subset_of?(a))

var empty: Set<String> = [].to_set
print(empty.empty?)

## Printed with braces, so it cannot be mistaken for a list or a dictionary.
print(a)

## Remembering what has been seen, which is what a set is for.
var seen: Set<String> = [].to_set
for word in "the cat the hat the end".split(" ") {
    print(word) unless seen.contains?(word)
    seen.add(word)
}
