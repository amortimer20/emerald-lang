## A struct's members are printed back in the order they were written, even
## though the parser groups them by kind internally.
struct Counter {
    var Counter.made = 0

    var value: Int = 0

    constructor(value: Int) {
        self.value = value
        Counter.made += 1
    }

    func increment() {
        self.value += 1
    }

    const doubled: Int {
        return self.value * 2
    }
}

trait Describable {
    const name: String

    func describe(): String
}

class Item with Describable {
    const name: String

    @override
    func describe(): String {
        return "an item called #{self.name}"
    }
}

enum Direction {
    north
    south

    const opposite: Direction {
        return case self {
            when Direction.north then Direction.south
            when Direction.south then Direction.north
        }
    }
}

case Direction.north {
    when Direction.north {
        print("facing north")
    }
    else {
        print("facing elsewhere")
    }
}
