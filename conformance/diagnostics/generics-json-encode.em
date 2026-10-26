struct Box[Item] {
    const value: Item
}

print(Json.encode(Box(1)))
