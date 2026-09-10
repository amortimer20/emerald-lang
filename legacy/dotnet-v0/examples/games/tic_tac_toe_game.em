# A free square shows its own number, so the board is also the instructions. Nobody has
# to be told the numbering, and there is no second diagram to keep in step with the first.

func cell(board: Board, square: Int): String {
    var piece = board[square]

    # Written as one if/else rather than an early return, because narrowing does not
    # yet survive a returning branch: after `if piece == nothing { return ... }` the
    # checker still calls piece a Piece?.
    if piece != nothing {
        return piece.name
    }
    else {
        return "#{square + 1}"
    }
}

func row(board: Board, first: Int): String {
    var cells: List<String> = []
    for square in first..(first + 2) {
        cells.add(TicTacToeGame.cell(board, square))
    }
    return "    " + cells.join(" | ")
}

func show(board: Board) {
    print()
    print(TicTacToeGame.row(board, 0))
    print("   ---+---+---")
    print(TicTacToeGame.row(board, 3))
    print("   ---+---+---")
    print(TicTacToeGame.row(board, 6))
    print()
}

func play() {
    Text.banner("Tic-tac-toe")
    print("You are X and go first. The computer plays perfectly, so a draw is a win.")

    var board = Board()
    var players: List<Player> = [Human(Piece.X), Computer(Piece.O)]
    var turn = 0

    while not board.over? {
        TicTacToeGame.show(board)

        var player = players[turn]
        var square = player.choose(board)
        board[square] = player.piece

        print("   #{player.name} takes #{square + 1}.") if turn == 1
        turn = (turn + 1) % 2
    }

    TicTacToeGame.show(board)

    var won = board.winner()
    if won == nothing {
        print("   A draw. That is the best there is against a perfect player.")
    }
    else if won == players[0].piece {
        print("   You win. That should not be possible - please report it.")
    }
    else {
        print("   Emerald wins.")
    }
}
