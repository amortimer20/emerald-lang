# Section 10.4: a type-level function is declared inside its type.
struct Vector2 {
    var x: Float
    var y: Float
}

func Vector2.origin(): Vector2 {
    return Vector2(0, 0)
}
