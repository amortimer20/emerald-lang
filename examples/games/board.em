class Board with Indexable

static const SIZE = 9

# The eight ways to win, written out. Nine squares do not deserve a loop.
static const LINES = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6]
]

var squares: List<Piece?>

constructor() {
    self.squares = []
    Board.SIZE.times { self.squares.add(nothing) }
}

func at(square: Int): Piece? {
    return self.squares[square]
}

func set_at(square: Int, piece: Piece?) {
    self.squares[square] = piece
}

func free?(square: Int): Bool {
    return self.squares[square] == nothing
}

func free(): List<Int> {
    var open: List<Int> = []
    for square in 0..(Board.SIZE - 1) {
        open.add(square) if self.free?(square)
    }
    return open
}

var full?: Bool {
    get { return self.free().empty?() }
}

# A copy with one more piece on it. The minimax search explores thousands of positions,
# and a board it can hand around without unwinding is far harder to get wrong than one
# it has to remember to put back.
func after(square: Int, piece: Piece): Board {
    var next = Board()
    for i in 0..(Board.SIZE - 1) {
        next[i] = self[i]
    }
    next[square] = piece
    return next
}

func winner(): Piece? {
    for line in Board.LINES {
        var first = self[line[0]]
        continue if first == nothing
        return first if self[line[1]] == first and self[line[2]] == first
    }
    return nothing
}

var over?: Bool {
    get { return self.winner() != nothing or self.full? }
}
