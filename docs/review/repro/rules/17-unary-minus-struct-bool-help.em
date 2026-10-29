# Section 11.5: unary `-` is not overloadable, even on a type that registers `-`.
struct Point {
    const x: Int

    @operator("-")
    func subtract(other: Self): Self {
        return Point(self.x - other.x)
    }
}

print(-Point(1))
