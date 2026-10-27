struct Box[Item] {
    const value: Item
}

const maybe = "4".to_int_maybe()
const box = Box(maybe)
