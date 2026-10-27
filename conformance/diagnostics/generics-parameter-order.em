func larger() {
}

struct Box[Item] {
    const value: Item

    func larger?(other: Item): Bool {
        return self.value > other
    }
}
