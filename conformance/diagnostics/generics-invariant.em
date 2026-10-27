struct Box[Item] {
    const value: Item
}

const whole: Box[Int] = Box(1)
const real: Box[Float] = whole
