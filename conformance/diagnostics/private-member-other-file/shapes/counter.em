struct Counter {
    var _count: Int = 0
    var Counter._made = 0

    func Counter._reset() {
        Counter._made = 0
    }
}

# Outside the braces, even in the same file.
func peek(counter: Counter): Int {
    return counter._count
}
