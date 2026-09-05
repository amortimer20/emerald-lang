# Indexing: a[i] through the Indexable trait (§3.2)
#
# Same shape as the arithmetic operators — the bracket is a method underneath, so a
# type earns [] by mixing in a trait and writing an ordinary method.

# Lists index natively, for reading and writing.
var scores = [10, 20, 30]
print("second score:  #{scores[1]}")

scores[1] = 99
scores[2] += 5
print("after writing: #{scores.join(", ")}")

# A user type opts in. `at` gives reading; adding `set_at` gives writing, exactly the
# way a var with only a get body is read-only until a set body is added.
class Board with Indexable {
    var squares: List<String>

    constructor(size: Int) {
        self.squares = []
        size.times { self.squares.add(".") }
    }

    func at(square: Int): String {
        return self.squares[square]
    }

    func set_at(square: Int, mark: String) {
        self.squares[square] = mark
    }

    func to_string(): String {
        return self.squares.join(" ")
    }
}

var board = Board(9)
board[0] = "X"
board[4] = "O"
board[8] = "X"

print()
print("square 4:      #{board[4]}")
print("board:         #{board.to_string()}")

# Leave set_at out and the type is read-only — `menu[0] = "x"` would not compile.
class Menu with Indexable {
    var items: List<String> = ["new game", "load", "quit"]

    func at(position: Int): String {
        return self.items[position]
    }

    func count(): Int {
        return self.items.count()
    }
}

var menu = Menu()
print()
for i in 0..menu.count() - 1 {
    print("  #{i + 1}. #{menu[i]}")
}
