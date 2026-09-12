func copy_marker(value: Marker): Marker {
    return value
}

const first: Marker = Marker()
const copied = copy_marker(first)
const labels: [Marker: String] = [first: "ready"]

print(first)
print(first == copied)
print(labels[Marker()].or("missing"))

struct Marker {
}
