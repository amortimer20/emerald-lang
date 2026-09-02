## A user type reaches [] through Indexable. at gives reading; adding set_at gives
## writing, the same way a property's set body does.
class Grid with Indexable {
    var cells = ["."]

    constructor(size: Int) {
        self.cells.clear()
        size.times { self.cells.add(".") }
    }

    func at(index: Int): String {
        return self.cells[index]
    }

    func set_at(index: Int, value: String) {
        self.cells[index] = value
    }

    func to_string(): String { return self.cells.join("") }
}

var g = Grid(5)
g[0] = "#"
g[4] = "#"
print(g[0])
print(g[1])
print(g.to_string())
