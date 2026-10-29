# Section 5.4: a slice whose start is after its end is an error, not an empty result.
const items = [1, 2, 3, 4]
print(items[2..<2])
const start = 3
print(items[start..<1])
