## Section 8.3: keys are values with stable equality and hashing.
var byPair: Dict[(String, Int), String] = [("a", 1): "first"]
byPair[("b", 2)] = "second"
print(byPair, byPair[("a", 1)], byPair[("z", 9)])

var rates: Dict[Float, String] = [1.5: "low"]
rates[2] = "high"
print(rates, rates[2.0])

var flags: Dict[Bool, String] = [true: "yes", false: "no"]
print(flags, flags[true])

## Section 9.2 compares strings after normalizing, and that reaches keys.
## Both spellings below are the same text: composed, and `e` plus an accent.
var byName: Dict[String, Int] = ["café": 1]
print(byName["cafe\u{301}"], byName.contains_key?("cafe\u{301}"))

## Section 8.1: a dictionary is a value, so a copy is independent.
var original = ["x": 1]
var copy = original
copy["y"] = 2
print(original, copy)

## Counting, which is what a dictionary is most often reached for.
var counts: Dict[String, Int] = []
for word in ["red", "blue", "red"] {
    counts[word] = counts[word].or(0) + 1
}
print(counts)
