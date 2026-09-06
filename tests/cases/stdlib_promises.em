## §3.7's claims, as a program. Each line is a promise the section makes, and the point
## of writing them down here is that a promise with no test is how four of them survived
## being false.

## Dictionary literals, and the empty one that needs the colon to stay a dictionary.
var ages = ["ada": 36, "bo": 7]
var empty: Dictionary<String, Int> = [:]
print("#{ages.count()} #{empty.count()}")

## Looking a key up gives back V?, never a failure — a miss is ordinary.
print(ages["ada"].or(0))
print(ages["nobody"].or(-1))

## Insertion order, kept. Removing and re-adding puts it at the end, which is what
## "insertion order" has to mean for the promise to be worth anything.
var seen: Dictionary<String, Int> = [:]
for w in ["zeta", "alpha", "mu", "beta"] { seen[w] = 1 }
print(seen.keys().join(", "))
seen.remove("mu")
seen["mu"] = 2
print(seen.keys().join(", "))

## A set keeps it too.
var s = ["zeta", "alpha", "mu"].to_set()
s.add("beta")
s.remove("alpha")
s.add("alpha")
print(s.to_list().join(", "))

## A set is looped over directly, where a dictionary has to say keys or values.
for x in [3, 1].to_set() { print(x) }

## Searching a list uses ==, so a struct is found by its contents.
struct P { var x: Int }
var route = [P(1), P(2)]
print(route.contains?(P(2)))
print(route.index_of(P(2)))
route.remove(P(1))
print(route.count())

## The methods that can miss give back T?, including on an empty list.
var xs = [3, 1, 2]
print(xs.find { n => n > 100 }.or(-1))
print(xs.first().or(-1))
print(xs.min().or(-1))
var none: List<Int> = []
print(none.max().or(-1))

## A block's parameter types come from the receiver, with nothing written down.
print(["aa", "b"].filter { w => w.count() > 1 }.join(","))
ages.each { k, v => print("#{k} is #{v}") }

## Math is a module, not a sprinkle on Float.
print(Math.sqrt(16.0))

## .chars is a List<String> of graphemes.
var cs = "héllo".chars()
print("#{cs.count()} #{cs[1]} #{cs.join("-")}")

## Three conversions, three behaviors, three names.
print("42".to_int())
print("x".to_int_or(0))
print("42".to_int_maybe().or(-1))
print("x".to_int_maybe().or(-1))
