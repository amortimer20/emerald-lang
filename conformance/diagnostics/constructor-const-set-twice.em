struct Badge {
    const code: Int

    constructor(code: Int) {
        if code > 100 {
            self.code = 100
        }
        self.code = code
    }
}

print(Badge(1))
