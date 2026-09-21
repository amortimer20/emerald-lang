# Section 8.4: `equals`/`hash` back `==` and hashing only through
# `Equatable`/`Hashable`, and adoption is explicit like every other trait's
# (11.2). Declaring either method alone is a warning, not an error: calling
# it directly still works, so the program runs.
struct Point {
    var x: Int

    func equals(other: Point): Bool {
        return self.x == other.x
    }

    func hash(): Int {
        return self.x
    }
}

# Adopting both traits is the other half, and warns about nothing.
struct Marked with Hashable {
    var x: Int

    @override
    func equals(other: Marked): Bool {
        return self.x == other.x
    }

    @override
    func hash(): Int {
        return self.x
    }
}

print(Point(1).equals(Point(1)), Marked(2) == Marked(2))
