# What both kinds of player have in common, and the one thing they disagree about.
#
# The game loop below never asks which kind it is holding. That is the whole point of
# the abstract method: `player.choose(board)` reads a line or searches a game tree, and
# the loop cannot tell.

class Player

var piece: Piece
var name: String

constructor(piece: Piece, name: String) {
    self.piece = piece
    self.name = name
}

abstract func choose(board: Board): Int
