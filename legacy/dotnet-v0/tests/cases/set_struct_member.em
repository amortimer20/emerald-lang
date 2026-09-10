## A struct is held by its fields. Two built the same way are one member, and one built
## later finds what an equal one stored -- the hash comes from the same fields == reads.
struct Point {
    var x: Int
    var y: Int
}

var seen = [Point(1, 2), Point(1, 2), Point(3, 4)].to_set()
print(seen.count())
print(seen.contains?(Point(3, 4)))
print(seen.contains?(Point(9, 9)))
