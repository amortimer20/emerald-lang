# The opponent is worth testing because it is the only part of the three games that can
# be wrong without looking wrong. A hangman that forgets a letter is obvious on screen;
# a search that misses a block just looks like a game you won.

func played(squares: List<Int>): Board {
    var board = Board()
    var turn = Piece.X
    for square in squares {
        board[square] = turn
        turn = turn.other()
    }
    return board
}

@test
func takes_a_win_it_is_offered() {
    # X: 0, 1   O: 3, 4   and it is O's turn with 3-4-5 open at 5.
    var board = ComputerTest.played([0, 3, 1, 4])
    assert Computer(Piece.O).choose(board) == 5
}

@test
func blocks_a_loss_it_is_facing() {
    # X holds 0 and 1 and will take 2 next turn unless O stops it.
    var board = ComputerTest.played([0, 4, 1])
    assert Computer(Piece.O).choose(board) == 2
}

# Winning beats blocking. A player that only ever blocks draws games it had won.
@test
func wins_rather_than_blocks() {
    # X threatens 6 (0-3-6). O threatens 5 (3-4-5)... and O can simply take it.
    var board = Board()
    board[0] = Piece.X
    board[3] = Piece.O
    board[1] = Piece.X
    board[4] = Piece.O
    board[7] = Piece.X
    assert Computer(Piece.O).choose(board) == 5
}

# Two perfect players draw. This is the property that says the search is right - not
# that it makes a particular move, but that it cannot be beaten by itself.
@test
func draws_against_itself() {
    for opening in [0, 1, 4] {
        var board = Board()
        board[opening] = Piece.X
        var turn = Piece.O

        while not board.over? {
            board[Computer(turn).choose(board)] = turn
            turn = turn.other()
        }

        assert board.winner() == nothing
    }
}
