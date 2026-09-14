## A bracketed list of elements is a set where a set is expected.
var seen: {String} = ["red", "green", "red"]
print(seen, seen.count)

seen.add("blue")
seen.add("red")
print(seen)

print(seen.contains?("blue"), seen.contains?("yellow"))
seen.remove("green")
print(seen, seen.empty?())

for colour in seen {
    print(colour)
}
print(seen.map { colour => colour.upper() })
seen.each_with_index { colour, index =>
    print(index, colour)
}
print(seen.all? { colour => colour.count >= 3 }, seen.one? { colour => colour == "red" })

## Without an expected set type, brackets build a list, so 8.2 names this.
print([1, 2, 2, 3].to_set())

## Section 8.4: membership decides equality, not insertion order.
const one: {Int} = [1, 2, 3]
const two: {Int} = [3, 2, 1]
print(one == two)

const empty: {String} = []
print(empty, empty.empty?())
