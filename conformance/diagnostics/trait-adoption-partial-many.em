# Section 11.1: with four or more methods to mark, the hint says which ones by rule. Here the
# struct defines four of the trait's six methods.
trait Shape {
    func area(): Int
    func m1(): Int {
        return 1
    }
    func m2(): Int {
        return 2
    }
    func m3(): Int {
        return 3
    }
    func m4(): Int {
        return 4
    }
    func m5(): Int {
        return 5
    }
}

struct Box {
    const x: Int
    func area(): Int {
        return 1
    }
    func m1(): Int {
        return 10
    }
    func m2(): Int {
        return 20
    }
    func m3(): Int {
        return 30
    }
}

const s: Shape = Box(1)
