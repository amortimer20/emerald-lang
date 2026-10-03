trait Shape {
    func area(): Int
}

struct Square {
    func area(): Int {
        return 4
    }
}

const s: Shape = Square()

class Circle {
    func area(): Int {
        return 3
    }
}

const c: Shape = Circle()

struct Triangle {
}

const t: Shape = Triangle()
