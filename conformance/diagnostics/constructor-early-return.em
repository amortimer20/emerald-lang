struct Level {
    var value: Int

    constructor(value: Int) {
        if value < 0 {
            return
        }
        self.value = value
    }
}

print(Level(1))
