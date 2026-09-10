# What is in a square. A square that is empty holds no Piece at all rather than a third
# value meaning "blank" — that is what Piece? is for, and it makes an unplayed square
# impossible to mistake for a played one.
#
# `other` used to live on Board, because an enum could hold nothing but names and a fact
# about a Piece had to be parked somewhere unrelated. Board.other(piece) is a function
# operating on a receiver, which is the shape §3.2 exists to not have.

enum Piece {
    X, O

    func other(): Piece {
        return if self == Piece.X then Piece.O else Piece.X
    }
}
