trait Shape {
    func area(): Int

    func describe(): String {
        return "shape"
    }
}

struct Square with Shape {
    @override
    func area(): Int {
        return 1
    }

    @override
    func describe(): String {
        return "square"
    }
}

const square: Shape = Square()
