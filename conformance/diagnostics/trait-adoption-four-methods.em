trait Shape {
    func area(): Int
    func perimeter(): Int
    func corners(): Int
    func diagonals(): Int
}

struct Square {
    func area(): Int {
        return 1
    }

    func perimeter(): Int {
        return 4
    }

    func corners(): Int {
        return 4
    }

    func diagonals(): Int {
        return 2
    }
}

const square: Shape = Square()