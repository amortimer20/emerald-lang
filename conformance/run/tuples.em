const entry = ("score", 10)
print(entry)
print(entry.0, entry.1)

const nested = ((1, (2, 3)), [4, 5])
print(nested)
print(nested.0.1.0, nested.1.count)

print(("a", 1) == ("a", 1), ("a", 1) == ("a", 2))
print(([1], ("x", 2)) == ([1], ("x", 2)))

const rates: (Float, Int) = (1, 2)
print(rates)

const grouped = (1)
const trailing = (2,)
print(grouped + trailing)
