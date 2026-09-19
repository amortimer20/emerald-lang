## Section 8.6: `filter` and `reject` preserve Dictionary and Set receivers.
## Predicates run once in deterministic insertion order, and never change the source.

var ages = ["Ava": 12, "Noah": 13, "Mia": 9]
var age_calls = 0
const teens = ages.filter { (name, age) =>
    age_calls += 1
    return age >= 12
}
const younger = ages.reject { (_, age) => age >= 12 }
print(teens, younger, age_calls, ages)

const values: Set[Int] = [1, 2, 3, 4]
var value_calls = 0
const evens = values.filter { value =>
    value_calls += 1
    return value.even?()
}
const odds = values.reject { value => value.even?() }
print(evens, odds, value_calls, values)
