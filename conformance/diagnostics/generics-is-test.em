struct Box[Item] {
    const value: Item
}

const box = Box(1)
print(box is Box[Int])
