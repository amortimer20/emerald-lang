@test
func starts_empty() {
    var board = Board()
    assert board.free().count() == 9
    assert board[0] == nothing
    assert not board.full?
    assert board.winner() == nothing
}

@test
func sees_a_row() {
    var board = Board()
    for square in [0, 1, 2] {
        board[square] = Piece.X
    }
    assert board.winner() == Piece.X
    assert board.over?
}

@test
func sees_a_column() {
    var board = Board()
    for square in [1, 4, 7] {
        board[square] = Piece.O
    }
    assert board.winner() == Piece.O
}

@test
func sees_both_diagonals() {
    var down = Board()
    for square in [0, 4, 8] {
        down[square] = Piece.X
    }
    assert down.winner() == Piece.X

    var up = Board()
    for square in [2, 4, 6] {
        up[square] = Piece.O
    }
    assert up.winner() == Piece.O
}

# Three of a kind in no line at all is not a win, which is the case a loop over the
# squares rather than over the lines gets wrong.
@test
func does_not_see_a_scattering() {
    var board = Board()
    for square in [0, 1, 5] {
        board[square] = Piece.X
    }
    assert board.winner() == nothing
}

@test
func is_full_and_drawn() {
    var board = Board()
    # X O X / X O O / O X X - full, and nobody has a line.
    for square in [0, 2, 3, 7, 8] {
        board[square] = Piece.X
    }
    for square in [1, 4, 5, 6] {
        board[square] = Piece.O
    }
    assert board.full?
    assert board.winner() == nothing
    assert board.over?
}

# The search hands boards around instead of taking moves back, so `after` must never
# touch the board it was given.
@test
func leaves_the_original_alone() {
    var board = Board()
    var next = board.after(4, Piece.X)
    assert board[4] == nothing
    assert next[4] == Piece.X
    assert board.free().count() == 9
    assert next.free().count() == 8
}
