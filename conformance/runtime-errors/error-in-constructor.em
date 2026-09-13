struct Ratio {
    var value: Int

    constructor(top: Int, bottom: Int) {
        self.value = top // bottom
    }
}

print(Ratio(4, 0))
