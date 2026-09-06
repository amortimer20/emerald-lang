class Human extends Player

constructor(piece: Piece) {
    super(piece, "You")
}

func choose(board: Board): Int {
    while true {
        var typed = read_line("   your move (1-9)> ").trim()
        var square = typed.to_int_maybe()

        if square == nothing {
            print("   Type a number from 1 to 9.")
            continue
        }

        # Squares are numbered 1-9 on the screen and 0-8 in the list. One subtraction,
        # in one place, is the whole of that translation.
        var index = square.or(0) - 1

        unless index.between?(0, Board.SIZE - 1) {
            print("   That is not a square.")
            continue
        }

        unless board.free?(index) {
            print("   That square is taken.")
            continue
        }

        return index
    }
}
