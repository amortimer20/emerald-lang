trait Shape {
    func area(): Int
    func perimeter(): Int
}

struct Square {
    func area(): Int {
        return 1
    }

    func perimeter(): Int {
        return 4
    }
}

const square: Shape = Square()