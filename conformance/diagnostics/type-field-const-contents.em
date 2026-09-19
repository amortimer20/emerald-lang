# Section 4.3: a `const` type-level field's contents cannot change either.
struct Limits {
    const Limits.names: List[String] = []
    const Limits.corner: Corner = Corner(0)
}

struct Corner {
    var x: Int
}

Limits.names.append("a")
Limits.corner.x = 1
