## Dictionaries and sets.
##
## A list keeps things in order. A dictionary looks things up by name, and a
## set remembers whether it has seen something. All three are written with
## square brackets; what decides which you get is the `key: value` entries of a
## dictionary, and the type written around a set.
##
## Run it with `emerald run examples/dictionaries.em`.

## A dictionary maps keys to values, and keeps them in the order they went in.
var ages = ["Ava": 12, "Noah": 13]
print(ages)

## Looking one up can miss, so the answer may be absent. That is why `.or(...)`
## reads so naturally here: it says what to use when there is nothing.
print(ages["Ava"])
print(ages["Zed"].or(0))

## Assigning inserts a new entry, or replaces an existing value in place.
ages["Mia"] = 9
ages["Ava"] = 20
print(ages)

## Counting things is what a dictionary is reached for most often.
const words = ["red", "blue", "red", "green", "red"]
var counts: [String: Int] = []
for word in words {
    counts[word] = counts[word].or(0) + 1
}
print(counts)

## A dictionary's item is one `(key, value)` pair, so a loop or a block
## unpacks it into two names.
for (word, count) in counts {
    print("#{word} appears #{count} #{plural(count)}")
}

func plural(count: Int): String {
    return "time" if count == 1
    return "times"
}

## A set records what it has seen, once each, in the order it first saw it.
var seen: {String} = []
for word in words {
    seen.add(word)
}
print(seen, seen.count)
print(seen.contains?("blue"), seen.contains?("yellow"))

## A bracketed literal becomes a set when a set is what is expected. Where
## nothing expects one, `to_set` says so.
print(words.to_set())

## Both are values: a copy is independent of what it was copied from.
var copy = counts
copy["red"] = 0
print(counts["red"].or(0), copy["red"].or(0))
