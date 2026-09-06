# §3.2 said an enum has "no payloads, no methods" and meant the first: a tagged union is
# a different feature wearing the same keyword. A method is not - it is a function whose
# receiver happens to be an enum value, and without one every fact about an enum became a
# static parked on an unrelated type, which is a global operating on a receiver.

enum Piece {
    X, O

    func other(): Piece {
        return if self == Piece.X then Piece.O else Piece.X
    }

    func symbol(): String {
        return if self == Piece.X then "#" else "o"
    }

    func first?(): Bool {
        return self == Piece.X
    }

    static func opening(): Piece {
        return Piece.X
    }
}

print(Piece.X.other().name)
print(Piece.O.other().name)
print(Piece.X.symbol() + Piece.O.symbol())
print(Piece.X.first?())
print(Piece.opening().name)

# The values, and the surface an enum already had, are untouched.
print(Piece.values.map { p => p.symbol() }.join(","))
print(Piece.X.name)
print(Piece.X)
print(Piece.X == Piece.opening())

# A method can call another one on itself.
enum Mark {
    HIT, PRESENT, MISS

    func rank(): Int {
        return if self == Mark.HIT then 2 else if self == Mark.PRESENT then 1 else 0
    }

    func better_than?(other: Mark): Bool {
        return self.rank() > other.rank()
    }
}

print(Mark.HIT.better_than?(Mark.MISS))
print(Mark.MISS.better_than?(Mark.HIT))
