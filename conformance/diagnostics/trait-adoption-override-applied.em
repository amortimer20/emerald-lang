trait Shape {
    func area(): Int
}

struct Square with Shape {
    @override
    func area(): Int {
        return 1
    }
}

const square: Shape = Square()