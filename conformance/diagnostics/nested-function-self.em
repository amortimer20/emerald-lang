# Section 7.1: a nested function may not use `self` any more than a lambda can (7.4);
# in a struct method, neither may capture `self`.
struct Tally {
    var count: Int = 0

    func peek(): Int {
        func helper(): Int {
            return self.count
        }
        return helper()
    }
}
