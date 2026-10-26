struct Box[Item] {
    const value: Item

    func holds?(other: Item): Bool {
        return self.value == other
    }
}
