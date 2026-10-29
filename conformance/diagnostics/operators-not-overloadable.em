# Section 11.5: `//` and `**` are not overloadable.
struct Vector {
    const x: Float

    @operator("//")
    func floor_divide(other: Vector): Vector {
        return other
    }

    @operator("**")
    func power(other: Vector): Vector {
        return other
    }
}
