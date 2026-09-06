class Computer extends Player

constructor(piece: Piece) {
    super(piece, "Emerald")
}

func choose(board: Board): Int {
    var open = board.free()
    var best = open[0]
    var best_score = -100

    # Carrying the best score so far into the next search, rather than starting each one
    # open, is the same pruning again one level up.
    for square in open {
        var score = Computer.value(board.after(square, self.piece),
                                   self.piece,
                                   self.piece.other(),
                                   1, best_score, 100)
        if score > best_score {
            best_score = score
            best = square
        }
    }

    return best
}

# What this position is worth to `me`, if both sides play as well as they can.
#
# It cannot be beaten, because there is nothing to guess at: it plays out every game
# that could follow and takes the best one it is allowed to reach. Depth is in the score
# so a win in two beats a win in four, which is the difference between a machine that
# wins and one that toys with you.
#
# alpha and beta are the best either side has already been promised elsewhere in the
# tree. The moment this branch cannot beat that promise, the rest of it cannot matter,
# and the loop stops — searching every position outright took eleven seconds a move.
static func value(board: Board, me: Piece, turn: Piece, depth: Int,
                  alpha: Int, beta: Int): Int {
    var won = board.winner()

    if won != nothing {
        return if won == me then 10 - depth else depth - 10
    }

    return 0 if board.full?

    var mine = turn == me
    var best = if mine then -100 else 100
    var floor = alpha
    var ceiling = beta

    for square in board.free() {
        var score = Computer.value(board.after(square, turn), me, turn.other(),
                                   depth + 1, floor, ceiling)

        if mine {
            best = score if score > best
            floor = best if best > floor
        }
        else {
            best = score if score < best
            ceiling = best if best < ceiling
        }

        break if ceiling <= floor
    }

    return best
}
