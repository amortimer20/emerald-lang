# A program's own random_fraction hides the built-in, with a warning.

func random_fraction(): Float {
    return 0.5
}
print(random_fraction())
print(Emerald.random_fraction(1))
print(Random(1).next_fraction(2))
const pick = Emerald.random_fraction
