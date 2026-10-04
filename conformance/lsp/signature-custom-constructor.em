struct Box {
    const value: Int
    constructor(value: Int, scale: Int = 2) {
        self.value = value * scale
    }
}
Box(3, /*cursor*/2)
