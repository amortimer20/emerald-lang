# Section 11.3: a generic class, built with its type inferred from an
# argument, from an annotation, and with whole numbers where `T` is `Float`.
class Grid[T] {
    const width: Int
    const height: Int
    var _cells: List[T] = []

    constructor(width: Int, height: Int, fill: T) {
        self.width = width
        self.height = height
        for index in 0..<width * height {
            self._cells.append(fill)
        }
    }

    func get(x: Int, y: Int): T {
        return self._cells[y * self.width + x]
    }

    func set(x: Int, y: Int, cell: T) {
        self._cells[y * self.width + x] = cell
    }

    func row(y: Int): List[T] {
        return self._cells[y * self.width..<(y + 1) * self.width]
    }
}

const board = Grid(3, 3, ".")
board.set(1, 1, "X")
print(board.get(1, 1), board.get(0, 0).upper())
print(board.row(1))

const counts: Grid[Int] = Grid(2, 2, 0)
counts.set(1, 1, 7)
print(counts.get(1, 1) + 1)

# Whole numbers become Floats on the way in, as they do in a List[Float].
const readings: Grid[Float] = Grid(2, 2, 0)
readings.set(0, 0, 5)
print(readings.get(0, 0), readings.get(1, 1), readings.row(0))
