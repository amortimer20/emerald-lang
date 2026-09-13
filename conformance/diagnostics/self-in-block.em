struct Badge {
    var code: Int

    constructor(code: Int) {
        self.code = code
        const show = { => print(self.code) }
        show()
    }
}
