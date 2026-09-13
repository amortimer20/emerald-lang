var made: [Pair] = []

struct Pair {
    var left: Int
    var right: Int

    constructor(left: Int) {
        self.left = left
        made.append(self)
        self.right = left
    }
}

print(Pair(1))
