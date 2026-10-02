trait Shape {
    func area(): Int

    func describe(): String {
        return "shape"
    }
}

struct Square {
    func area(): Int {
        return 1
    }
}

const square: Shape = Square()
