trait Shape {
    func area(): Int
}

struct Square {
    func area(): Int {
        return 1
    }
}

const square: Shape = Square()