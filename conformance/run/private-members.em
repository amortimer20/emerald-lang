struct Counter {
    var _count: Int = 0
    var step: Int
    var Counter._made = 0

    constructor(step: Int) {
        self.step = step
        Counter._made += 1
    }

    const count: Int {
        return self._count
    }

    func tick() {
        self._bump(self.step)
    }

    func _bump(by: Int) {
        self._count += by
    }

    func same?(other: Counter): Bool {
        return other._count == self._count
    }

    func all_ticked(counters: List[Counter]): List[Int] {
        return counters.map { c => c._count }
    }

    ## A documentation comment does not hide the type receiver.
    func Counter.made(): Int {
        return Counter._made
    }
}

var c = Counter(2)
c.tick()
c.tick()
print(c.count)
print(Counter.made())
print(c.same?(Counter(1)))
print(c)

struct Pair {
    var _left: Int = 1
    var right: Int
    func Pair.inside(): Pair {
        return Pair(5, 6)
    }
}
print(Pair(right: 2))
print(Pair.inside())
