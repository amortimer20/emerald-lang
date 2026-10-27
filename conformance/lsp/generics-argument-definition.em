struct Player {
    const name: String
}

struct Box[Item] {
    const value: Item
}

const box: Box[Pla/*cursor*/yer] = Box(Player("Ava"))
