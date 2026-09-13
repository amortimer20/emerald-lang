var base: Int

struct Badge {
    var code: Int

    constructor() {
        self.code = base
    }
}

func make(): Badge {
    return Badge()
}

print(Badge())
print(make())
base = 3
print(Badge())
