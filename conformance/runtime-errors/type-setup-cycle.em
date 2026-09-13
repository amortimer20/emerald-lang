# Section 14.1's initialization cycle, for type-level fields: `zero` is set up
# first, and its value calls a function that reads `made`, which is not set up
# until after it. The checker cannot see through the call, so this is raised.
struct Vector2 {
    var x: Float
    var y: Float
    const Vector2.zero = Vector2.origin()
    var Vector2.made = 0

    func Vector2.origin(): Vector2 {
        Vector2.made += 1
        return Vector2(0, 0)
    }
}

print("start")
print(Vector2.zero)
