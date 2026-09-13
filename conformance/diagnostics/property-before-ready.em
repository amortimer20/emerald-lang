struct Pair {
    var left: Int
    var right: Int

    constructor() {
        self.left = 1
        print(self.total)
        self.total = 3
        self.right = 2
    }

    var total: Int {
        get {
            return self.left + self.right
        }
        set {
            self.left = value
        }
    }
}
