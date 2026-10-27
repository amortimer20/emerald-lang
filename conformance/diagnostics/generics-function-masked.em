struct Box[Item] {
    const value: Item

    func Box.of[Value](value: Value): Item {
        return value
    }
}
