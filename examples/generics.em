# Generics: one declaration that works for every type it is given

## A grid of anything: a game board of Strings, a map of Ints. `Item` stands
## for whatever type each grid is given; Emerald works it out from the fill.
class Grid[Item] {
    const width: Int
    const height: Int
    var _cells: List[Item] = []

    constructor(width: Int, height: Int, fill: Item) {
        self.width = width
        self.height = height
        for _ in 0..<width * height {
            self._cells.append(fill)
        }
    }

    func get(x: Int, y: Int): Item {
        return self._cells[y * self.width + x]
    }

    func set(x: Int, y: Int, cell: Item) {
        self._cells[y * self.width + x] = cell
    }

    ## A method can have a type of its own: what `change` gives back.
    func mapped[Result](change: func(Item): Result): Grid[Result] {
        var result = Grid(self.width, self.height, change(self.get(0, 0)))
        for y in 0..<self.height {
            for x in 0..<self.width {
                result.set(x, y, change(self.get(x, y)))
            }
        }
        return result
    }
}

const board = Grid(3, 3, ".")
board.set(1, 1, "X")
print(board.get(1, 1), board.get(0, 0))

## The type can also be written where the value is kept.
const heights: Grid[Float] = Grid(2, 2, 0)
heights.set(1, 0, 2.5)
print(heights.mapped { height => height > 1 }.get(1, 0))

## A function over anything with an order. `with Ordered` says which types
## may be given: Ints, Floats, Strings, and types that adopt `Ordered`.
func largest[Item with Ordered](items: List[Item]): Item? {
    if items.empty?() {
        return nothing
    }
    var best = items[0]
    for item in items {
        best = item if item > best
    }
    return best
}

print(largest([3, 9, 4]), largest(["pear", "fig"]))

## An enum of anything: a linked list, built one link at a time.
enum Chain[Item] {
    end
    link(item: Item, rest: Chain[Item])

    const length: Int {
        return case self {
            when Chain.end then 0
            when Chain.link(_, rest) then 1 + rest.length
        }
    }
}

var names: Chain[String] = Chain.end
for name in ["Ava", "Noah", "Mia"] {
    names = Chain.link(name, names)
}
print(names.length, names)
