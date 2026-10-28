# random_fraction and Random.next_fraction give 0.0 <= x < 1.0.

var inside = true
for _ in 1..1000 {
    const fraction = random_fraction()
    if fraction < 0.0 or fraction >= 1.0 {
        inside = false
    }
}
print(inside, Emerald.random_fraction() < 1.0)

# A seeded generator repeats, fractions and whole numbers interleaved.
const first = Random(42)
const second = Random(42)
var same = true
for _ in 1..100 {
    const fraction = first.next_fraction()
    if fraction != second.next_fraction() or fraction < 0.0 or fraction >= 1.0 {
        same = false
    }
    if first.next(1..6) != second.next(1..6) {
        same = false
    }
}
print(same)
print(Random(7).next_fraction() == Random(7).next_fraction())
