struct Level {
    var value: Int

    constructor(value: Int) {
        if value > 0 {
            self.value = value
        }
    }
}

print(Level(1))
