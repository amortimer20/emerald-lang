struct Box[Item] {
    const value: Item

    func size(): Int {
        return self.value.count
    }
}
