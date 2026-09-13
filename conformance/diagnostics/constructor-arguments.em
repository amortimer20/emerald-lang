struct Badge {
    var code: Int

    constructor(label: String) {
        self.code = label.count
    }
}

print(Badge("ok"))
print(Badge(1, 2))
print(Badge(3))
