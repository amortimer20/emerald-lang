struct Badge {
    const code: Int

    constructor(code: Int) {
        self.code = 0
        for step in 1..code {
            self.code = step
        }
    }
}

print(Badge(3))
