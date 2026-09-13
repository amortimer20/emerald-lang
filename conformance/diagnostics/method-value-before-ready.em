struct Early {
    var a: Int
    var b: Int
    var later: func(): Int = self.total

    constructor(a: Int) {
        self.a = a
        const f = self.total
        self.b = f()
        const g = self.total
    }

    func total(): Int {
        return self.a + self.b
    }

    func _secret() {
    }
}

const hidden = Early(1)._secret
