struct Vector2 {
    const x: Float
    const y: Float
}

struct Bag {
    var values: [Int]
}

const first = Vector2(1, 2)
const copied = first
const labels: [Vector2: String] = [first: "point"]

print(first)
print(first.x)
print(first == copied)
print(first == Vector2(1, 2))
print(labels[Vector2(1, 2)].or("missing"))

var source = [1]
const bag = Bag(source)
source.append(2)
print(bag.values)
print(source)
