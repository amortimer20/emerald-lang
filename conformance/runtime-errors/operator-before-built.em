# A base class's constructor may pass `self` on once its own fields are set,
# and an operator there runs the object's own class's version of the method,
# which may read a field that is not set yet (10.2, 11.5).

func check(level: Level) {
    print(level < level)
}

class Level with Ordered {
    const rank: Int

    constructor(rank: Int) {
        self.rank = rank
        check(self)
    }

    @override
    func compare(other: Level): Int {
        return self.rank - other.rank
    }
}

class Boss extends Level {
    const bonus: Int

    constructor() {
        super(10)
        self.bonus = 5
    }

    @override
    func compare(other: Level): Int {
        return self.bonus
    }
}

Level(1)
Boss()
